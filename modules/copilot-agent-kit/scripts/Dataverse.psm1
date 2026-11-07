# Funcoes do modulo Copilot Agent Kit para falar com a Web API do Dataverse
# (com o token obtido pelo instalador) e importar solucoes das releases oficiais no GitHub.

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:Base = $null
$script:Token = $null

function Connect-Dataverse {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Token)
    $script:Base = "$($Url.TrimEnd('/'))/api/data/v9.2"
    $script:Token = $Token
}

function Invoke-Dataverse {
    param([string]$Metodo = 'GET', [Parameter(Mandatory)][string]$Caminho, [string]$Corpo, [int]$TempoLimiteSeg = 120)
    $parametros = @{
        Method     = $Metodo
        Uri        = "$script:Base/$Caminho"
        Headers    = @{ Authorization = "Bearer $script:Token"; 'OData-Version' = '4.0'; 'OData-MaxVersion' = '4.0'; Accept = 'application/json' }
        TimeoutSec = $TempoLimiteSeg
    }
    if ($Corpo) { $parametros.Body = [System.Text.Encoding]::UTF8.GetBytes($Corpo); $parametros.ContentType = 'application/json; charset=utf-8' }
    try {
        Invoke-RestMethod @parametros
    } catch {
        $detalhe = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $null }
        if ($_.Exception.Response.StatusCode -eq 401) { throw 'O acesso ao Dataverse expirou ou foi negado (401). Rode a etapa de novo para fazer login.' }
        if ($_.Exception.Response.StatusCode -eq 403) { throw "Sem permissão no Dataverse (403). Use uma conta com o papel Administrador do sistema. $detalhe" }
        throw "Dataverse: $(if ($detalhe) { $detalhe } else { $_.Exception.Message })"
    }
}

function Set-CodeAppsHabilitado {
    <#
    Liga "Power Apps code apps" no ambiente. Essa opcao nao fica no Dataverse (tabela
    organization) e sim nas configuracoes de gerenciamento do ambiente, na Power Platform API
    (a mesma usada pelo admin center e pelo "pac environment-management").
    Devolve $true se precisou ligar, $false se ja estava ligado.
    #>
    param([Parameter(Mandatory)][string]$EnvironmentId, [Parameter(Mandatory)][string]$Token)
    $url = "https://api.powerplatform.com/environmentmanagement/environments/$EnvironmentId/settings?api-version=2024-10-01"
    $cabecalhos = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    $corpo = [System.Text.Encoding]::UTF8.GetBytes('{"powerApps_AllowCodeApps":true}')

    $atual = $null
    try {
        $lista = Invoke-RestMethod -Uri "$url&`$select=powerApps_AllowCodeApps" -Headers $cabecalhos
        $registro = @($lista.objectResult)[0]
        if ($registro) { $atual = $registro.PSObject.Properties | Where-Object Name -eq 'powerApps_AllowCodeApps' | Select-Object -ExpandProperty Value }
    } catch {
        $codigo = [int]$_.Exception.Response.StatusCode
        if ($codigo -eq 401) { throw 'O acesso à Power Platform API expirou ou foi negado (401). Rode a etapa de novo para fazer login.' }
        if ($codigo -eq 403) { throw 'Sem permissão para alterar as configurações do ambiente na Power Platform API (403). É preciso ser administrador do Power Platform ou do ambiente.' }
        throw "Power Platform API: $($_.Exception.Message)"
    }
    if ($atual -eq $true) { return $false }

    try {
        # Se o ambiente ainda nao tem o registro de configuracoes, ele e criado (POST) em vez de atualizado
        $metodo = if ($null -eq $registro) { 'Post' } else { 'Patch' }
        Invoke-RestMethod -Method $metodo -Uri $url -Headers $cabecalhos -Body $corpo -ContentType 'application/json' | Out-Null
    } catch {
        $detalhe = try { ($_.ErrorDetails.Message | ConvertFrom-Json).errors.message } catch { $null }
        throw "Não foi possível ligar code apps pela Power Platform API: $(if ($detalhe) { $detalhe } else { $_.Exception.Message })"
    }
    return $true
}

function Get-SolucaoInstalada {
    <# Versao instalada da solucao (ou $null). #>
    param([Parameter(Mandatory)][string]$NomeUnico)
    $r = Invoke-Dataverse -Caminho "solutions?`$select=version,friendlyname,ismanaged&`$filter=uniquename eq '$NomeUnico'"
    return $r.value | Select-Object -First 1
}

function Compare-Versao([string]$A, [string]$B) {
    $pa = $A -split '\.' | ForEach-Object { [int64]$_ }
    $pb = $B -split '\.' | ForEach-Object { [int64]$_ }
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $d = ($pa[$i] ?? 0) - ($pb[$i] ?? 0)
        if ($d -ne 0) { return [Math]::Sign($d) }
    }
    return 0
}

