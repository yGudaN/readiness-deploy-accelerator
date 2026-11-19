#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-04 · Inventario PAYG do Copilot Studio por ambiente. SOMENTE LEITURA: nao cria, altera ou
    remove Billing Plans.

.DESCRIPTION
    Logica do script original (testes-manuais/originais/04-inventario-payg.ps1, COE-IA-010),
    adaptada ao instalador: os logins vem do instalador (sem Az.Accounts nem Add-PowerAppsAccount)
    e o CSV vai sempre para a pasta de evidencias (sem a pergunta do Read-Host). Mesmas chamadas:
      - GET /licensing/billingPolicies (paginado) e /billingPolicies/{id}/environments;
      - nome e tipo do ambiente pela lista do admin do Power Platform;
      - GET /licensing/allocationsV2/availability com o filtro de MCSMessages, por ambiente.
    Observacoes do original: a Billing Policy classica nao expoe budget/limite (fica N/A) e
    MCSMessages disponiveis e capacidade, nao gasto PAYG em moeda.
    NAO testado num tenant com PAYG (ver PENDENCIAS.md).
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
$entrada = Read-BizappEntrada

$ApiBaseUrl = 'https://api.powerplatform.com'
$ApiVersion = '2024-10-01'
$EntitlementId = 'MCSMessages'

function Get-AllApiValues([string]$Uri, [hashtable]$Headers) {
    $all = @()
    $next = $Uri
    while ($next) {
        $r = Invoke-RestMethod -Method GET -Uri $next -Headers $Headers
        if ($null -ne $r.value) { $all += @($r.value) } else { $all += @($r) }
        $next = $r.'@odata.nextLink'
    }
    return $all
}

$tokenAdmin = Get-BizappToken -Entrada $entrada -Nome Admin
$Token = Get-BizappToken -Entrada $entrada -Nome PowerPlatform
$id = Get-BizappIdentidade -Token $Token
$pasta = New-BizappEvidencias -Item 'Inventario-PAYG' -Acao 'Inventario'
Write-BizappLog "Conta     : $($id.Conta)" -Nivel sucesso
Write-BizappLog "Tenant ID : $($id.TenantId)" -Nivel sucesso
$Headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }

