#Requires -Version 5.1
<#
.SYNOPSIS
    Teste manual do AUTO-09 (ALM para agentes com Power Platform Pipelines, sem host dedicado)
    no tenant de demo, seguindo o roteiro em Word do item
    (originais/09-roteiro.docx; o cabecalho diz COE-IA-008).

.DESCRIPTION
    O roteiro so tem script para escolher os ambientes (secao 4) e para o preflight (secao 5,
    Get-AdminPowerAppEnvironment no Windows PowerShell 5.1). O resto e feito na tela: o pipeline
    usa o host da plataforma (platform host), que e oculto e nao tem API documentada para criar
    pipelines. Este teste roda as secoes 4 e 5 como o roteiro e acompanha as etapas de tela.

    Acrescimos ao roteiro (marcados com [+] na tela):
      - escolher DEV, HML e PROD pela lista de ambientes (o roteiro pede os IDs de cabeca);
      - preflight com a tabela da secao 5 conferida automaticamente (Dataverse nos tres, ambiente
        gerenciado em HML e PROD) e comparacao das regioes com a regiao do tenant (o host da
        plataforma fica sempre na regiao do tenant: outra regiao exige Cross-Geo, secao 8);
      - (opcional) tornar HML e PROD gerenciados se nao forem, com o mesmo cmdlet do item 10;
      - (opcional) tentar listar o pipeline pelo PAC CLI (pac pipeline list), para saber se o
        instalador consegue conferir o pipeline sozinho;
      - registro da secao 13 em CSV.

    Ordem do teste:
      1. Modulo Microsoft.PowerApps.Administration.PowerShell
      2. Login e conferencia da conta
      3. Escolher DEV, HML e PROD (digite SIM)
      4. Preflight (somente leitura)
      5. (opcional) Tornar HML e PROD gerenciados
      6. Configurar o pipeline na tela (secoes 7 e 8) e conferir
      7. (opcional) [+] Listar o pipeline pelo PAC CLI
      8. (opcional) Primeiro deployment DEV -> HML (secao 9)
      9. Registro (secao 13)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Teste-AUTO09.ps1
#>
param(
    [string]$TenantIdEsperado = '6a1a0a9c-5bbb-4060-8231-08f2ad74171e',
    [string]$ContaEsperada = 'admin@crm332072.onmicrosoft.com',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO09-Teste')
)

$ErrorActionPreference = 'Stop'
$MODULO = 'Microsoft.PowerApps.Administration.PowerShell'

function Etapa([string]$Numero, [string]$Titulo) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host " ETAPA $Numero - $Titulo" -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
}

function Confirmar([string]$Pergunta) {
    return (Read-Host "$Pergunta (S/N)") -match '^[sS]'
}

$resultados = New-Object System.Collections.Generic.List[object]
function Registrar([string]$Parte, [string]$Acao, [bool]$Ok, [string]$Detalhe = '') {
    $script:resultados.Add([pscustomobject]@{ Parte = $Parte; Acao = $Acao; Sucesso = $Ok; Detalhe = $Detalhe })
    $cor = if ($Ok) { 'Green' } else { 'Red' }
    $txt = if ($Ok) { 'OK' } else { 'FALHOU' }
    $det = if ($Detalhe) { ": $Detalhe" } else { '' }
    Write-Host "  $txt - $Parte / $Acao$det" -ForegroundColor $cor
}

function Salvar([string]$Nome, [object[]]$Dados) {
    $arq = Join-Path $script:Evid $Nome
    if (@($Dados).Count) { @($Dados) | Export-Csv -Path $arq -NoTypeInformation -Encoding UTF8 }
    else { [pscustomobject]@{ Resultado = 'Sem registros' } | Export-Csv -Path $arq -NoTypeInformation -Encoding UTF8 }
}

function Resumir-Ambiente($Amb) {
    $p = $Amb.Internal.properties
    [pscustomobject]@{
        DisplayName   = $Amb.DisplayName
        EnvironmentId = $Amb.EnvironmentName
        Sku           = $p.environmentSku
        Regiao        = $Amb.Location
        UrlDataverse  = $p.linkedEnvironmentMetadata.instanceUrl
        Gerenciado    = ($p.governanceConfiguration.protectionLevel -eq 'Standard')
    }
}

