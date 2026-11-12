# Funcoes do AUTO-31 (auditoria unificada e eventos do Copilot), trazidas do script validado no
# laboratorio (testes-manuais/originais/31-auditoria-copilot-ual.ps1, teste de 11/11/2026).
# Diferencas:
#   - logins pelo instalador: Graph (conta e licencas, chamadas REST, sem os modulos do Graph),
#     Exchange Online e Security & Compliance (Connect-* -AccessToken, modulo 3.8 ou superior);
#   - Security & Compliance conecta ANTES do Exchange Online: as duas sessoes tem
#     Get-AdminAuditLogConfig e vale a ultima; no Security & Compliance a auditoria aparece sempre
#     desligada (documentacao da Microsoft). A origem do comando e conferida antes de ler;
#   - ligar a auditoria pode levar ate 60 min: se a leitura logo depois ainda disser "desligada",
#     o pedido foi aceito e a etapa avisa, em vez de falhar (no teste, o original falhou aqui);
#   - nova acao para remover a politica de retencao criada (no teste foi feita a mao).

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'Auditoria-Copilot'
$script:VERSAO_MINIMA_EXO = [version]'3.8.0'   # -AccessToken no Connect-IPPSSession
$script:ESCOPOS_GRAPH = @('User.Read.All', 'Organization.Read.All')
$script:DESCRICAO_POLITICA = 'Retenção dos eventos de interação com o Copilot (CopilotInteraction). Criada pelo Readiness Deploy Accelerator.'

function Get-SafeProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Invoke-GraphRest {
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Caminho)
    Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/$Caminho" -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
}

function Import-ExchangeModulo {
    $m = Get-Module -ListAvailable -Name ExchangeOnlineManagement | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $m) { throw 'O módulo ExchangeOnlineManagement não está instalado. Instale-o pela tela de pré-requisitos.' }
    if ($m.Version -lt $script:VERSAO_MINIMA_EXO) {
        throw "O módulo ExchangeOnlineManagement está na versão $($m.Version); é preciso $($script:VERSAO_MINIMA_EXO) ou superior. Atualize pela tela de pré-requisitos."
    }
    # -Global: sem ele os comandos ficariam invisiveis para o script da etapa
    Import-Module -Name $m.Path -Force -Global -ErrorAction Stop -WarningAction SilentlyContinue 3>$null | Out-Null
    Write-BizappLog "Exchange Online PowerShell $($m.Version)" -Nivel discreto
    return $m
}

function Get-TextoDuracao {
    param([AllowNull()][object]$Valor)
    switch ([string]$Valor) {
        'ThreeMonths' { '3 meses' }
        'SixMonths' { '6 meses' }
        'NineMonths' { '9 meses' }
        'TwelveMonths' { '12 meses' }
        'TenYears' { '10 anos' }
        default { [string]$Valor }
    }
}

