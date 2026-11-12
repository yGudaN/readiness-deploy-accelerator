<#
# OBJETIVO:
# Validar e provar a automação de políticas de alerta de atividade no Microsoft Purview,
# incluindo consulta, criação de política agregada simples ou anômala, habilitação,
# desabilitação e geração de evidências.
#
# FERRAMENTA:
# Microsoft Graph PowerShell + Security & Compliance PowerShell
# (ExchangeOnlineManagement / Connect-IPPSSession).
#
# PERMISSÃO:
# Microsoft Graph: User.Read.All, Organization.Read.All e RoleManagement.Read.Directory.
# Microsoft Purview: View-Only Manage Alerts para consulta; Manage Alerts ou
# Organization Configuration para criar e alterar políticas.
#
# EFEITO:
# A ação Consultar é read-only. As ações CriarSimples, CriarAnomala, Habilitar e
# Desabilitar alteram uma política de alerta customizada no tenant de laboratório.
#
# RECURSO-ALVO:
# Política customizada com nome iniciado por LAB-AUTO30-.
#
# PARÂMETROS EDITÁVEIS:
# Acao, ExpectedTenantId, ExpectedAdminUpn, AlertName, Operation, NotifyUser,
# Threshold, TimeWindow e EvidenceRoot.
#
# EVIDÊNCIAS:
# Cria uma pasta por execução com execucao.log, contexto.csv, modulos-comandos.csv,
# funcoes-administrativas.csv, licencas-tenant.csv, configuracao-antes.csv,
# configuracao-depois.csv e resumo.csv.
#
# RISCOS:
# Uma política habilitada pode gerar alertas e notificações. AnomalousAggregation
# pode levar até 7 dias para estabelecer a linha de base e não gera alertas nesse período.
#
# ATENÇÃO:
# Execute apenas no tenant de laboratório. Mudanças exigem -ConfirmarAlteracao.
# O script não remove políticas. Políticas padrão não são alteradas.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Consultar', 'CriarSimples', 'CriarAnomala', 'Habilitar', 'Desabilitar')]
    [string]$Acao,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ExpectedTenantId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$ExpectedAdminUpn,

    [Parameter()]
    [ValidatePattern('^LAB-AUTO30-[A-Za-z0-9._ -]+$')]
    [string]$AlertName = 'LAB-AUTO30-Atividade-Anomala-SearchRemoved',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Operation = 'SearchRemoved',

    [Parameter()]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$NotifyUser,

    [Parameter()]
    [ValidateRange(3, 2147483647)]
    [int]$Threshold = 50,

    [Parameter()]
    [ValidateRange(61, 2147483647)]
    [int]$TimeWindow = 120,

    [Parameter()]
    [bool]$ConfirmarAlteracao = $false,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Justificativa = 'Prova controlada do item AUTO-30 no tenant de laboratório.',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$EvidenceRoot = 'C:\Users\PedroFrei\Documents\OneDrive - Bizapp\Documentos\Projetos\coe-validacao-scripts\evidencias'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function ConvertTo-SafeText {
    param(
        [AllowNull()]
        [object]$Value,

        [int]$MaximumLength = 1000
    )

    if ($null -eq $Value) {
        return ''
    }

    $text = if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        (($Value | ForEach-Object { [string]$_ }) -join '; ')
    }
    else {
        [string]$Value
    }

    $text = $text -replace '[\r\n\t]+', ' '

    if ($text.Length -gt $MaximumLength) {
        return $text.Substring(0, $MaximumLength)
    }

    return $text
}

function Export-CsvSafe {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    @($InputObject) |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
}

function Get-FirstPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        $property = $InputObject.PSObject.Properties[$propertyName]

        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }

    return $null
}