function Get-PacoteDaRelease {
    <#
    Baixa (ou reaproveita) o .zip gerenciado da ultima release oficial e devolve
    @{ Caminho; Versao; Release; Hash }. A versao vem do nome do arquivo
    (ex.: CreatorKitCore_1_0_20250310_1_managed.zip -> 1.0.20250310.1).
    #>
    param([Parameter(Mandatory)][string]$Repositorio, [Parameter(Mandatory)][string]$PadraoArquivo)
    $release = Invoke-RestMethod "https://api.github.com/repos/$Repositorio/releases/latest" -Headers @{ 'User-Agent' = 'ReadinessDeployAccelerator' }
    $asset = $release.assets | Where-Object name -match $PadraoArquivo | Select-Object -First 1
    if (-not $asset) { throw "Pacote '$PadraoArquivo' nao encontrado na release $($release.tag_name) de $Repositorio." }
    $versao = ($asset.name -replace '^[^_]+_', '' -replace '_managed\.zip$', '') -replace '_', '.'

    $pasta = Join-Path ([System.IO.Path]::GetTempPath()) 'ReadinessDeployAccelerator\pacotes'
    New-Item -ItemType Directory -Force -Path $pasta | Out-Null
    $destino = Join-Path $pasta $asset.name
    if ((Test-Path $destino) -and (Get-Item $destino).Length -eq $asset.size) {
        Write-BizappLog "Pacote já baixado: $($asset.name)" -Nivel discreto
    } else {
        Write-BizappLog "Baixando $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB) da release $($release.tag_name)..."
        Write-BizappProgresso -Percentual 0 -Fase 'Baixando o pacote oficial'
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile "$destino.parcial"
        Move-Item -Force "$destino.parcial" $destino
    }
    $hash = (Get-FileHash -Algorithm SHA256 -Path $destino).Hash
    Write-BizappLog "SHA-256: $hash" -Nivel discreto
    return @{ Caminho = $destino; Versao = $versao; Release = $release.tag_name; Hash = $hash }
}

function Get-ImportJob([string]$JobId) {
    <# Registro da importacao (ou $null se o ambiente ainda nao criou). #>
    try { return Invoke-Dataverse -Caminho "importjobs($JobId)?`$select=progress,completedon" } catch { return $null }
}

function Send-Pacote {
    <#
    Envia o pacote (ImportSolutionAsync) e devolve o id da operacao assincrona.
    O envio de dezenas de MB pode cair no meio ("Error while copying content to a stream").
    Antes de reenviar, confere pelo ImportJobId se o ambiente recebeu o pacote mesmo assim:
    nesse caso a importacao ja comecou e reenviar criaria uma segunda importacao. Entao devolve
    $null e o acompanhamento segue so pelo registro da importacao.
    #>
    param([string]$Caminho, [string]$Nome, [string]$JobId, [int]$Tentativas = 3)
    $base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Caminho))
    # PublishWorkflows = false: os fluxos ficam desligados ate as conexoes serem configuradas (Setup Wizard).
    # ComponentParameters fica de fora: mesmo vazio ([]), a Web API recusa com
    # "Custom state is not set for entity type crmbaseentity".
    $corpo = '{"OverwriteUnmanagedCustomizations":false,"PublishWorkflows":false,"ImportJobId":"' + $JobId + '","CustomizationFile":"' + $base64 + '"}'
    $base64 = $null

    for ($tentativa = 1; $tentativa -le $Tentativas; $tentativa++) {
        Write-BizappLog "Enviando $Nome para o Dataverse$(if ($tentativa -gt 1) { " (tentativa $tentativa de $Tentativas)" })..."
        Write-BizappProgresso -Percentual 0 -Fase 'Enviando o pacote para o ambiente'
        try {
            return (Invoke-Dataverse -Metodo POST -Caminho 'ImportSolutionAsync' -Corpo $corpo -TempoLimiteSeg 900).AsyncOperationId
        } catch {
            $erro = $_.Exception.Message
            if ($erro -match '\((401|403)\)') { throw }  # login ou permissao: repetir nao resolve
            Write-BizappLog "O envio falhou: $erro" -Nivel aviso
            Write-BizappLog 'Conferindo se o ambiente recebeu o pacote mesmo assim...' -Nivel discreto
            Start-Sleep -Seconds 20
            if (Get-ImportJob $JobId) {
                Write-BizappLog 'O ambiente recebeu o pacote e a importação começou. Acompanhando.' -Nivel sucesso
                return $null
            }
            if ($tentativa -eq $Tentativas) { throw "Não foi possível enviar $Nome depois de $Tentativas tentativas. Último erro: $erro" }
        }
    }
}

