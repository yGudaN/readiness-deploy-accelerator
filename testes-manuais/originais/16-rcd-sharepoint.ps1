#requires -Version 7.0
<#
# OBJETIVO:
# Validar os pré-requisitos e consultar, habilitar ou desabilitar
# Restricted Content Discovery em um site do SharePoint Online.
#
# FERRAMENTA:
# Microsoft Graph PowerShell SDK e SharePoint Online Management Shell.
#
# PERMISSÃO:
# Microsoft Graph:
# - User.Read.All
# - Organization.Read.All
# - RoleManagement.Read.Directory
#
# SharePoint:
# - Administrador Global; ou
# - Administrador do SharePoint; ou
# - Administrador do SharePoint Advanced Management.
#
# LICENÇA:
# Assinatura-base compatível e direito ao SharePoint Advanced Management.
# A prova funcional da alteração continua necessária.
#
# EFEITO:
# - Consultar: não altera o site.
# - Habilitar: define RestrictContentOrgWideSearch como True.
# - Desabilitar: define RestrictContentOrgWideSearch como False.
#
# RECURSO-ALVO:
# Um site do SharePoint Online.
# Sites pessoais do OneDrive não são suportados.
#
# PARÂMETROS EDITÁVEIS:
# - SiteUrl
# - Acao
# - Justificativa
# - ConfirmarAlteracao
#
# EVIDÊNCIAS:
# evidencias\AUTO-16-RCD-SharePoint\<data-hora>\
# execucao.log
# contexto.csv
# modulos-comandos.csv
# funcoes-administrativas.csv
# licencas-tenant.csv
# configuracao-antes.csv
# configuracao-depois.csv
# resumo.csv
# erro.txt, quando aplicável
#
# RISCOS:
# A habilitação reduz a descoberta organizacional do conteúdo.
# A propagação para pesquisa e Copilot não é imediata.
#
# ATENÇÃO:
# RCD não altera permissões.
# Usuários que já possuem acesso continuam podendo acessar o conteúdo.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SiteUrl,

    [Parameter(Mandatory = $false)]
    [ValidateSet(
        'Consultar',
        'Habilitar',
        'Desabilitar'
    )]
    [string]$Acao = 'Consultar',

    [Parameter(Mandatory = $false)]
    [string]$Justificativa,

    [Parameter(Mandatory = $false)]
    [switch]$ConfirmarAlteracao
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ''
    Write-Host "==> $Message" `
        -ForegroundColor Cyan
}

function Export-OneRowCsv {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $InputObject |
        Export-Csv `
            -LiteralPath $Path `
            -NoTypeInformation `
            -Encoding utf8
}

function Import-ModuleIfCommandMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [Parameter(Mandatory = $true)]
        [string]$ModuleName
    )

    $ExistingCommand = Get-Command `
        -Name $CommandName `
        -ErrorAction SilentlyContinue

    if ($null -ne $ExistingCommand) {
        Write-Host (
            " Comando já disponível: $CommandName"
        ) -ForegroundColor Green

        return
    }

    $AvailableModule = Get-Module `
        -ListAvailable `
        -Name $ModuleName |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -eq $AvailableModule) {
        throw @"
O módulo abaixo não foi encontrado:

$ModuleName

Comando necessário:
$CommandName
"@
    }

    Write-Host (
        " Carregando módulo: $ModuleName " +
        "$($AvailableModule.Version)"
    ) -ForegroundColor Yellow

    $ImportStart = Get-Date

    Import-Module `
        -Name $ModuleName `
        -ErrorAction Stop

    $ImportEnd = Get-Date
    $ImportDuration = [math]::Round(
        ($ImportEnd - $ImportStart).TotalSeconds,
        2
    )

    $ImportedCommand = Get-Command `
        -Name $CommandName `
        -ErrorAction SilentlyContinue

    if ($null -eq $ImportedCommand) {
        throw @"
O módulo foi importado, mas o comando não ficou disponível.

Módulo:
$ModuleName

Comando:
$CommandName
"@
    }

    Write-Host (
        " Módulo carregado em $ImportDuration segundos."
    ) -ForegroundColor Green
}