function Get-AlertSnapshot {
    param(
        [AllowNull()]
        [object]$Alert,

        [Parameter(Mandatory = $true)]
        [string]$Stage
    )

    if ($null -eq $Alert) {
        return [pscustomobject]@{
            DataHoraUtc        = (Get-Date).ToUniversalTime().ToString('o')
            Etapa              = $Stage
            Encontrada         = $false
            Name               = $AlertName
            Identity           = ''
            Category           = ''
            ThreatType         = ''
            Operation          = ''
            AggregationType    = ''
            AlertBy            = ''
            Threshold          = ''
            TimeWindow         = ''
            Severity           = ''
            Disabled           = ''
            NotificationEnabled = ''
            NotifyUser         = ''
            Description        = ''
            Comment            = ''
        }
    }

    return [pscustomobject]@{
        DataHoraUtc         = (Get-Date).ToUniversalTime().ToString('o')
        Etapa               = $Stage
        Encontrada          = $true
        Name                = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('Name'))
        Identity            = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('Identity', 'Guid', 'DistinguishedName'))
        Category            = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('Category'))
        ThreatType          = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('ThreatType'))
        Operation           = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('Operation'))
        AggregationType     = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('AggregationType'))
        AlertBy             = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('AlertBy'))
        Threshold           = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('Threshold'))
        TimeWindow          = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('TimeWindow'))
        Severity            = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('Severity'))
        Disabled            = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('Disabled'))
        NotificationEnabled = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('NotificationEnabled'))
        NotifyUser          = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('NotifyUser'))
        Description         = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('Description'))
        Comment             = ConvertTo-SafeText (Get-FirstPropertyValue $Alert @('Comment'))
    }
}

function Get-TargetAlert {
    $allAlerts = @(Get-ProtectionAlert -ErrorAction Stop)
    $matches = @($allAlerts | Where-Object { [string]$_.Name -eq $AlertName })

    if ($matches.Count -gt 1) {
        throw "Mais de uma política foi localizada com o nome exato '$AlertName'."
    }

    if ($matches.Count -eq 1) {
        return $matches[0]
    }

    return $null
}

$isChangeAction = $Acao -ne 'Consultar'

if ($isChangeAction -and -not $ConfirmarAlteracao) {
    throw 'A ação solicitada altera o tenant. Execute novamente com -ConfirmarAlteracao $true.'
}

if ($isChangeAction -and $AlertName -notlike 'LAB-AUTO30-*') {
    throw 'Alterações são permitidas somente em políticas com prefixo LAB-AUTO30-.'
}

if ([string]::IsNullOrWhiteSpace($NotifyUser)) {
    $NotifyUser = $ExpectedAdminUpn
}

$executionStart = Get-Date
$timestamp = $executionStart.ToString('yyyyMMdd-HHmmss')
$itemEvidenceRoot = Join-Path -Path $EvidenceRoot -ChildPath 'AUTO-30-Alertas-Atividade-Anomala'
$evidenceDirectory = Join-Path -Path $itemEvidenceRoot -ChildPath $timestamp

New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

$transcriptPath = Join-Path $evidenceDirectory 'execucao.log'
$contextPath = Join-Path $evidenceDirectory 'contexto.csv'
$commandsPath = Join-Path $evidenceDirectory 'modulos-comandos.csv'
$rolesPath = Join-Path $evidenceDirectory 'funcoes-administrativas.csv'
$licensesPath = Join-Path $evidenceDirectory 'licencas-tenant.csv'
$beforePath = Join-Path $evidenceDirectory 'configuracao-antes.csv'
$afterPath = Join-Path $evidenceDirectory 'configuracao-depois.csv'
$summaryPath = Join-Path $evidenceDirectory 'resumo.csv'

$transcriptStarted = $false
$result = 'Falha'
$validationApproved = $false
$changeExecuted = $false
$resultDetail = ''
$beforeAlert = $null
$afterAlert = $null

