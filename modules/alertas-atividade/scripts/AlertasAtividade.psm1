# Funcoes do AUTO-30 (politicas de alerta de atividade no Microsoft Purview), trazidas do script
# validado no laboratorio (testes-manuais/originais/30-alertas-anomalos.ps1, teste de 11/11/2026).
# Diferencas:
#   - logins pelo instalador: Graph (conta, funcoes e licencas por chamadas REST, sem os modulos
#     do Graph) e Security & Compliance (Connect-IPPSSession -AccessToken, modulo 3.8 ou superior);
#   - no lugar do prefixo obrigatorio LAB-AUTO30-, as politicas criadas aqui levam uma marca no
#     comentario, e so elas podem ser ligadas, desligadas ou removidas. Politicas padrao da
#     Microsoft e as criadas por outras pessoas nunca sao alteradas;
#   - nova acao para remover a politica (no teste foi feita a mao com Remove-ProtectionAlert).

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'Alertas-Atividade'
$script:VERSAO_MINIMA_EXO = [version]'3.8.0'   # -AccessToken no Connect-IPPSSession
$script:ESCOPOS_GRAPH = @('User.Read.All', 'Organization.Read.All', 'RoleManagement.Read.Directory')
$script:MARCA = 'Criada pelo Readiness Deploy Accelerator'

function Get-FirstPropertyValue {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string[]]$PropertyNames)
    if ($null -eq $InputObject) { return $null }
    foreach ($n in $PropertyNames) {
        $p = $InputObject.PSObject.Properties[$n]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    }
    return $null
}

function ConvertTo-SafeText {
    param([AllowNull()][object]$Value, [int]$MaximumLength = 1000)
    if ($null -eq $Value) { return '' }
    $text = if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { (($Value | ForEach-Object { [string]$_ }) -join '; ') } else { [string]$Value }
    $text = $text -replace '[\r\n\t]+', ' '
    if ($text.Length -gt $MaximumLength) { return $text.Substring(0, $MaximumLength) }
    return $text
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
    Import-Module -Name $m.Path -Force -Global -ErrorAction Stop -WarningAction SilentlyContinue 3>$null | Out-Null
    Write-BizappLog "Exchange Online PowerShell $($m.Version)" -Nivel discreto
    return $m
}