function Import-SharePointModuleIfNecessary {
    $RequiredSpoCommands = @(
        'Connect-SPOService',
        'Get-SPOTenant',
        'Get-SPOSite',
        'Set-SPOSite'
    )

    $MissingSpoCommands = @(
        $RequiredSpoCommands |
            Where-Object {
                $null -eq (
                    Get-Command `
                        -Name $_ `
                        -ErrorAction SilentlyContinue
                )
            }
    )

    if ($MissingSpoCommands.Count -eq 0) {
        Write-Host (
            ' Comandos SharePoint já disponíveis. ' +
            'O módulo não será importado novamente.'
        ) -ForegroundColor Green

        return
    }

    Write-Host (
        ' Comandos SharePoint ausentes: ' +
        ($MissingSpoCommands -join ', ')
    ) -ForegroundColor Yellow

    $SharePointModule = Get-Module `
        -ListAvailable `
        -Name Microsoft.Online.SharePoint.PowerShell |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -eq $SharePointModule) {
        throw @'
O módulo Microsoft.Online.SharePoint.PowerShell
não foi encontrado.
'@
    }

    $SharePointModulePath = [string]$SharePointModule.Path

    if (
        [string]::IsNullOrWhiteSpace(
            $SharePointModulePath
        )
    ) {
        throw @'
O módulo do SharePoint foi localizado, mas o caminho
do arquivo de módulo não foi retornado.
'@
    }

    Write-Host (
        ' Importando SharePoint pelo caminho exato:'
    ) -ForegroundColor Yellow
    Write-Host " $SharePointModulePath"

    if ($PSVersionTable.PSEdition -eq 'Core') {
        Import-Module `
            -Name $SharePointModulePath `
            -UseWindowsPowerShell `
            -DisableNameChecking `
            -ErrorAction Stop
    }
    else {
        Import-Module `
            -Name $SharePointModulePath `
            -DisableNameChecking `
            -ErrorAction Stop
    }

    $StillMissing = @(
        $RequiredSpoCommands |
            Where-Object {
                $null -eq (
                    Get-Command `
                        -Name $_ `
                        -ErrorAction SilentlyContinue
                )
            }
    )

    if ($StillMissing.Count -gt 0) {
        throw (
            'Comandos SharePoint ainda ausentes: ' +
            ($StillMissing -join ', ')
        )
    }

    Write-Host (
        ' Módulo SharePoint importado com sucesso.'
    ) -ForegroundColor Green
}

function Get-RcdSiteState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity
    )

    $Site = Get-SPOSite `
        -Identity $Identity `
        -ErrorAction Stop

    $RcdProperty = $Site.PSObject.Properties[
        'RestrictContentOrgWideSearch'
    ]

    if ($null -eq $RcdProperty) {
        throw @'
O site foi consultado, mas a propriedade
RestrictContentOrgWideSearch não foi retornada.

Verifique:
- versão do módulo SharePoint;
- disponibilidade do recurso no tenant;
- função administrativa;
- licenciamento do SharePoint Advanced Management.
'@
    }

    $RawValue = $RcdProperty.Value

    $InterpretedStatus = if ($null -eq $RawValue) {
        'Não determinado'
    }
    elseif ([bool]$RawValue) {
        'Habilitado'
    }
    else {
        'Desabilitado'
    }

    [PSCustomObject]@{
        DataHoraUtc = (
            Get-Date
        ).ToUniversalTime()

        SiteUrl = [string]$Site.Url
        SiteTitle = [string]$Site.Title
        Template = [string]$Site.Template
        StatusSite = [string]$Site.Status
        LockState = [string]$Site.LockState

        RestrictContentOrgWideSearch = $RawValue
        RcdStatus = $InterpretedStatus
    }
}

function Test-SharePointSession {
    try {
        $null = Get-SPOTenant `
            -ErrorAction Stop

        return $true
    }
    catch {
        return $false
    }
}