try {
    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $transcriptStarted = $true

    Write-Host ''
    Write-Host '====================================================='
    Write-Host ' AUTO-30 - ALERTAS DE ATIVIDADE ANÔMALA'
    Write-Host '====================================================='
    Write-Host "Ação: $Acao"
    Write-Host "Tenant esperado: $ExpectedTenantId"
    Write-Host "Conta esperada: $ExpectedAdminUpn"
    Write-Host "Política-alvo: $AlertName"
    Write-Host "Operação auditada: $Operation"
    Write-Host "Notificação: $NotifyUser"
    Write-Host "Evidências: $evidenceDirectory"

    $requiredModules = @(
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Users',
        'Microsoft.Graph.Identity.DirectoryManagement',
        'Microsoft.Graph.Identity.Governance',
        'ExchangeOnlineManagement'
    )

    $moduleEvidence = foreach ($moduleName in $requiredModules) {
        $module = Get-Module -ListAvailable -Name $moduleName |
            Sort-Object Version -Descending |
            Select-Object -First 1

        [pscustomobject]@{
            Tipo       = 'Modulo'
            Nome       = $moduleName
            Disponivel = ($null -ne $module)
            Versao     = if ($null -ne $module) { [string]$module.Version } else { '' }
            Origem     = if ($null -ne $module) { [string]$module.Path } else { '' }
        }
    }

    $requiredCommands = @(
        'Get-MgContext',
        'Get-MgUser',
        'Get-MgSubscribedSku',
        'Get-MgRoleManagementDirectoryRoleAssignment',
        'Get-MgRoleManagementDirectoryRoleDefinition',
        'Get-ConnectionInformation',
        'Get-ProtectionAlert',
        'New-ProtectionAlert',
        'Set-ProtectionAlert'
    )

    $commandEvidence = foreach ($commandName in $requiredCommands) {
        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue

        [pscustomobject]@{
            Tipo       = 'Comando'
            Nome       = $commandName
            Disponivel = ($null -ne $command)
            Versao     = ''
            Origem     = if ($null -ne $command) { [string]$command.Source } else { '' }
        }
    }

    Export-CsvSafe -InputObject @($moduleEvidence + $commandEvidence) -Path $commandsPath

    $missingModules = @($moduleEvidence | Where-Object { -not $_.Disponivel })
    if ($missingModules.Count -gt 0) {
        throw "Módulos ausentes: $(($missingModules.Nome) -join ', ')."
    }

    $graphRequiredCommands = @(
        'Get-MgContext',
        'Get-MgUser',
        'Get-MgSubscribedSku',
        'Get-MgRoleManagementDirectoryRoleAssignment',
        'Get-MgRoleManagementDirectoryRoleDefinition'
    )

    $missingGraphCommands = @(
        $commandEvidence |
            Where-Object { $_.Nome -in $graphRequiredCommands -and -not $_.Disponivel }
    )

    if ($missingGraphCommands.Count -gt 0) {
        throw "Comandos do Graph ausentes: $(($missingGraphCommands.Nome) -join ', ')."
    }

    $graphContext = Get-MgContext
    if ($null -eq $graphContext) {
        throw 'Não existe sessão ativa do Microsoft Graph. Execute primeiro 01-conectar-graph.ps1.'
    }

    if (-not [string]::Equals(
        [string]$graphContext.TenantId,
        [string]$ExpectedTenantId,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "A sessão Graph pertence ao tenant '$($graphContext.TenantId)', diferente do esperado."
    }

    if (-not [string]::Equals(
        [string]$graphContext.Account,
        [string]$ExpectedAdminUpn,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "A sessão Graph pertence à conta '$($graphContext.Account)', diferente da esperada."
    }

    $requiredScopes = @(
        'User.Read.All',
        'Organization.Read.All',
        'RoleManagement.Read.Directory'
    )

    $missingScopes = @(
        $requiredScopes |
            Where-Object { $_ -notin @($graphContext.Scopes) }
    )

    if ($missingScopes.Count -gt 0) {
        throw "Escopos Graph ausentes: $(($missingScopes) -join ', ')."
    }

    $adminUser = Get-MgUser `
        -UserId $ExpectedAdminUpn `
        -Property @(
            'Id',
            'DisplayName',
            'UserPrincipalName',
            'AccountEnabled',
            'AssignedLicenses'
        ) `
        -ErrorAction Stop

    if (-not $adminUser.AccountEnabled) {
        throw 'A conta administrativa esperada está desabilitada.'
    }

    $roleAssignments = @()
    try {
        $roleAssignments = @(
            Get-MgRoleManagementDirectoryRoleAssignment `
                -Filter "principalId eq '$($adminUser.Id)'" `
                -All `
                -ErrorAction Stop
        )
    }
    catch {
        $roleAssignments = @(
            Get-MgRoleManagementDirectoryRoleAssignment -All -ErrorAction Stop |
                Where-Object { [string]$_.PrincipalId -eq [string]$adminUser.Id }
        )
    }

    $roleDefinitions = @(
        Get-MgRoleManagementDirectoryRoleDefinition -All -ErrorAction Stop
    )

    $roleEvidence = foreach ($assignment in $roleAssignments) {
        $definition = $roleDefinitions |
            Where-Object { [string]$_.Id -eq [string]$assignment.RoleDefinitionId } |
            Select-Object -First 1

        [pscustomobject]@{
            Conta            = $ExpectedAdminUpn
            PrincipalId      = $adminUser.Id
            Funcao           = if ($null -ne $definition) { $definition.DisplayName } else { 'Não resolvida' }
            RoleDefinitionId = $assignment.RoleDefinitionId
            RoleAssignmentId = $assignment.Id
            DirectoryScopeId = $assignment.DirectoryScopeId
        }
    }

    if ($roleEvidence.Count -eq 0) {
        $roleEvidence = @(
            [pscustomobject]@{
                Conta            = $ExpectedAdminUpn
                PrincipalId      = $adminUser.Id
                Funcao           = 'Nenhuma função Entra ativa localizada'
                RoleDefinitionId = ''
                RoleAssignmentId = ''
                DirectoryScopeId = ''
            }
        )
    }

    Export-CsvSafe -InputObject @($roleEvidence) -Path $rolesPath

    $subscribedSkus = @(Get-MgSubscribedSku -All -ErrorAction Stop)
    $assignedSkuIds = @($adminUser.AssignedLicenses | ForEach-Object { [string]$_.SkuId })

    $licenseEvidence = foreach ($sku in $subscribedSkus) {
        [pscustomobject]@{
            SkuPartNumber          = $sku.SkuPartNumber
            SkuId                  = $sku.SkuId
            Capacidade             = $sku.CapabilityStatus
            UnidadesAtivas         = $sku.PrepaidUnits.Enabled
            UnidadesUsadas         = $sku.ConsumedUnits
            AtribuidaContaExecucao = ([string]$sku.SkuId -in $assignedSkuIds)
            CandidataAlertasAvancados = (
                [string]$sku.SkuPartNumber -match
                'E5|G5|A5|ENTERPRISEPREMIUM|SPE_E5|M365.*E5|Microsoft_365_E5'
            )
        }
    }

    Export-CsvSafe -InputObject @($licenseEvidence) -Path $licensesPath

    $advancedAlertLicenseFound = @(
        $licenseEvidence |
            Where-Object {
                $_.CandidataAlertasAvancados -and
                [string]$_.Capacidade -eq 'Enabled'
            }
    ).Count -gt 0

    $connectionCommand = Get-Command -Name 'Get-ConnectionInformation' -ErrorAction SilentlyContinue
    if ($null -eq $connectionCommand) {
        throw 'Get-ConnectionInformation não está disponível. Execute 05-conectar-purview.ps1.'
    }

    $purviewConnections = @(
        Get-ConnectionInformation -ErrorAction Stop |
            Where-Object {
                ($_.State -eq 'Connected') -and
                (
                    ($_.IsEopSession -eq $true) -or
                    ([string]$_.ConnectionUri -match 'compliance\.protection\.outlook\.com')
                )
            }
    )

    if ($purviewConnections.Count -eq 0) {
        throw 'Nenhuma sessão ativa do Security & Compliance PowerShell foi localizada.'
    }

    $purviewConnection = $purviewConnections | Select-Object -Last 1

    if (-not [string]::Equals(
        [string]$purviewConnection.TenantID,
        [string]$ExpectedTenantId,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "A sessão Purview pertence ao tenant '$($purviewConnection.TenantID)', diferente do esperado."
    }

    if (-not [string]::Equals(
        [string]$purviewConnection.UserPrincipalName,
        [string]$ExpectedAdminUpn,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "A sessão Purview pertence à conta '$($purviewConnection.UserPrincipalName)', diferente da esperada."
    }

    $getAvailable = $null -ne (Get-Command Get-ProtectionAlert -ErrorAction SilentlyContinue)
    $newAvailable = $null -ne (Get-Command New-ProtectionAlert -ErrorAction SilentlyContinue)
    $setAvailable = $null -ne (Get-Command Set-ProtectionAlert -ErrorAction SilentlyContinue)

    if (-not $getAvailable) {
        throw 'Get-ProtectionAlert não foi publicado na sessão. Valide View-Only Manage Alerts.'
    }

    if ($Acao -in @('CriarSimples', 'CriarAnomala') -and -not $newAvailable) {
        throw 'New-ProtectionAlert não foi publicado na sessão. Valide Manage Alerts ou Organization Configuration.'
    }

    if ($Acao -in @('Habilitar', 'Desabilitar') -and -not $setAvailable) {
        throw 'Set-ProtectionAlert não foi publicado na sessão. Valide Manage Alerts ou Organization Configuration.'
    }

    $contextEvidence = [pscustomobject]@{
        DataHoraUtc                  = (Get-Date).ToUniversalTime().ToString('o')
        Item                         = 'AUTO-30'
        Acao                         = $Acao
        TenantIdEsperado             = $ExpectedTenantId
        TenantIdGraph                = $graphContext.TenantId
        TenantIdPurview              = $purviewConnection.TenantID
        ContaEsperada                = $ExpectedAdminUpn
        ContaGraph                   = $graphContext.Account
        ContaPurview                 = $purviewConnection.UserPrincipalName
        ContaHabilitada              = $adminUser.AccountEnabled
        EscoposGraph                 = (@($graphContext.Scopes) -join '; ')
        FuncoesEntra                 = (@($roleEvidence.Funcao) -join '; ')
        GetProtectionAlertDisponivel = $getAvailable
        NewProtectionAlertDisponivel = $newAvailable
        SetProtectionAlertDisponivel = $setAvailable
        LicencaAvancadaCandidata     = $advancedAlertLicenseFound
        ConfirmarAlteracao           = $ConfirmarAlteracao
        AlertName                    = $AlertName
        Operation                    = $Operation
        NotifyUser                   = $NotifyUser
        Threshold                    = $Threshold
        TimeWindow                   = $TimeWindow
        Justificativa                = $Justificativa
    }

    Export-CsvSafe -InputObject @($contextEvidence) -Path $contextPath

    $beforeAlert = Get-TargetAlert
    Export-CsvSafe -InputObject @(
        Get-AlertSnapshot -Alert $beforeAlert -Stage 'Antes'
    ) -Path $beforePath

    switch ($Acao) {
        'Consultar' {
            $resultDetail = if ($null -eq $beforeAlert) {
                'Consulta concluída. A política-alvo não existe.'
            }
            else {
                'Consulta concluída. A política-alvo foi localizada.'
            }
        }

        'CriarSimples' {
            if (-not $advancedAlertLicenseFound) {
                throw 'Nenhuma licença candidata para alertas agregados avançados foi localizada no tenant.'
            }

            if ($null -ne $beforeAlert) {
                $resultDetail = 'A política já existia; nenhuma criação foi executada.'
            }
            else {
                New-ProtectionAlert `
                    -Name $AlertName `
                    -Category ThreatManagement `
                    -ThreatType Activity `
                    -Operation $Operation `
                    -NotifyUser $NotifyUser `
                    -NotificationEnabled $true `
                    -AggregationType SimpleAggregation `
                    -AlertBy User `
                    -Threshold $Threshold `
                    -TimeWindow $TimeWindow `
                    -Severity Medium `
                    -Description 'Política de laboratório para prova controlada do AUTO-30.' `
                    -Comment $Justificativa `
                    -Disabled $false `
                    -ErrorAction Stop

                $changeExecuted = $true
                $resultDetail = 'Política agregada simples criada e habilitada.'
            }
        }

        'CriarAnomala' {
            if (-not $advancedAlertLicenseFound) {
                throw 'Nenhuma licença candidata para alertas anômalos avançados foi localizada no tenant.'
            }

            if ($null -ne $beforeAlert) {
                $resultDetail = 'A política já existia; nenhuma criação foi executada.'
            }
            else {
                New-ProtectionAlert `
                    -Name $AlertName `
                    -Category ThreatManagement `
                    -ThreatType Activity `
                    -Operation $Operation `
                    -NotifyUser $NotifyUser `
                    -NotificationEnabled $true `
                    -AggregationType AnomalousAggregation `
                    -AlertBy User `
                    -Severity Medium `
                    -Description 'Política de laboratório para detecção de volume anômalo de atividade.' `
                    -Comment $Justificativa `
                    -Disabled $false `
                    -ErrorAction Stop

                $changeExecuted = $true
                $resultDetail = 'Política de agregação anômala criada e habilitada; linha de base pendente.'
            }
        }

        'Habilitar' {
            if ($null -eq $beforeAlert) {
                throw "A política '$AlertName' não existe."
            }

            if ([string]$beforeAlert.Disabled -eq 'False') {
                $resultDetail = 'A política já estava habilitada; nenhuma alteração foi executada.'
            }
            else {
                Set-ProtectionAlert `
                    -Identity $beforeAlert.Identity `
                    -Disabled $false `
                    -ErrorAction Stop

                $changeExecuted = $true
                $resultDetail = 'Política habilitada.'
            }
        }

        'Desabilitar' {
            if ($null -eq $beforeAlert) {
                throw "A política '$AlertName' não existe."
            }

            if ([string]$beforeAlert.Disabled -eq 'True') {
                $resultDetail = 'A política já estava desabilitada; nenhuma alteração foi executada.'
            }
            else {
                Set-ProtectionAlert `
                    -Identity $beforeAlert.Identity `
                    -Disabled $true `
                    -ErrorAction Stop

                $changeExecuted = $true
                $resultDetail = 'Política desabilitada.'
            }
        }
    }

    Start-Sleep -Seconds 5
    $afterAlert = Get-TargetAlert

    Export-CsvSafe -InputObject @(
        Get-AlertSnapshot -Alert $afterAlert -Stage 'Depois'
    ) -Path $afterPath

    switch ($Acao) {
        'Consultar' {
            $validationApproved = $true
        }

        'CriarSimples' {
            $validationApproved = (
                $null -ne $afterAlert -and
                [string]$afterAlert.AggregationType -eq 'SimpleAggregation' -and
                [int]$afterAlert.Threshold -eq $Threshold -and
                [int]$afterAlert.TimeWindow -eq $TimeWindow -and
                [string]$afterAlert.Disabled -eq 'False'
            )
        }

        'CriarAnomala' {
            $validationApproved = (
                $null -ne $afterAlert -and
                [string]$afterAlert.AggregationType -eq 'AnomalousAggregation' -and
                [string]$afterAlert.Disabled -eq 'False'
            )
        }

        'Habilitar' {
            $validationApproved = (
                $null -ne $afterAlert -and
                [string]$afterAlert.Disabled -eq 'False'
            )
        }

        'Desabilitar' {
            $validationApproved = (
                $null -ne $afterAlert -and
                [string]$afterAlert.Disabled -eq 'True'
            )
        }
    }

    if (-not $validationApproved) {
        throw 'A consulta posterior não confirmou o estado esperado.'
    }

    $result = if ($Acao -eq 'CriarAnomala') {
        'Configuração validada; disparo depende da linha de base'
    }
    else {
        'Validado'
    }
}
catch {
    $result = 'Falha'
    $resultDetail = ConvertTo-SafeText $_.Exception.Message
    Write-Warning $resultDetail
}
finally {
    $executionEnd = Get-Date

    $summary = [pscustomobject]@{
        DataHoraInicioUtc    = $executionStart.ToUniversalTime().ToString('o')
        DataHoraFimUtc       = $executionEnd.ToUniversalTime().ToString('o')
        Item                 = 'AUTO-30'
        Controle             = 'Alertas de atividade anômala'
        AcaoSolicitada       = $Acao
        TenantId             = $ExpectedTenantId
        Conta                = $ExpectedAdminUpn
        AlertName            = $AlertName
        Operation            = $Operation
        AggregationType      = if ($Acao -eq 'CriarAnomala') {
            'AnomalousAggregation'
        }
        elseif ($Acao -eq 'CriarSimples') {
            'SimpleAggregation'
        }
        elseif ($null -ne $afterAlert) {
            ConvertTo-SafeText $afterAlert.AggregationType
        }
        else {
            ''
        }
        Threshold            = if ($Acao -eq 'CriarSimples') { $Threshold } else { '' }
        TimeWindow           = if ($Acao -eq 'CriarSimples') { $TimeWindow } else { '' }
        AlteracaoExecutada   = $changeExecuted
        ValidacaoAprovada    = $validationApproved
        Resultado            = $result
        Detalhe              = $resultDetail
        Justificativa        = $Justificativa
        PastaEvidencias      = $evidenceDirectory
        Observacao           = if (-not $validationApproved) {
            'A execução foi interrompida antes da validação final. Consulte Detalhe e execucao.log.'
        }
        elseif ($Acao -eq 'CriarAnomala') {
            'A política foi validada administrativamente. A linha de base anômala pode levar até 7 dias.'
        }
        else {
            'A validação administrativa foi concluída por consulta posterior.'
        }
    }

    Export-CsvSafe -InputObject @($summary) -Path $summaryPath

    Write-Host ''
    Write-Host '====================================================='
    Write-Host ' RESULTADO DA PROVA'
    Write-Host '====================================================='
    $summary | Format-List
    Write-Host '====================================================='

    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}

if (-not $validationApproved) {
    throw "AUTO-30 não foi validado. Consulte '$summaryPath' e '$transcriptPath'."
}

[pscustomobject]@{
    Resultado  = $result
    Detalhe    = $resultDetail
    Evidencias = $evidenceDirectory
}