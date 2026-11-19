# Funcoes do item "Alocacao de Copilot Credits" (AUTO-05).
# Logica do script original (testes-manuais/originais/05-copilot-credits.ps1, COE-IA-009),
# validado pelo autor em teste pratico, adaptada ao instalador: os logins vem do instalador (sem
# Az.Accounts nem Add-PowerAppsAccount) e as respostas vem dos campos das etapas (sem Read-Host).
# Mesmas chamadas, mesmos parametros e mesmo corpo do PUT:
#  - ambientes: lista do admin do Power Platform (o que o Get-AdminPowerAppEnvironment le);
#  - consulta: GET https://api.powerplatform.com/licensing/allocationsV2/availability
#    ?api-version=2024-10-01&$filter=environmentId eq '<id>' and EntitlementId in ('MCSMessages');
#  - alocacao: PUT https://api.powerplatform.com/licensing/allocationsV2?api-version=2024-10-01.
# NAO testado neste repositorio: o tenant de demo nao tem Copilot Credits (ver PENDENCIAS.md).

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'Copilot-Credits'
$script:ApiBaseUrl = 'https://api.powerplatform.com'
$script:ApiVersion = '2024-10-01'
$script:EntitlementId = 'MCSMessages'
$script:BAP = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform'
$script:TokenAdmin = $null
$script:TokenApi = $null

function Connect-CopilotCredits {
    param([Parameter(Mandatory)][hashtable]$Entrada, [switch]$PrimeiraEtapa, [switch]$ComApi)
    $script:TokenAdmin = Get-BizappToken -Entrada $Entrada -Nome Admin
    if ($ComApi) { $script:TokenApi = Get-BizappToken -Entrada $Entrada -Nome PowerPlatform }
    if ($PrimeiraEtapa) { return Get-BizappIdentidade -Token $script:TokenAdmin }
    return Assert-BizappContexto -Token $script:TokenAdmin -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta
}

function Get-Ambientes {
    <# Mesmos campos que o original mostra no menu: nome, tipo e Environment ID. #>
    $itens = [System.Collections.Generic.List[object]]::new()
    $url = "$script:BAP/scopes/admin/environments?api-version=2021-04-01"
    while ($url) {
        $r = Invoke-RestMethod -Method GET -Uri $url -Headers @{ Authorization = "Bearer $script:TokenAdmin"; Accept = 'application/json' }
        foreach ($a in @($r.value)) {
            if ($a) { $itens.Add([pscustomobject]@{ Nome = $a.properties.displayName; Tipo = $a.properties.environmentSku; EnvironmentId = $a.name }) }
        }
        $url = [string]$r.nextLink
    }
    return , @($itens.ToArray() | Sort-Object Nome)
}

function Find-Ambiente {
    <# Ambiente pelo ID ou pelo nome (o original escolhe pelo numero do menu). #>
    param([object[]]$Ambientes, [string]$Texto)
    $t = ([string]$Texto).Trim()
    if (-not $t) { throw 'Informe o ambiente. Nada foi alterado.' }
    $porId = @($Ambientes | Where-Object { $_.EnvironmentId -eq $t })
    if ($porId) { return $porId[0] }
    $porNome = @($Ambientes | Where-Object { [string]::Equals($_.Nome, $t, [StringComparison]::OrdinalIgnoreCase) })
    if ($porNome.Count -gt 1) { throw "Há mais de um ambiente chamado '$t'. Informe o Environment ID. Nada foi alterado." }
    if (-not $porNome) { throw "Ambiente '$t' não encontrado. Confira o nome na lista da consulta. Nada foi alterado." }
    return $porNome[0]
}

function Get-Disponibilidade {
    <# GET allocationsV2/availability para MCSMessages (como o original). Devolve a quantidade disponivel e a resposta. #>
    param([Parameter(Mandatory)][string]$EnvironmentId)
    $FilterText = "environmentId eq '$EnvironmentId' and EntitlementId in ('$script:EntitlementId')"
    $Filter = [uri]::EscapeDataString($FilterText)
    $AvailabilityUri = "$script:ApiBaseUrl/licensing/allocationsV2/availability?api-version=$script:ApiVersion&`$filter=$Filter"
    $Headers = @{ Authorization = "Bearer $script:TokenApi"; Accept = 'application/json' }
    try {
        $Availability = Invoke-RestMethod -Method GET -Uri $AvailabilityUri -Headers $Headers
    } catch {
        $codigo = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        throw "Falha ao consultar allocationsV2/availability (HTTP $codigo). $($_.ErrorDetails.Message)"
    }
    # Aceita pequenas variacoes de shape da resposta (igual ao original)
    $AvailableItems = @()
    if ($Availability.entitlementAllocationsAvailable) { $AvailableItems = @($Availability.entitlementAllocationsAvailable) }
    elseif ($Availability.value) { $AvailableItems = @($Availability.value) }
    $MCS = $AvailableItems | Where-Object { $_.entitlementId -eq $script:EntitlementId -or $_.EntitlementId -eq $script:EntitlementId } | Select-Object -First 1
    $quantidade = $null
    if ($MCS) { $quantidade = if ($null -ne $MCS.availableQuantity) { [decimal]$MCS.availableQuantity } else { [decimal]$MCS.AvailableQuantity } }
    return [pscustomobject]@{ Disponivel = $quantidade; Resposta = $Availability }
}