function Connect-SharePointWhenNecessary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdminUrl,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedAccount
    )

    if (Test-SharePointSession) {
        Write-Host (
            ' Sessão SharePoint existente confirmada. ' +
            'Nenhuma nova autenticação será aberta.'
        ) -ForegroundColor Green

        return
    }

    Write-Host (
        ' Não foi encontrada uma sessão SharePoint válida.'
    ) -ForegroundColor Yellow

    Write-Host (
        ' Será aberta uma nova autenticação.'
    ) -ForegroundColor Yellow

    Write-Host ''
    Write-Host 'Use somente esta conta:' `
        -ForegroundColor Yellow
    Write-Host " $ExpectedAccount" `
        -ForegroundColor Yellow

    $ConnectCommand = Get-Command `
        -Name Connect-SPOService `
        -ErrorAction Stop

    $ConnectParameters = @{
        Url = $AdminUrl
        ErrorAction = 'Stop'
    }

    if (
        $ConnectCommand.Parameters.ContainsKey(
            'UseSystemBrowser'
        )
    ) {
        $ConnectParameters[
            'UseSystemBrowser'
        ] = $true
    }

    Connect-SPOService @ConnectParameters

    if (-not (Test-SharePointSession)) {
        throw @'
A autenticação foi concluída, mas Get-SPOTenant
não confirmou a sessão administrativa.
'@
    }

    Write-Host (
        ' Nova sessão SharePoint confirmada.'
    ) -ForegroundColor Green
}

# =====================================================================
# CARREGAR O PREFLIGHT
# =====================================================================

$ScriptRoot = Split-Path `
    -Parent $MyInvocation.MyCommand.Path

$PreflightPath = Join-Path `
    -Path $ScriptRoot `
    -ChildPath '00-preflight.ps1'

if (-not (Test-Path -LiteralPath $PreflightPath)) {
    throw @"
O arquivo 00-preflight.ps1 não foi encontrado.

Local esperado:
$PreflightPath
"@
}

. $PreflightPath

# =====================================================================
# VALIDAR PARÂMETROS
# =====================================================================

$ParsedSiteUri = $null

$SiteUrlIsValid = [Uri]::TryCreate(
    $SiteUrl,
    [UriKind]::Absolute,
    [ref]$ParsedSiteUri
)

if (
    -not $SiteUrlIsValid -or
    $ParsedSiteUri.Scheme -ne 'https'
) {
    throw @'
SiteUrl deve ser uma URL HTTPS válida
do SharePoint Online.
'@
}

$SiteHost = $ParsedSiteUri.Host.ToLowerInvariant()

if (
    $SiteHost -notmatch
    '\.sharepoint\.(com|us|de|cn)$'
) {
    throw @'
SiteUrl não pertence a um domínio reconhecido
do SharePoint Online.
'@
}

if ($SiteHost -match '-admin\.sharepoint\.') {
    throw @'
Informe a URL do site, não a URL
do SharePoint Admin Center.
'@
}

if ($SiteHost -match '-my\.sharepoint\.') {
    throw @'
Restricted Content Discovery não é suportado
em sites pessoais do OneDrive.
'@
}

$SiteUrlNormalized = $ParsedSiteUri.GetLeftPart(
    [System.UriPartial]::Path
).TrimEnd('/')

$SharePointPrefix = (
    $SiteHost -split '\.'
)[0]

$SharePointAdminUrl = (
    "https://{0}-admin.sharepoint.com" -f
    $SharePointPrefix
)

if ($Acao -ne 'Consultar') {
    if (-not $ConfirmarAlteracao.IsPresent) {
        throw @"
A ação $Acao altera a configuração do site.

Execute novamente incluindo:
-ConfirmarAlteracao
"@
    }

    if ([string]::IsNullOrWhiteSpace($Justificativa)) {
        throw @'
Informe -Justificativa para habilitar ou
desabilitar o recurso.
'@
    }

    if ($Justificativa.Trim().Length -lt 10) {
        throw @'
A justificativa deve ter pelo menos 10 caracteres.
'@
    }
}

# =====================================================================
# PREPARAR EVIDÊNCIAS
# =====================================================================

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$EvidenceRoot = Join-Path `
    -Path $ScriptRoot `
    -ChildPath 'evidencias'

$ItemEvidenceRoot = Join-Path `
    -Path $EvidenceRoot `
    -ChildPath 'AUTO-16-RCD-SharePoint'

$RunEvidenceFolder = Join-Path `
    -Path $ItemEvidenceRoot `
    -ChildPath $Timestamp

New-Item `
    -Path $RunEvidenceFolder `
    -ItemType Directory `
    -Force |
    Out-Null

