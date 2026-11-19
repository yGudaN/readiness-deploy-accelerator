<#
COE-IA-009 - Validacao automatica de Copilot Credits
Objetivo: descobrir tenant, ambientes e capacidade automaticamente.
O usuario apenas autentica, escolhe o ambiente pelo numero e, opcionalmente, confirma a alocacao.

Requisitos:
- Windows PowerShell 5.1
- Az.Accounts
- Microsoft.PowerApps.Administration.PowerShell
- Conta com permissoes administrativas no Power Platform
#>

$ErrorActionPreference = "Stop"
$ApiBaseUrl = "https://api.powerplatform.com"
$ApiVersion = "2024-10-01"
$EntitlementId = "MCSMessages"

function Write-Step($Text) {
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Ensure-Module($Name) {
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Host "Instalando $Name..." -ForegroundColor Yellow
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $Name -WarningAction SilentlyContinue -ErrorAction Stop
}

function Convert-SecureToken($Token) {
    if ($Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new("", $Token).Password
    }
    return [string]$Token
}

try {
    Write-Step "DEPENDENCIAS"
    Ensure-Module "Az.Accounts"
    Ensure-Module "Microsoft.PowerApps.Administration.PowerShell"

    Write-Step "LOGIN"
    Connect-AzAccount | Out-Null

    # Descobre tenant e usuario automaticamente
    $AzContext = Get-AzContext
    $TenantId = $AzContext.Tenant.Id
    $Account = $AzContext.Account.Id

    if (-not $TenantId) { throw "Tenant ID nao identificado." }

    Write-Host "Conta     : $Account" -ForegroundColor Green
    Write-Host "Tenant ID : $TenantId" -ForegroundColor Green

    # Token automatico para Power Platform API
    Write-Step "TOKEN POWER PLATFORM API"
    $AccessToken = Get-AzAccessToken -ResourceUrl "$ApiBaseUrl/" -TenantId $TenantId
    $Token = Convert-SecureToken $AccessToken.Token

    if ([string]::IsNullOrWhiteSpace($Token)) { throw "Token nao obtido." }

    $Headers = @{
        Authorization = "Bearer $Token"
        Accept = "application/json"
    }

    Write-Host "Token obtido. Expira em $($AccessToken.ExpiresOn)" -ForegroundColor Green

    # Conecta Power Platform Admin usando a mesma conta interativamente
    Write-Step "AMBIENTES"
    Add-PowerAppsAccount | Out-Null

    $Environments = @(Get-AdminPowerAppEnvironment | Sort-Object DisplayName)
    if ($Environments.Count -eq 0) { throw "Nenhum ambiente encontrado." }

    # Cria menu numerico automaticamente
    $EnvironmentMenu = for ($i = 0; $i -lt $Environments.Count; $i++) {
        [PSCustomObject]@{
            Numero = $i + 1
            Nome = $Environments[$i].DisplayName
            Tipo = $Environments[$i].EnvironmentType
            EnvironmentId = $Environments[$i].EnvironmentName
        }
    }

    $EnvironmentMenu | Format-Table Numero, Nome, Tipo, EnvironmentId -AutoSize

    [int]$Selection = Read-Host "Escolha o NUMERO do ambiente"
    if ($Selection -lt 1 -or $Selection -gt $Environments.Count) {
        throw "Selecao invalida."
    }

    # Todas as variaveis seguintes sao extraidas automaticamente
    $Environment = $Environments[$Selection - 1]
    $EnvironmentId = $Environment.EnvironmentName
    $EnvironmentName = $Environment.DisplayName
    $EnvironmentType = $Environment.EnvironmentType

    Write-Host ""
    Write-Host "Ambiente      : $EnvironmentName" -ForegroundColor Green
    Write-Host "Environment ID: $EnvironmentId" -ForegroundColor Green
    Write-Host "Tipo          : $EnvironmentType" -ForegroundColor Green

    # Consulta capacidade
    Write-Step "COPILOT CREDITS"
    $FilterText = "environmentId eq '$EnvironmentId' and EntitlementId in ('$EntitlementId')"
    $Filter = [uri]::EscapeDataString($FilterText)
    $AvailabilityUri = "$ApiBaseUrl/licensing/allocationsV2/availability?api-version=$ApiVersion&`$filter=$Filter"

    try {
        $Availability = Invoke-RestMethod -Method GET -Uri $AvailabilityUri -Headers $Headers
    }
    catch {
        Write-Host "Falha ao consultar allocationsV2/availability." -ForegroundColor Red
        if ($_.Exception.Response) {
            try { Write-Host "HTTP: $([int]$_.Exception.Response.StatusCode)" -ForegroundColor Red } catch {}
        }
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
        throw
    }

    # Aceita pequenas variacoes de shape da resposta
    $AvailableItems = @()
    if ($Availability.entitlementAllocationsAvailable) {
        $AvailableItems = @($Availability.entitlementAllocationsAvailable)
    } elseif ($Availability.value) {
        $AvailableItems = @($Availability.value)
    }

    $MCS = $AvailableItems | Where-Object {
        $_.entitlementId -eq $EntitlementId -or $_.EntitlementId -eq $EntitlementId
    } | Select-Object -First 1

    if (-not $MCS) {
        Write-Host "A API respondeu, mas MCSMessages nao foi encontrado." -ForegroundColor Yellow
        Write-Host "Resposta para diagnostico:" -ForegroundColor Yellow
        $Availability | ConvertTo-Json -Depth 10 | Write-Host
        return
    }

    $AvailableQuantity = if ($null -ne $MCS.availableQuantity) {
        [decimal]$MCS.availableQuantity
    } else {
        [decimal]$MCS.AvailableQuantity
    }

    Write-Host "Copilot Credits disponiveis: $AvailableQuantity" -ForegroundColor Green

    # Primeiro permite validar apenas a leitura
    $Allocate = (Read-Host "Deseja testar a ALOCACAO? SIM ou NAO").Trim().ToUpper()
    if ($Allocate -ne "SIM") {
        Write-Host ""
        Write-Host "VALIDACAO DE LEITURA CONCLUIDA." -ForegroundColor Green
        Write-Host "Nenhuma alteracao foi realizada."
        return
    }

    [decimal]$CreditQuantity = Read-Host "Quantidade de Copilot Credits a alocar"
    if ($CreditQuantity -lt 0) { throw "Quantidade invalida." }
    if ($CreditQuantity -gt $AvailableQuantity) {
        throw "Solicitado $CreditQuantity, mas a disponibilidade retornada e $AvailableQuantity."
    }

    $TenantPoolText = (Read-Host "Permitir consumo do pool do tenant apos esgotar a alocacao? SIM ou NAO").Trim().ToUpper()
    if ($TenantPoolText -notin @("SIM","NAO")) { throw "Resposta invalida." }
    $TenantPool = ($TenantPoolText -eq "SIM")

    Write-Step "RESUMO"
    Write-Host "Tenant        : $TenantId"
    Write-Host "Ambiente      : $EnvironmentName"
    Write-Host "Environment ID: $EnvironmentId"
    Write-Host "Disponivel    : $AvailableQuantity"
    Write-Host "Alocar        : $CreditQuantity"
    Write-Host "TenantPool    : $TenantPool"

    $Confirm = (Read-Host "Digite ALOCAR para executar").Trim().ToUpper()
    if ($Confirm -ne "ALOCAR") {
        Write-Host "Operacao cancelada." -ForegroundColor Yellow
        return
    }

    $BodyObject = @{
        scope = @{
            environmentId = $EnvironmentId
        }
        allocatedEntitlements = @(
            @{
                entitlementId = $EntitlementId
                allocation = @{
                    quantity = $CreditQuantity
                }
                enforcementRules = @(
                    @{
                        ruleType = "TenantPool"
                        enabled = $TenantPool
                    }
                )
            }
        )
    }

    $Body = $BodyObject | ConvertTo-Json -Depth 10
    $AllocationUri = "$ApiBaseUrl/licensing/allocationsV2?api-version=$ApiVersion"

    Write-Step "ALOCACAO"
    try {
        $AllocationResult = Invoke-RestMethod -Method PUT -Uri $AllocationUri -Headers $Headers -ContentType "application/json" -Body $Body
        Write-Host "Alocacao enviada com sucesso." -ForegroundColor Green
    }
    catch {
        Write-Host "Falha ao alocar Copilot Credits." -ForegroundColor Red
        if ($_.Exception.Response) {
            try { Write-Host "HTTP: $([int]$_.Exception.Response.StatusCode)" -ForegroundColor Red } catch {}
        }
        if ($_.ErrorDetails.Message) {
            Write-Host $_.ErrorDetails.Message -ForegroundColor Red
            if ($_.ErrorDetails.Message -match "TenantPoolLockedByPolicy") {
                Write-Host "TenantPool esta controlado por uma Environment Group Rule." -ForegroundColor Yellow
            }
        }
        throw
    }

    # Valida novamente a API
    Write-Step "VALIDACAO FINAL"
    $After = Invoke-RestMethod -Method GET -Uri $AvailabilityUri -Headers $Headers

    if ($After.entitlementAllocationsAvailable) {
        $After.entitlementAllocationsAvailable |
            Select-Object entitlementId, availableQuantity |
            Format-Table -AutoSize
    } else {
        $After | ConvertTo-Json -Depth 10 | Write-Host
    }

    Write-Host "VALIDACAO CONCLUIDA." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "O script foi interrompido sem executar passos posteriores." -ForegroundColor Yellow
}
finally {
    $Token = $null
    $Headers = $null
}