function Connect-AlertasAtividade {
    <#
    Confere conta, funcoes e licencas pelo Graph (token do instalador) e conecta o Security &
    Compliance com o token do instalador. Devolve o contexto da execucao.
    #>
    param([Parameter(Mandatory)][hashtable]$Entrada)

    $tokenGraph = Get-BizappToken -Entrada $Entrada -Nome Graph
    $id = Assert-BizappContexto -Token $tokenGraph -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta
    $faltando = @($script:ESCOPOS_GRAPH | Where-Object { $_ -notin $id.Escopos })
    if ($faltando) { throw "O login não tem as permissões necessárias: $($faltando -join ', ')." }
    $tokenScc = Get-BizappToken -Entrada $Entrada -Nome Purview
    $tokenExo = Get-BizappToken -Entrada $Entrada -Nome Exchange
    $null = Assert-BizappContexto -Token $tokenExo -TenantEsperado $id.TenantId -ContaEsperada $id.Conta

    $usuario = Invoke-GraphRest -Token $tokenGraph -Caminho "users/$([uri]::EscapeDataString($id.Conta))?`$select=id,displayName,userPrincipalName,accountEnabled,assignedLicenses"
    if ($usuario.accountEnabled -ne $true) { throw 'A conta administrativa está desabilitada.' }

    # Funcoes (so registro, como no original)
    $atribuicoes = @((Invoke-GraphRest -Token $tokenGraph -Caminho "roleManagement/directory/roleAssignments?`$filter=principalId eq '$($usuario.id)'&`$expand=roleDefinition").value)
    $funcoes = @(foreach ($a in $atribuicoes) {
            [pscustomobject]@{ Conta = $id.Conta; PrincipalId = $usuario.id; Funcao = $(if ($a.roleDefinition) { $a.roleDefinition.displayName } else { 'Não resolvida' })
                RoleDefinitionId = $a.roleDefinitionId; RoleAssignmentId = $a.id; DirectoryScopeId = $a.directoryScopeId }
        })
    if (-not $funcoes) {
        $funcoes = @([pscustomobject]@{ Conta = $id.Conta; PrincipalId = $usuario.id; Funcao = 'Nenhuma função Entra ativa localizada'
                RoleDefinitionId = ''; RoleAssignmentId = ''; DirectoryScopeId = '' })
    }

    # Licencas do tenant (mesma heuristica do original, pelo nome do SKU)
    $atribuidas = @($usuario.assignedLicenses | ForEach-Object { [string]$_.skuId })
    $licencas = @(foreach ($s in @((Invoke-GraphRest -Token $tokenGraph -Caminho 'subscribedSkus').value)) {
            [pscustomobject]@{
                SkuPartNumber = $s.skuPartNumber; SkuId = $s.skuId; Capacidade = $s.capabilityStatus
                UnidadesAtivas = $(if ($s.prepaidUnits) { $s.prepaidUnits.enabled } else { 0 }); UnidadesUsadas = $s.consumedUnits
                AtribuidaContaExecucao = ([string]$s.skuId -in $atribuidas)
                CandidataAlertasAvancados = ([string]$s.skuPartNumber -match 'E5|G5|A5|ENTERPRISEPREMIUM|SPE_E5|M365.*E5|Microsoft_365_E5')
            }
        })
    $temLicenca = @($licencas | Where-Object { $_.CandidataAlertasAvancados -and [string]$_.Capacidade -eq 'Enabled' }).Count -gt 0

    $modulo = Import-ExchangeModulo
    Write-BizappLog 'Conectando ao Security & Compliance...'
    try {
        Connect-IPPSSession -AccessToken $tokenScc -UserPrincipalName $id.Conta -ShowBanner:$false -ErrorAction Stop 3>$null | Out-Null
    } catch {
        Write-BizappLog "Nova tentativa com o login do Exchange Online ($($_.Exception.Message))." -Nivel discreto
        Connect-IPPSSession -AccessToken $tokenExo -UserPrincipalName $id.Conta -ShowBanner:$false -ErrorAction Stop 3>$null | Out-Null
    }
    $scc = @(Get-ConnectionInformation) | Where-Object {
        $_.State -eq 'Connected' -and ($_.IsEopSession -eq $true -or [string]$_.ConnectionUri -match 'compliance\.protection\.outlook\.com')
    } | Select-Object -Last 1
    if (-not $scc) { throw 'A conexão com o Security & Compliance não foi estabelecida.' }
    if (-not [string]::Equals([string]$scc.TenantID, [string]$id.TenantId, [StringComparison]::OrdinalIgnoreCase)) {
        throw "A sessão do Security & Compliance pertence a outro tenant ($($scc.TenantID)). Nada foi alterado."
    }
    if ($scc.UserPrincipalName -and -not [string]::Equals([string]$scc.UserPrincipalName, [string]$id.Conta, [StringComparison]::OrdinalIgnoreCase)) {
        throw "A sessão do Security & Compliance pertence a outra conta ($($scc.UserPrincipalName)). Nada foi alterado."
    }
    if (-not (Get-Command Get-ProtectionAlert -ErrorAction SilentlyContinue)) {
        throw 'A conta não tem permissão para ver as políticas de alerta (função View-Only Manage Alerts ou Manage Alerts no Microsoft Purview).'
    }
    Write-BizappLog 'Security & Compliance conectado.' -Nivel sucesso

    return [pscustomobject]@{
        Identidade = $id; Funcoes = $funcoes; Licencas = $licencas; TemLicenca = $temLicenca
        VersaoModulo = [string]$modulo.Version; TenantPurview = $scc.TenantID; ContaPurview = $scc.UserPrincipalName
        PodeCriar = $null -ne (Get-Command New-ProtectionAlert -ErrorAction SilentlyContinue)
        PodeAlterar = $null -ne (Get-Command Set-ProtectionAlert -ErrorAction SilentlyContinue)
        PodeRemover = $null -ne (Get-Command Remove-ProtectionAlert -ErrorAction SilentlyContinue)
    }
}