function Import-Solucao {
    <#
    Importa a solucao com ImportSolutionAsync e acompanha o progresso (importjob) e o
    resultado (asyncoperation) ate terminar. O resultado oficial e o da operacao assincrona:
    o historico de solucoes pode mostrar "Falha" (WorkerProcessCrashFailure) enquanto a
    importacao segue normalmente. Quando a resposta do envio se perdeu (ver Send-Pacote),
    so o registro da importacao e acompanhado e quem chama confere a versao instalada no fim.
    #>
    param(
        [Parameter(Mandatory)][string]$Caminho,
        [Parameter(Mandatory)][string]$Nome,
        [int]$LimiteMinutos = 90
    )
    $jobId = [guid]::NewGuid().ToString()
    $operacaoId = Send-Pacote -Caminho $Caminho -Nome $Nome -JobId $jobId
    if ($operacaoId) { Write-BizappLog "Importação iniciada (operação $operacaoId)." -Nivel discreto }

    $inicio = Get-Date
    $ultimoLog = $inicio
    while ($true) {
        Start-Sleep -Seconds 10
        $job = Get-ImportJob $jobId
        $progresso = if ($job) { [double]$job.progress } else { 0 }

        $fase = if ($progresso -lt 90) { 'Importando componentes' } else { 'Finalizando: publicando apps e fluxos' }
        Write-BizappProgresso -Percentual $progresso -Fase $fase

        if (-not $operacaoId) {
            # Sem a operacao assincrona: termina quando o registro da importacao tiver data de conclusao
            if ($job -and $job.completedon) { return }
        } else {
            $operacao = Invoke-Dataverse -Caminho "asyncoperations($operacaoId)?`$select=statecode,statuscode,message,friendlymessage"
        }

        if ($operacaoId -and $operacao.statecode -eq 3) {
            switch ($operacao.statuscode) {
                30 { Write-BizappProgresso -Percentual 100 -Fase 'Concluído'; return }
                32 { throw "A importação de $Nome foi cancelada no ambiente." }
                default {
                    $mensagem = if ($operacao.friendlymessage) { $operacao.friendlymessage } else { $operacao.message }
                    throw "A importação de $Nome falhou: $mensagem"
                }
            }
        }

        $decorrido = (Get-Date) - $inicio
        if (((Get-Date) - $ultimoLog).TotalMinutes -ge 5) {
            Write-BizappLog "Ainda importando: $([int]$decorrido.TotalMinutes) min, $([math]::Round($progresso, 1))%." -Nivel discreto
            $ultimoLog = Get-Date
        }
        if ($decorrido.TotalMinutes -ge $LimiteMinutos) {
            throw "A importação de $Nome passou de $LimiteMinutos min e continua no ambiente. Acompanhe em Soluções > Histórico de soluções e rode a etapa de novo quando terminar (ela reconhece a solução instalada)."
        }
    }
}

function Install-SolucaoDaRelease {
    <# Instala ou atualiza a solucao a partir da ultima release oficial; pula se ja estiver na mesma versao ou mais nova. #>
    param(
        [Parameter(Mandatory)][string]$Repositorio,
        [Parameter(Mandatory)][string]$PadraoArquivo,
        [Parameter(Mandatory)][string]$NomeUnico,
        [Parameter(Mandatory)][string]$Nome,
        [int]$LimiteMinutos = 90
    )
    $pacote = Get-PacoteDaRelease -Repositorio $Repositorio -PadraoArquivo $PadraoArquivo
    $instalada = Get-SolucaoInstalada -NomeUnico $NomeUnico
    if ($instalada -and (Compare-Versao $instalada.version $pacote.Versao) -ge 0) {
        Write-BizappLog "$Nome já está instalado na versão $($instalada.version) (pacote: $($pacote.Versao)). Nada a fazer." -Nivel sucesso
        Write-BizappProgresso -Percentual 100 -Fase 'Já instalado'
        return $instalada.version
    }
    if ($instalada) { Write-BizappLog "Atualizando $Nome da versão $($instalada.version) para $($pacote.Versao)." }
    else { Write-BizappLog "Instalando $Nome $($pacote.Versao)." }

    $inicio = Get-Date
    Import-Solucao -Caminho $pacote.Caminho -Nome $Nome -LimiteMinutos $LimiteMinutos
    $versao = (Get-SolucaoInstalada -NomeUnico $NomeUnico).version
    if (-not $versao -or (Compare-Versao $versao $pacote.Versao) -lt 0) {
        throw "A importação de $Nome terminou, mas a solução não está na versão $($pacote.Versao) (encontrada: $(if ($versao) { $versao } else { 'nenhuma' })). Veja o erro em Soluções > Histórico de soluções."
    }
    Write-BizappProgresso -Percentual 100 -Fase 'Concluído'
    Write-BizappLog "$Nome $versao instalado em $([int]((Get-Date) - $inicio).TotalMinutes) min." -Nivel sucesso
    return $versao
}

Export-ModuleMember -Function Connect-Dataverse, Invoke-Dataverse, Set-CodeAppsHabilitado, Get-SolucaoInstalada, Install-SolucaoDaRelease