function Escolher([object[]]$Lista, [string]$Camada, [string]$Sugestao) {
    while ($true) {
        $padrao = ''
        if ($Sugestao) { $i = [array]::IndexOf(@($Lista.DisplayName), $Sugestao); if ($i -ge 0) { $padrao = $i + 1 } }
        $r = (Read-Host "Numero do ambiente $Camada$(if ($padrao) { " (Enter = $padrao $Sugestao)" })").Trim()
        if (-not $r -and $padrao) { $r = "$padrao" }
        $n = 0
        if ([int]::TryParse($r, [ref]$n) -and $n -ge 1 -and $n -le $Lista.Count) { return $Lista[$n - 1] }
        Write-Host 'Numero invalido.' -ForegroundColor Yellow
    }
}

New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$script:Evid = Join-Path $PastaTrabalho "evidencias\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Force -Path $script:Evid | Out-Null
$LOG_TESTE = Join-Path $PastaTrabalho "teste-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -LiteralPath $LOG_TESTE -Force | Out-Null
$registro = [ordered]@{}

try {
    # ------------------------------------------------------------------
    Etapa 1 "Modulo $MODULO"
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Rode no Windows PowerShell 5.1 (powershell.exe), como pede o roteiro.' }
    if (-not (Get-Module -ListAvailable -Name $MODULO)) {
        if (-not (Confirmar 'Falta o modulo. Instalar para o seu usuario agora?')) { throw 'Modulo nao instalado. Nada foi alterado.' }
        Install-Module -Name $MODULO -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    Import-Module $MODULO -WarningAction SilentlyContinue
    Write-Host "$MODULO $((Get-Module $MODULO).Version)" -ForegroundColor Green

    # ------------------------------------------------------------------
    Etapa 2 'Login'
    Write-Host "Tenant esperado: $TenantIdEsperado"
    Write-Host "Conta esperada:  $ContaEsperada"
    if (-not (Confirmar 'Estes sao os dados do tenant de DEMO?')) {
        $TenantIdEsperado = Read-Host 'Tenant ID do tenant de demo'
        $ContaEsperada = Read-Host 'Conta administradora (UPN)'
    }
    Write-Host "Vai abrir uma janela de login: entre com $ContaEsperada." -ForegroundColor Cyan
    Add-PowerAppsAccount -TenantID $TenantIdEsperado | Out-Null
    $conta = $global:currentSession.upn
    if (-not $conta -and $global:currentSession.msalAccount) { $conta = $global:currentSession.msalAccount.Username }
    if ($conta -and $conta -ne $ContaEsperada) { throw "Login com outra conta ($conta). Nada foi alterado." }
    if ($global:currentSession.tenantId -ne $TenantIdEsperado) { throw "Login em outro tenant ($($global:currentSession.tenantId)). Nada foi alterado." }
    Registrar 'Login' 'Conectar' $true $conta

    # ------------------------------------------------------------------
    Etapa 3 'Escolher DEV, HML e PROD (secao 4 do roteiro)'
    $todos = @(Get-AdminPowerAppEnvironment | ForEach-Object { Resumir-Ambiente $_ } | Sort-Object DisplayName)
    Salvar 'ambientes.csv' $todos
    for ($i = 0; $i -lt $todos.Count; $i++) {
        $a = $todos[$i]
        Write-Host ("{0,3}. {1}  [{2}, {3}, {4}, {5}]" -f ($i + 1), $a.DisplayName, $a.Sku, $a.Regiao, $(if ($a.UrlDataverse) { 'Dataverse' } else { 'sem Dataverse' }), $(if ($a.Gerenciado) { 'gerenciado' } else { 'nao gerenciado' }))
    }
    $padraoRegiao = @($todos | Where-Object Sku -eq 'Default' | Select-Object -ExpandProperty Regiao)[0]
    Write-Host "[+] Regiao do tenant (ambiente padrao): $padraoRegiao. O host da plataforma fica nela." -ForegroundColor DarkGray
    $dev = Escolher $todos 'DEV' 'Agentes de IA - Dev'
    $hml = Escolher $todos 'HML' 'Agentes IA - Homol'
    $prod = Escolher $todos 'PROD' 'Agentes de IA - Prod'
    Write-Host "DEV : $($dev.DisplayName) ($($dev.EnvironmentId))"
    Write-Host "HML : $($hml.DisplayName) ($($hml.EnvironmentId))"
    Write-Host "PROD: $($prod.DisplayName) ($($prod.EnvironmentId))"
    if (@($dev.EnvironmentId, $hml.EnvironmentId, $prod.EnvironmentId | Select-Object -Unique).Count -lt 3) { throw 'DEV, HML e PROD precisam ser ambientes diferentes.' }
    if ((Read-Host 'Confirma os ambientes? Digite SIM') -cne 'SIM') { throw 'Operacao cancelada.' }

    # ------------------------------------------------------------------
    Etapa 4 'Preflight (secao 5 do roteiro, somente leitura)'
    $camadas = [ordered]@{ DEV = $dev; HML = $hml; PROD = $prod }
    $preflight = New-Object System.Collections.Generic.List[object]
    foreach ($c in @($camadas.Keys)) {
        $lido = Resumir-Ambiente (Get-AdminPowerAppEnvironment -EnvironmentName $camadas[$c].EnvironmentId)
        $camadas[$c] = $lido
        $exigeGerenciado = $c -ne 'DEV'
        $outraRegiao = $padraoRegiao -and $lido.Regiao -ne $padraoRegiao
        $preflight.Add([pscustomobject]@{
                Camada = $c; Nome = $lido.DisplayName; EnvironmentId = $lido.EnvironmentId; Tipo = $lido.Sku; Regiao = $lido.Regiao
                Dataverse = [bool]$lido.UrlDataverse; Gerenciado = $lido.Gerenciado; GerenciadoObrigatorio = $exigeGerenciado
                RegiaoDiferenteDoTenant = $outraRegiao
            })
        Registrar 'Preflight' "$c Dataverse" ([bool]$lido.UrlDataverse) $lido.UrlDataverse
        if ($exigeGerenciado) { Registrar 'Preflight' "$c gerenciado" $lido.Gerenciado }
        else { Write-Host "  (DEV gerenciado: $($lido.Gerenciado); nao obrigatorio)" -ForegroundColor DarkGray }
    }
    $preflight | Format-Table -AutoSize | Out-Host
    Salvar 'preflight.csv' $preflight
    $foraDaRegiao = @($preflight | Where-Object RegiaoDiferenteDoTenant)
    $crossGeo = $foraDaRegiao.Count -gt 0
    if ($crossGeo) {
        Write-Host "[+] Em regiao diferente do tenant ($padraoRegiao): $(($foraDaRegiao | ForEach-Object { "$($_.Camada) em $($_.Regiao)" }) -join ', ')." -ForegroundColor Yellow
        Write-Host '    Pela secao 8 do roteiro, o pipeline so enxerga esses ambientes com Cross-Geo Solution Deployment ligado (exige aprovacao do CoE).' -ForegroundColor Yellow
    } else { Write-Host '[+] Todos na regiao do tenant: nao precisa de Cross-Geo.' -ForegroundColor Green }
    Registrar 'Preflight' 'Regioes comparadas' $true $(if ($crossGeo) { 'Cross-Geo necessario' } else { 'Mesma regiao' })

    # ------------------------------------------------------------------
    Etapa 5 '[+] Tornar HML e PROD gerenciados (opcional)'
    foreach ($c in 'HML', 'PROD') {
        $a = $camadas[$c]
        if ($a.Gerenciado) { Write-Host "$c ja e gerenciado." -ForegroundColor DarkGray; continue }
        if (-not (Confirmar "$c ($($a.DisplayName)) nao e gerenciado. Tornar gerenciado agora?")) { continue }
        try {
            $null = Set-AdminPowerAppEnvironmentGovernanceConfiguration -EnvironmentName $a.EnvironmentId -UpdatedGovernanceConfiguration ([pscustomobject]@{
                    protectionLevel = 'Standard'; settings = [pscustomobject]@{ extendedSettings = @{} } })
            $ok = $false
            for ($i = 1; $i -le 6 -and -not $ok; $i++) { Start-Sleep -Seconds 20; $ok = (Resumir-Ambiente (Get-AdminPowerAppEnvironment -EnvironmentName $a.EnvironmentId)).Gerenciado }
            Registrar 'Gerenciado' $c $ok
            if ($ok) { $camadas[$c].Gerenciado = $true }
        } catch { Registrar 'Gerenciado' $c $false $_.Exception.Message }
    }

    # ------------------------------------------------------------------
    Etapa 6 'Configurar o pipeline na tela (secoes 7 e 8 do roteiro)'
    $urlPipelines = "https://make.powerapps.com/environments/$($camadas.DEV.EnvironmentId)/solutions"
    Write-Host "1. Abra $urlPipelines (o ambiente DEV). Pipelines fica DENTRO de uma solucao: crie uma (Nova solucao) ou abra uma nao gerenciada e va em Pipelines (icone de foguete) no menu da solucao." -ForegroundColor Cyan
    Write-Host "2. Criar pipeline: nome (ex.: Agentes IA), destino = $($camadas.HML.DisplayName). Salvar." -ForegroundColor Cyan
    Write-Host "3. Adicionar fase: destino final = $($camadas.PROD.DisplayName). Salvar." -ForegroundColor Cyan
    if ($crossGeo) { Write-Host '4. Se o HML ou o PROD nao aparecer na lista: Gerenciar pipelines > Configuracoes avancadas > Cross-Geo Solution Deployment = On (so com aprovacao).' -ForegroundColor Yellow }
    Write-Host 'Observacao: no host da plataforma o pipeline e pessoal (nao da para compartilhar). Para compartilhar ou ter mais fases, e preciso um host proprio.' -ForegroundColor DarkGray
    try { Start-Process $urlPipelines } catch { }
    $nomePipeline = (Read-Host 'Nome do pipeline criado (Enter se nao criou)').Trim()
    if ($nomePipeline) {
        $estagios = Confirmar "O pipeline '$nomePipeline' tem as duas fases (HML e depois PROD)?"
        Registrar 'Pipeline' 'Criado na tela' $estagios "$nomePipeline"
        $registro.Pipeline = $nomePipeline
        if ($crossGeo) {
            $cg = Confirmar 'Precisou ligar o Cross-Geo?'
            $registro.CrossGeo = $(if ($cg) { 'SIM' } else { 'NAO' })
        } else { $registro.CrossGeo = 'N/A' }
    } else { Registrar 'Pipeline' 'Criado na tela' $false 'Nao criado' }

    # ------------------------------------------------------------------
    Etapa 7 '[+] Listar o pipeline pelo PAC CLI (opcional)'
    $pac = Get-Command pac -ErrorAction SilentlyContinue
    if (-not $pac) { Write-Host 'PAC CLI nao encontrado; pulando.' -ForegroundColor DarkGray }
    elseif (Confirmar 'Tentar "pac pipeline list" no DEV? (pode abrir um login do PAC no navegador)') {
        $devUrl = ([string]$camadas.DEV.UrlDataverse).TrimEnd('/')
        Write-Host "pac auth create --environment $devUrl" -ForegroundColor DarkGray
        & pac auth create --environment $devUrl 2>&1 | Out-Host
        Write-Host "pac pipeline list --environment $devUrl" -ForegroundColor DarkGray
        $saida = & pac pipeline list --environment $devUrl 2>&1 | Out-String
        Write-Host $saida
        $saida | Set-Content -Path (Join-Path $script:Evid 'pac-pipeline-list.txt') -Encoding UTF8
        $achou = $nomePipeline -and $saida -match [regex]::Escape($nomePipeline)
        Registrar 'PAC CLI' 'pac pipeline list no DEV' $achou $(if ($achou) { 'Pipeline listado' } else { 'Pipeline nao apareceu (veja pac-pipeline-list.txt)' })
    }

    # ------------------------------------------------------------------
    Etapa 8 'Primeiro deployment DEV -> HML (opcional, secao 9 do roteiro)'
    Write-Host 'No DEV: Solucoes > sua solucao (nao gerenciada) > Pipelines > Implantar aqui na fase do HML.' -ForegroundColor Cyan
    Write-Host 'Revise as validacoes, os valores das variaveis de ambiente e as referencias de conexao do HML, e conclua.' -ForegroundColor Cyan
    $solucao = (Read-Host 'Nome da solucao implantada no HML (Enter se nao fez)').Trim()
    if ($solucao) {
        $registro.Solution = $solucao
        Registrar 'Deployment' 'DEV -> HML' (Confirmar "A solucao '$solucao' aparece como gerenciada no HML e funciona?") $solucao
    }

    # ------------------------------------------------------------------
    Etapa 9 'Registro (secao 13 do roteiro)'
    foreach ($c in $camadas.Keys) { $registro["$c Environment ID"] = $camadas[$c].EnvironmentId; $registro["$c Regiao"] = $camadas[$c].Regiao }
    $reg = [pscustomobject]$registro
    $reg | Format-List | Out-Host
    Salvar 'registro.csv' @($reg)
} catch {
    Write-Host ''
    Write-Host "PAROU: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Onde: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
} finally {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host ' RESUMO' -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    if ($resultados.Count) {
        $resultados | Format-Table -AutoSize -Wrap | Out-Host
        $resultados | Export-Csv -Path (Join-Path $script:Evid 'resumo.csv') -NoTypeInformation -Encoding UTF8
    } else { Write-Host 'Nada foi executado.' }
    Write-Host "Evidencias: $script:Evid" -ForegroundColor DarkGray
    Write-Host "Log completo do teste: $LOG_TESTE" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
}