function Get-AlocacaoAmbiente {
    <#
        Le a alocacao atual do ambiente: GET licensing/allocationsByEnvironment/{id} (api-version 2024-10-01).
        A disponibilidade (allocationsV2/availability) e o que ainda pode ir para o ambiente e nao
        mostra o que ja esta nele; por isso a conferencia da alocacao usa esta leitura.
        Devolve $null se a leitura falhar (a etapa segue so com a disponibilidade).
    #>
    param([Parameter(Mandatory)][string]$EnvironmentId)
    $uri = "$script:ApiBaseUrl/licensing/allocationsByEnvironment/$EnvironmentId`?api-version=$script:ApiVersion"
    try {
        $r = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $script:TokenApi"; Accept = 'application/json' }
    } catch {
        $codigo = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if ($codigo -eq 404) { return [pscustomobject]@{ Alocado = [decimal]0; TenantPool = $null; Resposta = $null } }
        Write-BizappLog "Não foi possível ler a alocação atual do ambiente (HTTP $codigo)." -Nivel aviso
        return $null
    }
    $mcs = @($r.currencyAllocations) | Where-Object { [string]$_.currencyType -eq $script:EntitlementId } | Select-Object -First 1
    $alocado = if ($mcs -and $null -ne $mcs.allocated) { [decimal]$mcs.allocated } else { [decimal]0 }
    $regra = if ($mcs) { @($mcs.enforcementRules) | Where-Object { [string]$_.ruleType -eq 'TenantPool' } | Select-Object -First 1 }
    $pool = if ($regra) { [bool]$regra.enabled } else { $null }
    return [pscustomobject]@{ Alocado = $alocado; TenantPool = $pool; Resposta = $r }
}

function Format-TenantPool([object]$Valor) {
    if ($null -eq $Valor) { 'sem regra definida (padrão: usa a capacidade do tenant)' } elseif ($Valor) { 'continua usando a capacidade do tenant' } else { 'para no limite alocado' }
}

function Set-Alocacao {
    <# PUT allocationsV2 com o mesmo corpo do original. #>
    param([Parameter(Mandatory)][string]$EnvironmentId, [Parameter(Mandatory)][decimal]$CreditQuantity, [Parameter(Mandatory)][bool]$TenantPool)
    $BodyObject = @{
        scope                 = @{ environmentId = $EnvironmentId }
        allocatedEntitlements = @(
            @{
                entitlementId    = $script:EntitlementId
                allocation       = @{ quantity = $CreditQuantity }
                enforcementRules = @(@{ ruleType = 'TenantPool'; enabled = $TenantPool })
            }
        )
    }
    $Body = $BodyObject | ConvertTo-Json -Depth 10
    $AllocationUri = "$script:ApiBaseUrl/licensing/allocationsV2?api-version=$script:ApiVersion"
    $Headers = @{ Authorization = "Bearer $script:TokenApi"; Accept = 'application/json' }
    try {
        return Invoke-RestMethod -Method PUT -Uri $AllocationUri -Headers $Headers -ContentType 'application/json' -Body $Body
    } catch {
        $codigo = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        $msg = [string]$_.ErrorDetails.Message
        if ($msg -match 'TenantPoolLockedByPolicy') {
            throw "A opção de usar a capacidade do tenant é controlada por uma regra de grupo de ambientes (TenantPoolLockedByPolicy). Altere a regra do grupo ou tire o ambiente do grupo. Nada foi alterado."
        }
        if ($msg -match 'InvalidAllocationRequest') {
            throw "O serviço recusou a quantidade (InvalidAllocationRequest). No teste do roteiro, 20 foi recusado e 5000 foi aceito. $msg"
        }
        throw "Falha ao alocar Copilot Credits (HTTP $codigo). $msg"
    }
}

function Write-ResumoCredits {
    param([string]$Pasta, [string]$Acao, [object]$Identidade, [bool]$Aprovada, [bool]$Alterou, [string]$Detalhe, [System.Collections.IDictionary]$Extras = @{})
    $resumo = [ordered]@{
        DataHoraFimUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-05'; Controle = 'Alocação de Copilot Credits por ambiente'
        AcaoSolicitada = $Acao; TenantId = $Identidade.TenantId; Conta = $Identidade.Conta
    }
    foreach ($k in $Extras.Keys) { $resumo[$k] = $Extras[$k] }
    $resumo.AlteracaoExecutada = $Alterou
    $resumo.ValidacaoAprovada = $Aprovada
    $resumo.Resultado = $(if ($Aprovada) { 'Validado' } else { 'Falha' })
    $resumo.Detalhe = $Detalhe
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject]$resumo)
    if (-not $Aprovada) { throw $Detalhe }
}

function Format-Creditos([object]$Valor) { if ($null -eq $Valor) { 'Não encontrado' } else { ([decimal]$Valor).ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('pt-BR')) } }

Export-ModuleMember -Variable ITEM -Function Connect-CopilotCredits, Get-Ambientes, Find-Ambiente, Get-Disponibilidade, Get-AlocacaoAmbiente, Format-TenantPool, Set-Alocacao, Write-ResumoCredits, Format-Creditos