function Connect-AuditoriaCopilot {
    <#
    Confere a conta e as licencas pelo Graph (token do instalador) e conecta o Security &
    Compliance e o Exchange Online com os tokens do instalador. Devolve o contexto da execucao.
    #>
    param([Parameter(Mandatory)][hashtable]$Entrada)

    $tokenGraph = Get-BizappToken -Entrada $Entrada -Nome Graph
    $id = Assert-BizappContexto -Token $tokenGraph -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta
    $faltando = @($script:ESCOPOS_GRAPH | Where-Object { $_ -notin $id.Escopos })
    if ($faltando) { throw "O login não tem as permissões necessárias: $($faltando -join ', ')." }
    $tokenExo = Get-BizappToken -Entrada $Entrada -Nome Exchange
    $tokenScc = Get-BizappToken -Entrada $Entrada -Nome Purview
    $null = Assert-BizappContexto -Token $tokenExo -TenantEsperado $id.TenantId -ContaEsperada $id.Conta

    # Conta e licencas atribuidas (mesma heuristica do original, pelo nome do SKU)
    $usuario = Invoke-GraphRest -Token $tokenGraph -Caminho "users/$([uri]::EscapeDataString($id.Conta))?`$select=id,userPrincipalName,accountEnabled,assignedLicenses"
    if ($usuario.accountEnabled -ne $true) { throw 'A conta administrativa está desabilitada.' }
    $skus = @((Invoke-GraphRest -Token $tokenGraph -Caminho 'subscribedSkus').value)
    $atribuidas = @($usuario.assignedLicenses | ForEach-Object { [string]$_.skuId })
    $licencas = @(foreach ($s in $skus) {
            if ($atribuidas -contains [string]$s.skuId) {
                $nome = [string]$s.skuPartNumber
                $candidata = $nome -match 'E5|PURVIEW|COMPLIANCE|AUDIT|EDISCOVERY'
                [pscustomobject]@{
                    Conta = $id.Conta; ContaHabilitada = $usuario.accountEnabled; SkuPartNumber = $nome; SkuId = $s.skuId
                    CandidataAuditPremium = $candidata
                    Observacao = $(if ($candidata) { 'SKU candidata; validar direitos do produto.' } else { 'Não classificada como candidata pelo nome.' })
                }
            }
        })
    $temPremium = @($licencas | Where-Object CandidataAuditPremium).Count -gt 0

    $modulo = Import-ExchangeModulo
    Write-BizappLog 'Conectando ao Security & Compliance...'
    try {
        Connect-IPPSSession -AccessToken $tokenScc -UserPrincipalName $id.Conta -ShowBanner:$false -ErrorAction Stop 3>$null | Out-Null
    } catch {
        # Alguns ambientes aceitam o token do Exchange Online no Security & Compliance
        Write-BizappLog "Nova tentativa com o login do Exchange Online ($($_.Exception.Message))." -Nivel discreto
        Connect-IPPSSession -AccessToken $tokenExo -UserPrincipalName $id.Conta -ShowBanner:$false -ErrorAction Stop 3>$null | Out-Null
    }
    Write-BizappLog 'Conectando ao Exchange Online...'
    Connect-ExchangeOnline -AccessToken $tokenExo -UserPrincipalName $id.Conta -ShowBanner:$false -ErrorAction Stop 3>$null | Out-Null

    # Mesmas conferencias do original: as duas sessoes no tenant e na conta esperados
    $conexoes = @(Get-ConnectionInformation)
    $exo = $conexoes | Where-Object { $_.State -eq 'Connected' -and $_.IsEopSession -eq $false } | Select-Object -Last 1
    $scc = $conexoes | Where-Object { $_.State -eq 'Connected' -and $_.IsEopSession -eq $true } | Select-Object -Last 1
    if (-not $exo) { throw 'A conexão com o Exchange Online não foi estabelecida.' }
    if (-not $scc) { throw 'A conexão com o Security & Compliance não foi estabelecida.' }
    foreach ($c in $exo, $scc) {
        if (-not [string]::Equals([string]$c.TenantID, [string]$id.TenantId, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Uma sessão administrativa pertence a outro tenant ($($c.TenantID)). Nada foi alterado."
        }
        if ($c.UserPrincipalName -and -not [string]::Equals([string]$c.UserPrincipalName, [string]$id.Conta, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Uma sessão administrativa pertence a outra conta ($($c.UserPrincipalName)). Nada foi alterado."
        }
    }
    # Get-AdminAuditLogConfig tem de vir do Exchange Online (no S&C a auditoria aparece sempre desligada).
    # Get-ConnectionInformation devolve o caminho do modulo temporario; Get-Command, so o nome.
    $origem = (Get-Command Get-AdminAuditLogConfig -ErrorAction Stop).ModuleName
    if ($exo.ModuleName -and $origem -ne (Split-Path -Leaf $exo.ModuleName)) {
        throw 'A leitura da auditoria não está vindo do Exchange Online; o resultado sairia errado. Nada foi alterado.'
    }
    Write-BizappLog 'Exchange Online e Security & Compliance conectados.' -Nivel sucesso

    return [pscustomobject]@{
        Identidade = $id; Licencas = $licencas; TemPremium = $temPremium; VersaoModulo = [string]$modulo.Version
        TenantExchange = $exo.TenantID; TenantPurview = $scc.TenantID
    }
}

function Disconnect-AuditoriaCopilot {
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue 3>$null | Out-Null } catch { }
}

function Get-ConfiguracaoUal {
    $c = Get-AdminAuditLogConfig -ErrorAction Stop
    return [pscustomobject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime()
        UnifiedAuditLogIngestionEnabled = $c.UnifiedAuditLogIngestionEnabled
        AdminAuditLogEnabled = $c.AdminAuditLogEnabled
        AdminAuditLogAgeLimit = $c.AdminAuditLogAgeLimit
    }
}

function Get-PoliticasRetencao {
    <# Politicas de retencao de auditoria, no formato do original (politicas-antes/depois.csv). #>
    $lista = @(Get-UnifiedAuditLogRetentionPolicy -ErrorAction Stop | Sort-Object Priority)
    return @(foreach ($p in $lista) {
            [pscustomobject]@{
                Name = $p.Name; Priority = $p.Priority; RetentionDuration = $p.RetentionDuration
                RecordTypes = @($p.RecordTypes) -join ';'; Operations = @($p.Operations) -join ';'
                UserIds = @($p.UserIds) -join ';'; Identity = $p.Identity
            }
        })
}

function Export-PoliticasRetencao {
    param([string]$Pasta, [string]$Nome, [object[]]$Politicas)
    if (@($Politicas).Count) { Export-BizappEvidencia -Pasta $Pasta -Nome $Nome -Dados @($Politicas); return }
    Export-BizappEvidencia -Pasta $Pasta -Nome $Nome -Dados ([pscustomobject]@{
            DataHoraUtc = (Get-Date).ToUniversalTime(); Resultado = 'Sem registros'; Quantidade = 0
            Observacao = 'Nenhuma política personalizada de retenção foi encontrada.' })
}

function Get-TextoPolitica {
    <# Situacao da politica do item para a tela. #>
    param([object[]]$Politicas, [string]$Nome)
    $p = Find-PoliticaPorNome -Politicas $Politicas -Nome $Nome
    if (-not $p) { return 'Não existe' }
    return "$(Get-TextoDuracao $p.RetentionDuration) · prioridade $($p.Priority)"
}

function Search-EventosCopilot {
    <#
    Eventos CopilotInteraction dos ultimos N dias (como o original: paginas de 5.000 ate 50.000).
    Nao grava AuditData bruto, prompts, respostas nem conteudo: so os campos de resumo.
    #>
    param([Parameter(Mandatory)][int]$Dias)
    $inicio = (Get-Date).AddDays(-$Dias)
    $fim = Get-Date
    $sessao = "AUTO31-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $brutos = @()
    $maximo = 50000
    do {
        $pagina = @(Search-UnifiedAuditLog -StartDate $inicio -EndDate $fim -RecordType CopilotInteraction -SessionId $sessao `
                -SessionCommand ReturnLargeSet -ResultSize 5000 -ErrorAction Stop)
        if ($pagina.Count) {
            $brutos += $pagina
            Write-BizappLog "$($brutos.Count) eventos lidos..." -Nivel discreto
        }
    } while ($pagina.Count -gt 0 -and $brutos.Count -lt $maximo)
    $brutos = @($brutos | Sort-Object Identity -Unique)

    return @(foreach ($r in $brutos) {
            $json = $null; $parse = 'Não processado'
            try { $json = $r.AuditData | ConvertFrom-Json -ErrorAction Stop; $parse = 'Concluído' } catch { $parse = 'Falha no parsing' }
            $recursos = 0; $appHost = ''; $workload = ''; $status = ''
            if ($json) {
                $workload = [string](Get-SafeProperty $json 'Workload')
                $status = [string](Get-SafeProperty $json 'ResultStatus')
                $dados = Get-SafeProperty $json 'CopilotEventData'
                if ($dados) {
                    $appHost = [string](Get-SafeProperty $dados 'AppHost')
                    $recursos = @(Get-SafeProperty $dados 'AccessedResources').Count
                }
            }
            [pscustomobject]@{
                CreationDate = $r.CreationDate; UserId = $r.UserIds; Operation = $r.Operations; RecordType = $r.RecordType
                Workload = $workload; ApplicationHost = $appHost; ResultStatus = $status; AccessedResourceCount = $recursos
                EventId = $r.Identity; JsonParseStatus = $parse
            }
        })
}

# Os comandos do Exchange/S&C so sao chamados dentro deste modulo: o Connect-* importa a sessao no
# escopo de quem chama, entao chamar daqui funciona seja ela global ou so deste modulo.

function Set-IngestaoUal {
    param([Parameter(Mandatory)][bool]$Ligada)
    Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $Ligada -Confirm:$false -ErrorAction Stop 3>$null | Out-Null
}

function Set-PoliticaRetencaoCopilot {
    <# Cria ou atualiza a politica (mesmos parametros do original). Devolve 'Criada' ou 'Atualizada'. #>
    param([Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)][string]$Duracao, [Parameter(Mandatory)][int]$Prioridade, [object]$Existente)
    if ($null -eq $Existente) {
        New-UnifiedAuditLogRetentionPolicy -Name $Nome -Description $script:DESCRICAO_POLITICA -RecordTypes CopilotInteraction `
            -RetentionDuration $Duracao -Priority $Prioridade -Confirm:$false -ErrorAction Stop | Out-Null
        return 'Criada'
    }
    Set-UnifiedAuditLogRetentionPolicy -Identity $Existente.Identity -Description $script:DESCRICAO_POLITICA -RecordTypes CopilotInteraction `
        -RetentionDuration $Duracao -Priority $Prioridade -Confirm:$false -ErrorAction Stop | Out-Null
    return 'Atualizada'
}

function Remove-PoliticaRetencaoCopilot {
    param([Parameter(Mandatory)][object]$Existente)
    Remove-UnifiedAuditLogRetentionPolicy -Identity $Existente.Identity -Confirm:$false -ErrorAction Stop | Out-Null
}

function Find-PoliticaPorNome {
    param([object[]]$Politicas, [string]$Nome)
    return @($Politicas) | Where-Object { [string]::Equals([string]$_.Name, $Nome, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
}

function Write-ContextoAuditoria {
    param([string]$Pasta, [object]$Ctx, [string]$Acao, [System.Collections.IDictionary]$Extras = @{})
    $dados = [ordered]@{
        DataHoraUtc = (Get-Date).ToUniversalTime(); Item = 'AUTO-31'; Acao = $Acao
        TenantEsperado = $Ctx.Identidade.TenantId; TenantExchange = $Ctx.TenantExchange; TenantPurview = $Ctx.TenantPurview
        Conta = $Ctx.Identidade.Conta; PowerShellVersion = [string]$PSVersionTable.PSVersion; VersaoModuloExchange = $Ctx.VersaoModulo
        LicencaAuditPremiumCandidata = $Ctx.TemPremium
    }
    foreach ($k in $Extras.Keys) { $dados[$k] = $Extras[$k] }
    Export-BizappEvidencia -Pasta $Pasta -Nome 'contexto.csv' -Dados ([pscustomobject]$dados)
    if (@($Ctx.Licencas).Count) {
        Export-BizappEvidencia -Pasta $Pasta -Nome 'licencas-conta.csv' -Dados @($Ctx.Licencas)
    } else {
        Export-BizappEvidencia -Pasta $Pasta -Nome 'licencas-conta.csv' -Dados ([pscustomobject]@{
                DataHoraUtc = (Get-Date).ToUniversalTime(); Resultado = 'Sem registros'; Quantidade = 0; Observacao = 'Nenhuma licença atribuída foi retornada.' })
    }
}

function Write-ResumoAuditoria {
    <# resumo.csv / resumo.json no formato do original; interrompe se a validacao falhou. #>
    param([string]$Pasta, [string]$Acao, [object]$Ctx, [bool]$Aprovada, [bool]$Alterou, [System.Collections.IDictionary]$Extras = @{}, [string]$Erro = '')
    $resumo = [ordered]@{
        DataHoraUtc = (Get-Date).ToUniversalTime(); Item = 'AUTO-31'; AcaoSolicitada = $Acao
        AlteracaoExecutada = $Alterou; ValidacaoAprovada = $Aprovada
    }
    foreach ($k in $Extras.Keys) { $resumo[$k] = $Extras[$k] }
    $resumo.LicencaAuditPremiumCandidata = $Ctx.TemPremium
    $resumo.Erro = $Erro
    $resumo.PastaEvidencias = $Pasta
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject]$resumo)
    [pscustomobject]$resumo | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Pasta 'resumo.json') -Encoding utf8
    if (-not $Aprovada) { throw 'A validação final não foi aprovada. Veja resumo.csv na pasta de evidências.' }
}

Export-ModuleMember -Variable ITEM, DESCRICAO_POLITICA -Function Get-SafeProperty, Get-TextoDuracao, Connect-AuditoriaCopilot, `
    Disconnect-AuditoriaCopilot, Get-ConfiguracaoUal, Get-PoliticasRetencao, Export-PoliticasRetencao, Get-TextoPolitica, `
    Search-EventosCopilot, Set-IngestaoUal, Set-PoliticaRetencaoCopilot, Remove-PoliticaRetencaoCopilot, Find-PoliticaPorNome, `
    Write-ContextoAuditoria, Write-ResumoAuditoria