try {
    # Ambientes (o original usa Get-AdminPowerAppEnvironment; aqui a mesma lista do admin)
    $EnvById = @{}
    $url = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2021-04-01'
    while ($url) {
        $r = Invoke-RestMethod -Method GET -Uri $url -Headers @{ Authorization = "Bearer $tokenAdmin"; Accept = 'application/json' }
        foreach ($e in @($r.value)) { if ($e) { $EnvById[[string]$e.name] = [pscustomobject]@{ DisplayName = $e.properties.displayName; EnvironmentType = $e.properties.environmentSku } } }
        $url = [string]$r.nextLink
    }
    Write-BizappLog "$($EnvById.Count) ambientes encontrados."

    $PoliciesUri = "$ApiBaseUrl/licensing/billingPolicies?api-version=$ApiVersion"
    try { $Policies = @(Get-AllApiValues -Uri $PoliciesUri -Headers $Headers) }
    catch {
        $codigo = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        throw "Falha ao listar as Billing Policies (HTTP $codigo). É preciso ser Administrador do Power Platform ou Administrador Global. $($_.ErrorDetails.Message)"
    }

    $Rows = @()
    if ($Policies.Count -eq 0) {
        Write-BizappLog 'Nenhuma Billing Policy PAYG encontrada no tenant.' -Nivel aviso
    } else {
        Write-BizappLog "$($Policies.Count) Billing Policies encontradas." -Nivel sucesso
    }

    foreach ($Policy in $Policies) {
        $PolicyId = [string]$Policy.id
        $PolicyName = [string]$Policy.name
        $PolicyStatus = [string]$Policy.status
        $SubscriptionId = [string]$Policy.billingInstrument.subscriptionId
        $ResourceGroup = [string]$Policy.billingInstrument.resourceGroup

        try {
            $LinkedUri = "$ApiBaseUrl/licensing/billingPolicies/$PolicyId/environments?api-version=$ApiVersion"
            $Linked = @(Get-AllApiValues -Uri $LinkedUri -Headers $Headers)
        } catch {
            Write-BizappLog "Não foi possível listar os ambientes da policy '$PolicyName' ($PolicyId)." -Nivel aviso
            continue
        }

        foreach ($Link in $Linked) {
            $EnvironmentId = [string]$Link.environmentId
            $env = $EnvById[$EnvironmentId]
            $EnvironmentName = if ($env) { $env.DisplayName } else { '(nome não resolvido)' }
            $EnvironmentType = if ($env) { $env.EnvironmentType } else { '' }

            $CreditsAvailable = $null
            $CreditsStatus = 'Não consultado'
            try {
                $FilterText = "environmentId eq '$EnvironmentId' and EntitlementId in ('$EntitlementId')"
                $Filter = [uri]::EscapeDataString($FilterText)
                $AvailabilityUri = "$ApiBaseUrl/licensing/allocationsV2/availability?api-version=$ApiVersion&`$filter=$Filter"
                $Availability = Invoke-RestMethod -Method GET -Uri $AvailabilityUri -Headers $Headers
                $MCS = @($Availability.entitlementAllocationsAvailable) | Where-Object { $_.entitlementId -eq $EntitlementId } | Select-Object -First 1
                if ($MCS) { $CreditsAvailable = $MCS.availableQuantity; $CreditsStatus = 'OK' }
                else { $CreditsStatus = 'MCSMessages não retornado' }
            } catch { $CreditsStatus = 'Falha na consulta' }

            $Rows += [PSCustomObject]@{
                Ambiente               = $EnvironmentName
                Tipo                   = $EnvironmentType
                EnvironmentId          = $EnvironmentId
                PAYG                   = if ($PolicyStatus -eq 'Enabled') { 'Ativo' } else { $PolicyStatus }
                BillingPolicy          = $PolicyName
                PolicyId               = $PolicyId
                AzureSubscription      = $SubscriptionId
                ResourceGroup          = $ResourceGroup
                MCSMessagesDisponiveis = $CreditsAvailable
                LimiteOrcamento        = 'N/A - Billing Plan clássico'
                ConsultaCredits        = $CreditsStatus
            }
        }
    }

    if ($Policies.Count -and $Rows.Count -eq 0) { Write-BizappLog 'Billing Policies existem, mas nenhum ambiente vinculado foi retornado.' -Nivel aviso }
    foreach ($row in ($Rows | Sort-Object Ambiente)) {
        Write-BizappLog "  $($row.Ambiente) ($($row.Tipo)) · PAYG $($row.PAYG) · $($row.BillingPolicy) · Copilot Credits: $(if ($null -ne $row.MCSMessagesDisponiveis) { $row.MCSMessagesDisponiveis } else { $row.ConsultaCredits })" -Nivel discreto
    }
    Export-BizappEvidencia -Pasta $pasta -Nome 'COE-IA-010_Inventario_PAYG.csv' -Dados @($Rows | Sort-Object Ambiente)
    Export-BizappEvidencia -Pasta $pasta -Nome 'billing-policies.csv' -Dados @($Policies | ForEach-Object { [pscustomobject]@{ Id = $_.id; Nome = $_.name; Status = $_.status; Subscription = $_.billingInstrument.subscriptionId; ResourceGroup = $_.billingInstrument.resourceGroup } })
    Write-BizappLog 'Copilot Credits disponíveis vêm da consulta de capacidade e não representam gasto PAYG em moeda. A Billing Policy clássica não informa orçamento: por isso o limite aparece como N/A.' -Nivel discreto
    Write-BizappLog 'Nenhuma configuração foi alterada.' -Nivel sucesso

    Set-BizappSaida -Nome 'Conta' -Valor $id.Conta
    # Estado de cada plano em texto (ex.: DisabledBySubscription = assinatura do Azure desativada ou expirada)
    $textosEstado = @{ Enabled = 'ativa'; Disabled = 'desativada'; DisabledBySubscription = 'desativada pela assinatura do Azure' }
    $estados = @($Policies | Group-Object { [string]$_.status } | ForEach-Object {
        $t = if ($textosEstado.ContainsKey($_.Name)) { $textosEstado[$_.Name] } elseif ($_.Name) { $_.Name } else { 'sem estado' }
        "$($_.Count) $t"
    })
    Set-BizappSaida -Nome 'BillingPolicies' -Valor $(if ($Policies.Count) { "$($Policies.Count) ($($estados -join ', '))" } else { 'Nenhuma' })
    if (@($Policies | Where-Object { [string]$_.status -eq 'DisabledBySubscription' }).Count) {
        Write-BizappLog 'Há plano de cobrança desativado pela assinatura do Azure: o pagamento por uso não está cobrando nesses ambientes. Confira a assinatura no portal do Azure.' -Nivel aviso
    }
    Set-BizappSaida -Nome 'AmbientesPayg' -Valor $(if ($Rows.Count) { (($Rows | Sort-Object Ambiente | ForEach-Object { "$($_.Ambiente) ($($_.BillingPolicy))" }) -join '; ') } else { 'Nenhum' })
    Export-BizappEvidencia -Pasta $pasta -Nome 'resumo.csv' -Dados ([pscustomobject]@{
            DataHoraFimUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-04'; Controle = 'Inventário PAYG do Copilot Studio'
            TenantId = $id.TenantId; Conta = $id.Conta; BillingPolicies = $Policies.Count; AmbientesVinculados = $Rows.Count
            AlteracaoExecutada = $false; Resultado = 'Validado'; Detalhe = 'Somente leitura. Nenhuma configuração foi alterada.'
        })
} finally {
    $Token = $null
    $Headers = $null
}
