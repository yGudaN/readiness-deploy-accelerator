<#
COE-IA-010 - Inventario PAYG Copilot Studio por Ambiente
SOMENTE LEITURA. Nao cria, altera ou remove Billing Plans.

Objetivo:
- Descobrir Tenant ID automaticamente
- Obter token para Power Platform API
- Listar Billing Policies PAYG do tenant
- Listar ambientes vinculados a cada policy
- Resolver nome/tipo do ambiente
- Consultar MCSMessages via allocationsV2/availability
- Exibir uma tabela consolidada

Observacao importante:
- Billing Policy classica nao expoe, neste endpoint, um campo de budget/limite monetario.
- Portanto Limite/Orcamento fica N/A no inventario classico.
- MCSMessagesDisponiveis e a capacidade retornada por allocationsV2/availability; nao e custo PAYG em moeda.
#>

$ErrorActionPreference = 'Stop'
$ApiBaseUrl = 'https://api.powerplatform.com'
$ApiVersion = '2024-10-01'
$EntitlementId = 'MCSMessages'

function Step([string]$Text) {
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Ensure-Module([string]$Name) {
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Host "Instalando $Name..." -ForegroundColor Yellow
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $Name -WarningAction SilentlyContinue -ErrorAction Stop
}

function Convert-Token($Value) {
    if ($Value -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $Value).Password
    }
    return [string]$Value
}

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

try {
    Step 'DEPENDENCIAS'
    Ensure-Module 'Az.Accounts'
    Ensure-Module 'Microsoft.PowerApps.Administration.PowerShell'

    Step 'LOGIN E TENANT'
    Connect-AzAccount | Out-Null
    $AzContext = Get-AzContext
    $TenantId = $AzContext.Tenant.Id
    $Account = $AzContext.Account.Id
    if (-not $TenantId) { throw 'Tenant ID nao identificado.' }
    Write-Host "Conta     : $Account" -ForegroundColor Green
    Write-Host "Tenant ID : $TenantId" -ForegroundColor Green

    Step 'TOKEN POWER PLATFORM API'
    $AccessToken = Get-AzAccessToken -ResourceUrl "$ApiBaseUrl/" -TenantId $TenantId
    $Token = Convert-Token $AccessToken.Token
    if ([string]::IsNullOrWhiteSpace($Token)) { throw 'Token nao obtido.' }
    $Headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    Write-Host "Token obtido. Expira em $($AccessToken.ExpiresOn)" -ForegroundColor Green

    Step 'AMBIENTES POWER PLATFORM'
    Add-PowerAppsAccount | Out-Null
    $Environments = @(Get-AdminPowerAppEnvironment)
    $EnvById = @{}
    foreach ($e in $Environments) { $EnvById[$e.EnvironmentName] = $e }
    Write-Host "$($Environments.Count) ambientes encontrados." -ForegroundColor Green

    Step 'BILLING POLICIES PAYG'
    $PoliciesUri = "$ApiBaseUrl/licensing/billingPolicies?api-version=$ApiVersion"
    $Policies = @(Get-AllApiValues -Uri $PoliciesUri -Headers $Headers)
    if ($Policies.Count -eq 0) {
        Write-Host 'Nenhuma Billing Policy PAYG encontrada no tenant.' -ForegroundColor Yellow
        return
    }
    Write-Host "$($Policies.Count) Billing Policies encontradas." -ForegroundColor Green

    $Rows = @()

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
            Write-Warning "Nao foi possivel listar ambientes da policy '$PolicyName' ($PolicyId)."
            continue
        }

        foreach ($Link in $Linked) {
            $EnvironmentId = [string]$Link.environmentId
            $env = $EnvById[$EnvironmentId]
            $EnvironmentName = if ($env) { $env.DisplayName } else { '(nome nao resolvido)' }
            $EnvironmentType = if ($env) { $env.EnvironmentType } else { '' }

            $CreditsAvailable = $null
            $CreditsStatus = 'Nao consultado'
            try {
                $FilterText = "environmentId eq '$EnvironmentId' and EntitlementId in ('$EntitlementId')"
                $Filter = [uri]::EscapeDataString($FilterText)
                $AvailabilityUri = "$ApiBaseUrl/licensing/allocationsV2/availability?api-version=$ApiVersion&`$filter=$Filter"
                $Availability = Invoke-RestMethod -Method GET -Uri $AvailabilityUri -Headers $Headers
                $MCS = @($Availability.entitlementAllocationsAvailable) | Where-Object { $_.entitlementId -eq $EntitlementId } | Select-Object -First 1
                if ($MCS) {
                    $CreditsAvailable = $MCS.availableQuantity
                    $CreditsStatus = 'OK'
                } else {
                    $CreditsStatus = 'MCSMessages nao retornado'
                }
            } catch {
                $CreditsStatus = 'Falha na consulta'
            }

            $Rows += [PSCustomObject]@{
                Ambiente = $EnvironmentName
                Tipo = $EnvironmentType
                EnvironmentId = $EnvironmentId
                PAYG = if ($PolicyStatus -eq 'Enabled') { 'Ativo' } else { $PolicyStatus }
                BillingPolicy = $PolicyName
                PolicyId = $PolicyId
                AzureSubscription = $SubscriptionId
                ResourceGroup = $ResourceGroup
                MCSMessagesDisponiveis = $CreditsAvailable
                LimiteOrcamento = 'N/A - Billing Plan classico'
                ConsultaCredits = $CreditsStatus
            }
        }
    }

    Step 'INVENTARIO PAYG COPILOT STUDIO'
    if ($Rows.Count -eq 0) {
        Write-Host 'Billing Policies existem, mas nenhum ambiente vinculado foi retornado.' -ForegroundColor Yellow
        return
    }

    $Rows | Sort-Object Ambiente | Format-Table Ambiente, Tipo, PAYG, BillingPolicy, MCSMessagesDisponiveis, LimiteOrcamento -AutoSize

    Write-Host ""
    Write-Host 'Observacao:' -ForegroundColor Yellow
    Write-Host '- MCSMessagesDisponiveis vem de allocationsV2/availability e nao representa gasto PAYG em moeda.'
    Write-Host '- O endpoint classico de Billing Policy nao retorna um budget/limite monetario; por isso o campo aparece como N/A.'

    $Export = (Read-Host 'Deseja exportar a lista para CSV? SIM ou NAO').Trim().ToUpper()
    if ($Export -eq 'SIM') {
        $CsvPath = Join-Path (Get-Location) 'COE-IA-010_Inventario_PAYG.csv'
        $Rows | Sort-Object Ambiente | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "CSV criado: $CsvPath" -ForegroundColor Green
    }

    Step 'VALIDACAO CONCLUIDA'
    Write-Host 'Nenhuma configuracao foi alterada.' -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
}
finally {
    $Token = $null
    $Headers = $null
}