function Disconnect-AlertasAtividade {
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue 3>$null | Out-Null } catch { }
}

# Os comandos do Security & Compliance so sao chamados dentro deste modulo: o Connect-IPPSSession
# importa a sessao no escopo de quem chama.

function Get-AlertasTenant {
    return @(Get-ProtectionAlert -ErrorAction Stop)
}

function Test-AlertaDoItem {
    <# Criada por este item: tem a marca no comentario e nao e politica padrao da Microsoft. #>
    param([AllowNull()][object]$Alerta)
    if ($null -eq $Alerta) { return $false }
    if ((Get-FirstPropertyValue $Alerta @('IsSystemRule')) -eq $true) { return $false }
    $texto = "$(Get-FirstPropertyValue $Alerta @('Comment')) $(Get-FirstPropertyValue $Alerta @('Description'))"
    return $texto -like "*$($script:MARCA)*"
}

function Find-AlertaPorNome {
    param([object[]]$Alertas, [Parameter(Mandatory)][string]$Nome)
    $achados = @(@($Alertas) | Where-Object { [string]$_.Name -eq $Nome })
    if ($achados.Count -gt 1) { throw "Mais de uma política foi localizada com o nome exato '$Nome'." }
    if ($achados.Count -eq 1) { return $achados[0] }
    return $null
}

function Get-AlertSnapshot {
    <# Mesmo formato do original (configuracao-antes/depois.csv). #>
    param([AllowNull()][object]$Alert, [Parameter(Mandatory)][string]$Stage, [string]$Nome)
    if ($null -eq $Alert) {
        return [pscustomobject]@{
            DataHoraUtc = (Get-Date).ToUniversalTime().ToString('o'); Etapa = $Stage; Encontrada = $false; Name = $Nome
            Identity = ''; Category = ''; ThreatType = ''; Operation = ''; AggregationType = ''; AlertBy = ''; Threshold = ''; TimeWindow = ''
            Severity = ''; Disabled = ''; NotificationEnabled = ''; NotifyUser = ''; Description = ''; Comment = ''
        }
    }
    $campos = 'Category', 'ThreatType', 'Operation', 'AggregationType', 'AlertBy', 'Threshold', 'TimeWindow', 'Severity', 'Disabled', 'NotificationEnabled', 'NotifyUser', 'Description', 'Comment'
    $s = [ordered]@{
        DataHoraUtc = (Get-Date).ToUniversalTime().ToString('o'); Etapa = $Stage; Encontrada = $true
        Name = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('Name'))
        Identity = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('Identity', 'Guid', 'DistinguishedName'))
    }
    foreach ($c in $campos) { $s[$c] = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @($c)) }
    return [pscustomobject]$s
}

function Get-TextoEstadoAlerta {
    param([AllowNull()][object]$Alerta)
    if ($null -eq $Alerta) { return 'Não existe' }
    $tipo = if ([string]$Alerta.AggregationType -eq 'AnomalousAggregation') { 'atividade incomum' }
            elseif ([string]$Alerta.AggregationType -eq 'SimpleAggregation') { "volume ($($Alerta.Threshold) em $($Alerta.TimeWindow) min)" }
            else { 'cada ocorrência' }
    $estado = if ([string]$Alerta.Disabled -eq 'True') { 'Desligada' } else { 'Ligada' }
    return "$estado · $tipo"
}

function New-AlertaAtividade {
    <# Mesmos parametros do original (CriarSimples / CriarAnomala), com a marca no comentario. #>
    param(
        [Parameter(Mandatory)][ValidateSet('simples', 'anomala')][string]$Tipo,
        [Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)][string]$Operacao, [Parameter(Mandatory)][string]$Notificar,
        [int]$Limite, [int]$Janela, [string]$Justificativa
    )
    $comum = @{
        Name = $Nome; Category = 'ThreatManagement'; ThreatType = 'Activity'; Operation = $Operacao
        NotifyUser = $Notificar; NotificationEnabled = $true; AlertBy = 'User'; Severity = 'Medium'
        Comment = "$($script:MARCA). $Justificativa"; Disabled = $false; ErrorAction = 'Stop'
    }
    if ($Tipo -eq 'simples') {
        New-ProtectionAlert @comum -AggregationType SimpleAggregation -Threshold $Limite -TimeWindow $Janela `
            -Description "Alerta quando o mesmo usuário repete a atividade muitas vezes em pouco tempo. $($script:MARCA)." | Out-Null
    } else {
        New-ProtectionAlert @comum -AggregationType AnomalousAggregation `
            -Description "Alerta quando um usuário foge do próprio padrão de volume desta atividade. $($script:MARCA)." | Out-Null
    }
}