$TranscriptPath = Join-Path `
    $RunEvidenceFolder `
    'execucao.log'

$ContextPath = Join-Path `
    $RunEvidenceFolder `
    'contexto.csv'

$CommandsPath = Join-Path `
    $RunEvidenceFolder `
    'modulos-comandos.csv'

$RolesPath = Join-Path `
    $RunEvidenceFolder `
    'funcoes-administrativas.csv'

$LicensesPath = Join-Path `
    $RunEvidenceFolder `
    'licencas-tenant.csv'

$BeforePath = Join-Path `
    $RunEvidenceFolder `
    'configuracao-antes.csv'

$AfterPath = Join-Path `
    $RunEvidenceFolder `
    'configuracao-depois.csv'

$SummaryPath = Join-Path `
    $RunEvidenceFolder `
    'resumo.csv'

$ErrorPath = Join-Path `
    $RunEvidenceFolder `
    'erro.txt'

$TranscriptStarted = $false
$ChangeExecuted = $false
$ValidationSucceeded = $false
$BeforeState = $null
$AfterState = $null
$GraphContext = $null
$SignedInUser = $null
$RoleNames = @()
$LicenseAssessment = 'Não validada'
$FunctionalLicenseAssessment = 'Não validada'

try {
    Start-Transcript `
        -LiteralPath $TranscriptPath `
        -Force |
        Out-Null

    $TranscriptStarted = $true

    Write-Host ''
    Write-Host '====================================================='
    Write-Host ' AUTO-16 - RESTRICTED CONTENT DISCOVERY'
    Write-Host '====================================================='
    Write-Host "Ação: $Acao"
    Write-Host "Site: $SiteUrlNormalized"
    Write-Host "Tenant esperado: $TenantId"
    Write-Host "Conta esperada: $AdminUPN"
    Write-Host "Admin Center: $SharePointAdminUrl"
    Write-Host "Evidências: $RunEvidenceFolder"

    # =================================================================
    # 1. VALIDAR/IMPORTAR GRAPH DE FORMA SELETIVA
    # =================================================================

    Write-Step (
        'Validando comandos específicos do Microsoft Graph'
    )

    Import-ModuleIfCommandMissing `
        -CommandName 'Connect-MgGraph' `
        -ModuleName 'Microsoft.Graph.Authentication'

    Import-ModuleIfCommandMissing `
        -CommandName 'Get-MgUser' `
        -ModuleName 'Microsoft.Graph.Users'

    Import-ModuleIfCommandMissing `
        -CommandName 'Get-MgSubscribedSku' `
        -ModuleName (
            'Microsoft.Graph.Identity.DirectoryManagement'
        )

    Import-ModuleIfCommandMissing `
        -CommandName (
            'Get-MgRoleManagementDirectoryRoleAssignment'
        ) `
        -ModuleName 'Microsoft.Graph.Identity.Governance'

    Import-ModuleIfCommandMissing `
        -CommandName (
            'Get-MgRoleManagementDirectoryRoleDefinition'
        ) `
        -ModuleName 'Microsoft.Graph.Identity.Governance'

    # =================================================================
    # 2. VALIDAR/IMPORTAR SHAREPOINT SEM REIMPORTAÇÃO
    # =================================================================

    Write-Step (
        'Validando comandos e sessão do SharePoint'
    )

    Import-SharePointModuleIfNecessary

    $SetSPOSiteCommand = Get-Command `
        -Name Set-SPOSite `
        -ErrorAction Stop

    $RcdParameterAvailable = (
        $SetSPOSiteCommand.Parameters.ContainsKey(
            'RestrictContentOrgWideSearch'
        )
    )

    if (-not $RcdParameterAvailable) {
        throw @'
O parâmetro RestrictContentOrgWideSearch
não foi encontrado no Set-SPOSite.
'@
    }

    Connect-SharePointWhenNecessary `
        -AdminUrl $SharePointAdminUrl `
        -ExpectedAccount $AdminUPN

    # =================================================================
    # 3. REGISTRAR COMANDOS
    # =================================================================

    Write-Step 'Registrando comandos disponíveis'

    $RequiredCommands = @(
        'Connect-MgGraph',
        'Get-MgContext',
        'Disconnect-MgGraph',
        'Get-MgUser',
        'Get-MgSubscribedSku',
        'Get-MgRoleManagementDirectoryRoleAssignment',
        'Get-MgRoleManagementDirectoryRoleDefinition',
        'Connect-SPOService',
        'Get-SPOTenant',
        'Get-SPOSite',
        'Set-SPOSite'
    )

    $CommandEvidence = foreach (
        $RequiredCommand in $RequiredCommands
    ) {
        $Command = Get-Command `
            -Name $RequiredCommand `
            -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            Comando = $RequiredCommand

            Disponivel = (
                $null -ne $Command
            )

            Tipo = if ($null -ne $Command) {
                [string]$Command.CommandType
            }
            else {
                'Não encontrado'
            }

            Modulo = if ($null -ne $Command) {
                [string]$Command.ModuleName
            }
            else {
                'Não encontrado'
            }
        }
    }

    $CommandEvidence |
        Export-Csv `
            -LiteralPath $CommandsPath `
            -NoTypeInformation `
            -Encoding utf8

    $MissingCommands = @(
        $CommandEvidence |
            Where-Object {
                -not $_.Disponivel
            }
    )

    if ($MissingCommands.Count -gt 0) {
        throw (
            'Comandos ausentes: ' +
            ($MissingCommands.Comando -join ', ')
        )
    }

    # =================================================================
    # 4. VALIDAR CONTEXTO GRAPH
    # =================================================================

    Write-Step (
        'Validando tenant, conta e escopos do Graph'
    )

    $RequiredGraphScopes = @(
        'User.Read.All',
        'Organization.Read.All',
        'RoleManagement.Read.Directory'
    )

    $GraphContext = Get-MgContext
    $MustReconnectGraph = $false

    if ($null -eq $GraphContext) {
        $MustReconnectGraph = $true
    }
    elseif (
        -not [string]::Equals(
            [string]$GraphContext.TenantId,
            [string]$TenantId,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $MustReconnectGraph = $true
    }
    elseif (
        -not [string]::Equals(
            [string]$GraphContext.Account,
            [string]$AdminUPN,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $MustReconnectGraph = $true
    }
    else {
        foreach (
            $RequiredScope in $RequiredGraphScopes
        ) {
            if (
                $GraphContext.Scopes -notcontains
                $RequiredScope
            ) {
                $MustReconnectGraph = $true
                break
            }
        }
    }

    if ($MustReconnectGraph) {
        if ($null -ne $GraphContext) {
            Disconnect-MgGraph | Out-Null
        }

        Write-Host ''
        Write-Host 'Autentique no Graph com:' `
            -ForegroundColor Yellow
        Write-Host " $AdminUPN" `
            -ForegroundColor Yellow

        Connect-MgGraph `
            -TenantId $TenantId `
            -Scopes $RequiredGraphScopes `
            -ContextScope Process `
            -NoWelcome `
            -ErrorAction Stop

        $GraphContext = Get-MgContext
    }
    else {
        Write-Host (
            ' Contexto Graph existente reutilizado.'
        ) -ForegroundColor Green
    }

    if ($null -eq $GraphContext) {
        throw @'
A autenticação não criou um contexto
do Microsoft Graph.
'@
    }

    if (
        -not [string]::Equals(
            [string]$GraphContext.TenantId,
            [string]$TenantId,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw @"
Tenant Graph incorreto.

Esperado:
$TenantId

Autenticado:
$($GraphContext.TenantId)
"@
    }

    if (
        -not [string]::Equals(
            [string]$GraphContext.Account,
            [string]$AdminUPN,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw @"
Conta Graph incorreta.

Esperada:
$AdminUPN

Autenticada:
$($GraphContext.Account)
"@
    }

    $MissingScopes = @(
        $RequiredGraphScopes |
            Where-Object {
                $GraphContext.Scopes -notcontains $_
            }
    )

    if ($MissingScopes.Count -gt 0) {
        throw (
            'Escopos Graph ausentes: ' +
            ($MissingScopes -join ', ')
        )
    }

    $SignedInUser = Get-MgUser `
        -UserId $AdminUPN `
        -Property `
            Id,
            DisplayName,
            UserPrincipalName,
            AccountEnabled `
        -ErrorAction Stop

    if (-not $SignedInUser.AccountEnabled) {
        throw @'
A conta administrativa está desabilitada
no Microsoft Entra ID.
'@
    }

    # =================================================================
    # 5. VALIDAR FUNÇÕES
    # =================================================================

    Write-Step 'Validando funções administrativas'

    $RoleAssignments = @(
        Get-MgRoleManagementDirectoryRoleAssignment `
            -Filter (
                "principalId eq '$($SignedInUser.Id)'"
            ) `
            -All `
            -ErrorAction Stop
    )

    $RoleEvidence = @(
        foreach (
            $Assignment in $RoleAssignments
        ) {
            $RoleDefinition = (
                Get-MgRoleManagementDirectoryRoleDefinition `
                    -UnifiedRoleDefinitionId (
                        $Assignment.RoleDefinitionId
                    ) `
                    -ErrorAction Stop
            )

            [PSCustomObject]@{
                Conta = $AdminUPN
                PrincipalId = $SignedInUser.Id
                Funcao = $RoleDefinition.DisplayName
                RoleDefinitionId = (
                    $Assignment.RoleDefinitionId
                )
                RoleAssignmentId = $Assignment.Id
                DirectoryScopeId = (
                    $Assignment.DirectoryScopeId
                )
            }
        }
    )

    $RoleEvidence |
        Export-Csv `
            -LiteralPath $RolesPath `
            -NoTypeInformation `
            -Encoding utf8

    $RoleNames = @(
        $RoleEvidence |
            Select-Object `
                -ExpandProperty Funcao
    )

    $AcceptedRolePatterns = @(
        '^Global Administrator$',
        '^Company Administrator$',
        '^SharePoint Administrator$',
        '^SharePoint Advanced Management Administrator$'
    )

    $HasAcceptedRole = $false

    foreach ($RoleName in $RoleNames) {
        foreach (
            $Pattern in $AcceptedRolePatterns
        ) {
            if ($RoleName -match $Pattern) {
                $HasAcceptedRole = $true
                break
            }
        }

        if ($HasAcceptedRole) {
            break
        }
    }

    if (-not $HasAcceptedRole) {
        throw @"
Nenhuma função administrativa compatível
foi localizada.

Funções encontradas:
$($RoleNames -join '; ')
"@
    }

    # =================================================================
    # 6. INVENTARIAR LICENÇAS
    # =================================================================

    Write-Step 'Inventariando licenças do tenant'

    $SubscribedSkus = @(
        Get-MgSubscribedSku `
            -All `
            -ErrorAction Stop
    )

    $LicenseEvidence = @(
        foreach ($Sku in $SubscribedSkus) {
            $EnabledUnits = 0

            if ($null -ne $Sku.PrepaidUnits) {
                $EnabledUnits = (
                    [int]$Sku.PrepaidUnits.Enabled
                )
            }

            [PSCustomObject]@{
                SkuPartNumber = (
                    [string]$Sku.SkuPartNumber
                )
                SkuId = [string]$Sku.SkuId
                Capacidade = (
                    [string]$Sku.CapabilityStatus
                )
                UnidadesAtivas = $EnabledUnits
                UnidadesUsadas = (
                    [int]$Sku.ConsumedUnits
                )
            }
        }
    )

    $LicenseEvidence |
        Sort-Object SkuPartNumber |
        Export-Csv `
            -LiteralPath $LicensesPath `
            -NoTypeInformation `
            -Encoding utf8

    $LicenseCandidates = @(
        $LicenseEvidence |
            Where-Object {
                $_.SkuPartNumber -match (
                    'COPILOT|' +
                    'SHAREPOINT.*ADVANCED|' +
                    'ADVANCED.*SHAREPOINT'
                )
            }
    )

    $LicenseAssessment = if (
        $LicenseCandidates.Count -gt 0
    ) {
        (
            'SKU candidata a Microsoft Copilot ou ' +
            'SharePoint Advanced Management encontrada'
        )
    }
    else {
        (
            'SKU candidata não identificada pelo nome; ' +
            'validar funcionalmente o recurso'
        )
    }

    # =================================================================
    # 7. CONSULTAR ESTADO ANTERIOR
    # =================================================================

    Write-Step 'Capturando configuração anterior'

    $BeforeState = Get-RcdSiteState `
        -Identity $SiteUrlNormalized

    Export-OneRowCsv `
        -InputObject $BeforeState `
        -Path $BeforePath

    $FunctionalLicenseAssessment = (
        'A propriedade RCD foi consultada ' +
        'com sucesso no tenant'
    )

    $BeforeState |
        Format-List

    # =================================================================
    # 8. CONSULTAR OU ALTERAR
    # =================================================================

    if ($Acao -eq 'Consultar') {
        $AfterState = $BeforeState

        Export-OneRowCsv `
            -InputObject $AfterState `
            -Path $AfterPath

        $ValidationSucceeded = $true
    }
    else {
        $DesiredValue = (
            $Acao -eq 'Habilitar'
        )

        $CurrentValue = [bool](
            $BeforeState.RestrictContentOrgWideSearch
        )

        if ($CurrentValue -eq $DesiredValue) {
            Write-Host ''
            Write-Host (
                'O site já está no estado solicitado. ' +
                'Nenhuma alteração foi necessária.'
            ) -ForegroundColor Yellow

            $AfterState = $BeforeState

            Export-OneRowCsv `
                -InputObject $AfterState `
                -Path $AfterPath

            $ValidationSucceeded = $true
        }
        else {
            Write-Step "Executando ação: $Acao"

            Set-SPOSite `
                -Identity $SiteUrlNormalized `
                -RestrictContentOrgWideSearch (
                    $DesiredValue
                ) `
                -ErrorAction Stop

            $ChangeExecuted = $true

            $MaximumAttempts = 6
            $Attempt = 0
            $ActualValue = $CurrentValue

            do {
                $Attempt++

                Write-Host (
                    " Tentativa de validação " +
                    "$Attempt de $MaximumAttempts..."
                )

                Start-Sleep -Seconds 10

                $AfterState = Get-RcdSiteState `
                    -Identity $SiteUrlNormalized

                $ActualValue = [bool](
                    $AfterState.
                        RestrictContentOrgWideSearch
                )
            }
            while (
                $ActualValue -ne $DesiredValue -and
                $Attempt -lt $MaximumAttempts
            )

            Export-OneRowCsv `
                -InputObject $AfterState `
                -Path $AfterPath

            if ($ActualValue -ne $DesiredValue) {
                throw @"
O comando foi enviado, mas a propriedade não confirmou
o estado desejado após $MaximumAttempts tentativas.

Estado desejado:
$DesiredValue

Estado retornado:
$ActualValue
"@
            }

            $ValidationSucceeded = $true

            $FunctionalLicenseAssessment = (
                'Alteração RCD executada e ' +
                'confirmada funcionalmente'
            )
        }
    }

    # =================================================================
    # 9. GERAR CONTEXTO E RESUMO
    # =================================================================

    Write-Step 'Gerando resumo da prova'

    $ContextEvidence = [PSCustomObject]@{
        DataHoraUtc = (
            Get-Date
        ).ToUniversalTime()

        TenantIdEsperado = $TenantId
        TenantIdGraph = $GraphContext.TenantId
        ContaEsperada = $AdminUPN
        ContaGraph = $GraphContext.Account
        ContaHabilitada = $SignedInUser.AccountEnabled
        EscoposGraph = (
            $GraphContext.Scopes -join '; '
        )
        FuncoesAtivas = (
            $RoleNames -join '; '
        )
        PowerShellVersion = (
            [string]$PSVersionTable.PSVersion
        )
        PowerShellEdition = (
            [string]$PSVersionTable.PSEdition
        )
        SharePointAdminUrl = $SharePointAdminUrl
        SiteUrl = $SiteUrlNormalized
        Acao = $Acao
        ConfirmarAlteracao = (
            $ConfirmarAlteracao.IsPresent
        )
        Justificativa = $Justificativa
        AvaliacaoLicenciamento = (
            $LicenseAssessment
        )
        ValidacaoFuncionalRcd = (
            $FunctionalLicenseAssessment
        )
    }

    Export-OneRowCsv `
        -InputObject $ContextEvidence `
        -Path $ContextPath

    $SummaryEvidence = [PSCustomObject]@{
        DataHoraUtc = (
            Get-Date
        ).ToUniversalTime()

        Item = 'AUTO-16'
        Controle = 'Restricted Content Discovery'
        SiteUrl = $SiteUrlNormalized
        AcaoSolicitada = $Acao
        EstadoAntes = $BeforeState.RcdStatus
        EstadoDepois = $AfterState.RcdStatus
        AlteracaoExecutada = $ChangeExecuted
        ValidacaoAprovada = $ValidationSucceeded
        PermissoesAlteradas = $false
        ConteudoExportado = $false
        Justificativa = $Justificativa
        PastaEvidencias = $RunEvidenceFolder

        Observacao = (
            'A propriedade administrativa foi validada. ' +
            'A propagação em pesquisa e Copilot ' +
            'pode levar tempo.'
        )
    }

    Export-OneRowCsv `
        -InputObject $SummaryEvidence `
        -Path $SummaryPath

    Write-Host ''
    Write-Host '====================================================='
    Write-Host ' RESULTADO DA PROVA'
    Write-Host '====================================================='

    $SummaryEvidence |
        Format-List

    Write-Host '====================================================='
    Write-Host (
        'A validação administrativa foi concluída.'
    ) -ForegroundColor Green
    Write-Host (
        'As permissões do site não foram alteradas.'
    )
    Write-Host (
        'Nenhum conteúdo do site foi exportado.'
    )
}
catch {
    $ErrorMessage = $_.Exception.Message

    @(
        "DataHoraUtc: $((Get-Date).ToUniversalTime())"
        'Item: AUTO-16'
        "SiteUrl: $SiteUrlNormalized"
        "Acao: $Acao"
        "Erro: $ErrorMessage"
    ) |
        Set-Content `
            -LiteralPath $ErrorPath `
            -Encoding utf8

    $FailureSummary = [PSCustomObject]@{
        DataHoraUtc = (
            Get-Date
        ).ToUniversalTime()

        Item = 'AUTO-16'
        Controle = 'Restricted Content Discovery'
        SiteUrl = $SiteUrlNormalized
        AcaoSolicitada = $Acao

        EstadoAntes = if (
            $null -ne $BeforeState
        ) {
            $BeforeState.RcdStatus
        }
        else {
            'Não capturado'
        }

        EstadoDepois = if (
            $null -ne $AfterState
        ) {
            $AfterState.RcdStatus
        }
        else {
            'Não capturado'
        }

        AlteracaoExecutada = $ChangeExecuted
        ValidacaoAprovada = $false
        Erro = $ErrorMessage
        PastaEvidencias = $RunEvidenceFolder
    }

    Export-OneRowCsv `
        -InputObject $FailureSummary `
        -Path $SummaryPath

    Write-Host ''
    Write-Host 'A prova do AUTO-16 falhou.' `
        -ForegroundColor Red
    Write-Host $ErrorMessage `
        -ForegroundColor Red
    Write-Host ''
    Write-Host (
        "Evidências preservadas em: " +
        $RunEvidenceFolder
    )

    throw
}
finally {
    if ($TranscriptStarted) {
        try {
            Stop-Transcript |
                Out-Null
        }
        catch {
            # Não substitui o resultado da prova.
        }
    }
}