function Set-AlertaLigado {
    param([Parameter(Mandatory)][object]$Alerta, [Parameter(Mandatory)][bool]$Ligado)
    Set-ProtectionAlert -Identity $Alerta.Identity -Disabled (-not $Ligado) -ErrorAction Stop | Out-Null
}

function Remove-AlertaAtividade {
    param([Parameter(Mandatory)][object]$Alerta)
    Remove-ProtectionAlert -Identity $Alerta.Identity -Confirm:$false -ErrorAction Stop | Out-Null
}

function Write-ContextoAlertas {
    param([string]$Pasta, [object]$Ctx, [string]$Acao, [System.Collections.IDictionary]$Extras = @{})
    Export-BizappEvidencia -Pasta $Pasta -Nome 'funcoes-administrativas.csv' -Dados @($Ctx.Funcoes)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'licencas-tenant.csv' -Dados @($Ctx.Licencas)
    $dados = [ordered]@{
        DataHoraUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-30'; Acao = $Acao
        TenantId = $Ctx.Identidade.TenantId; TenantIdPurview = $Ctx.TenantPurview; Conta = $Ctx.Identidade.Conta; ContaPurview = $Ctx.ContaPurview
        EscoposGraph = ($Ctx.Identidade.Escopos -join '; '); FuncoesEntra = (@($Ctx.Funcoes.Funcao) -join '; ')
        NewProtectionAlertDisponivel = $Ctx.PodeCriar; SetProtectionAlertDisponivel = $Ctx.PodeAlterar
        LicencaAvancadaCandidata = $Ctx.TemLicenca; VersaoModuloExchange = $Ctx.VersaoModulo
    }
    foreach ($k in $Extras.Keys) { $dados[$k] = $Extras[$k] }
    Export-BizappEvidencia -Pasta $Pasta -Nome 'contexto.csv' -Dados ([pscustomobject]$dados)
}

function Write-ResumoAlertas {
    <# resumo.csv / resumo.json no formato do original; interrompe se a validacao falhou. #>
    param([string]$Pasta, [string]$Acao, [object]$Ctx, [bool]$Aprovada, [bool]$Alterou, [string]$Resultado, [string]$Detalhe,
        [System.Collections.IDictionary]$Extras = @{})
    $resumo = [ordered]@{
        DataHoraFimUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-30'; Controle = 'Alertas de atividade anômala'
        AcaoSolicitada = $Acao; TenantId = $Ctx.Identidade.TenantId; Conta = $Ctx.Identidade.Conta
    }
    foreach ($k in $Extras.Keys) { $resumo[$k] = $Extras[$k] }
    $resumo.AlteracaoExecutada = $Alterou
    $resumo.ValidacaoAprovada = $Aprovada
    $resumo.Resultado = $Resultado
    $resumo.Detalhe = $Detalhe
    $resumo.PastaEvidencias = $Pasta
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject]$resumo)
    [pscustomobject]$resumo | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Pasta 'resumo.json') -Encoding utf8
    if (-not $Aprovada) { throw 'A consulta posterior não confirmou o estado esperado. Veja resumo.csv na pasta de evidências.' }
}

Export-ModuleMember -Variable ITEM, MARCA -Function ConvertTo-SafeText, Connect-AlertasAtividade, Disconnect-AlertasAtividade, `
    Get-AlertasTenant, Test-AlertaDoItem, Find-AlertaPorNome, Get-AlertSnapshot, Get-TextoEstadoAlerta, New-AlertaAtividade, `
    Set-AlertaLigado, Remove-AlertaAtividade, Write-ContextoAlertas, Write-ResumoAlertas
