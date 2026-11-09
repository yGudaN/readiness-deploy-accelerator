<#
# OBJETIVO:
# Validar e operar controladamente o item AUTO-34 - SharePoint SAM / oversharing.
# O script inventaria configurações de compartilhamento, valida identidade,
# funções e licenças, administra coleta para relatórios de atividade EEEU,
# inicia/consulta/exporta relatórios Data Access Governance e, opcionalmente,
# altera a capacidade de compartilhamento de um site de laboratório.
#
# FERRAMENTA:
# PowerShell 7 no Windows; Microsoft Graph PowerShell;
# Microsoft.Online.SharePoint.PowerShell.
#
# PERMISSÃO:
# SharePoint Administrator para administração do SharePoint.
# SharePoint Advanced Management Administrator para o snapshot detalhado
# Everyone/EEEU e para metadados e remediações avançadas.
# Microsoft Graph: User.Read.All, Organization.Read.All e
# RoleManagement.Read.Directory.
#
# EFEITO:
# Consultar não altera o tenant. As ações HabilitarColeta, DesabilitarColeta,
# IniciarRelatorio*, IniciarBaselinePermissoes, IniciarSnapshotDetalhadoEEEU
# e ConfigurarCompartilhamentoSite alteram estado administrativo ou iniciam
# processamento e exigem -ConfirmarAlteracao e -Justificativa.
#
# RECURSO-ALVO:
# Tenant SharePoint Online, relatórios Data Access Governance, coleta de
# atividade EEEU e, quando informado, um site SharePoint de laboratório.
#
# PARÂMETROS EDITÁVEIS:
# -Acao, -SharePointTenantPrefix, -EscopoEEEU, -NomeRelatorio,
# -CountOfUsersMoreThan, -ReportId, -SiteUrl, -SharingCapability,
# -IncludePersonalSites, -ConfirmarAlteracao e -Justificativa.
#
# EVIDÊNCIAS:
# evidencias\\AUTO-34-SharePoint-SAM-Oversharing\\<data-hora>\\
# Inclui log, contexto, módulos/comandos, funções, licenças, configuração do
# tenant e sites, relatórios DAG, coleta antes/depois, ação e resumo.
#
# RISCOS:
# A configuração SharingCapability mostra exposição potencial, não prova
# oversharing efetivo. Reduzir compartilhamento pode interromper acesso
# legítimo. Relatórios são assíncronos e podem refletir dados defasados.
#
# ATENÇÃO:
# Execute somente no tenant de laboratório confirmado.
# Não use ConfigurarCompartilhamentoSite sem site dedicado e autorização.
# Everyone Except External Users concede acesso amplo a usuários internos.
#>
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet(
        'Consultar',
        'HabilitarColeta',
        'DesabilitarColeta',
        'IniciarRelatorioAtividadeSites',
        'IniciarRelatorioAtividadeItens',
        'IniciarBaselinePermissoes',
        'IniciarSnapshotDetalhadoEEEU',
        'ConsultarRelatorio',
        'ExportarRelatorio',
        'ConfigurarCompartilhamentoSite'
    )]
    [string]$Acao = 'Consultar',
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string]$SharePointTenantPrefix,
    [Parameter(Mandatory = $false)]
    [ValidateSet('Sites', 'Itens', 'Ambos')]
    [string]$EscopoEEEU = 'Ambos',
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$NomeRelatorio = 'LAB-AUTO34-Oversharing',
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 2147483647)]
    [int]$CountOfUsersMoreThan = 0,
    [Parameter(Mandatory = $false)]
    [Guid]$ReportId,
    [Parameter(Mandatory = $false)]
    [string]$SiteUrl,
    [Parameter(Mandatory = $false)]
    [ValidateSet(
        'Disabled',
        'ExistingExternalUserSharingOnly',
        'ExternalUserSharingOnly',
        'ExternalUserAndGuestSharing'
    )]
    [string]$SharingCapability,
    [Parameter(Mandatory = $false)]
    [switch]$IncludePersonalSites,
    [Parameter(Mandatory = $false)]
    [switch]$ConfirmarAlteracao,
    [Parameter(Mandatory = $false)]
    [string]$Justificativa
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$AutomationId = 'AUTO-34'
$AutomationName = 'SharePoint SAM / oversharing'
$MinimumDagVersion = [version]'16.0.25409.0'
$StartedAt = Get-Date
$Stamp = $StartedAt.ToString('yyyyMMdd-HHmmss')
$Completed = $false
$TranscriptStarted = $false
function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}
function Get-SafeProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) {
        return $null
    }
    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property) {
        return $null
    }
    return $Property.Value
}
function Get-FirstPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )
    foreach ($Name in $Names) {
        $Value = Get-SafeProperty -Object $Object -Name $Name
        if ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)) {
            return $Value
        }
    }
    return $null
}
function Export-Records {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$EmptyMessage = 'Consulta concluída sem registros.'
    )
    $Items = @($Records)
    if ($Items.Count -gt 0) {
        $Items | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
        return
    }
    [PSCustomObject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime()
        Fonte       = $Source
        Resultado   = $EmptyMessage
    } | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
}
function Import-ModuleForCommand {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$ModuleName
    )
    if ($null -ne (Get-Command -Name $CommandName -ErrorAction SilentlyContinue)) {
        return
    }
    Import-Module -Name $ModuleName -ErrorAction Stop
    if ($null -eq (Get-Command -Name $CommandName -ErrorAction SilentlyContinue)) {
        throw "O comando $CommandName não ficou disponível após importar $ModuleName."
    }
}
function Import-SharePointModule {
    $ExistingConnectCommand = Get-Command `
        -Name Connect-SPOService `
        -ErrorAction SilentlyContinue
    $ExistingTenantCommand = Get-Command `
        -Name Get-SPOTenant `
        -ErrorAction SilentlyContinue

    if (
        $null -ne $ExistingConnectCommand -and
        $null -ne $ExistingTenantCommand
    ) {
        $LoadedModule = Get-Module `
            -Name Microsoft.Online.SharePoint.PowerShell `
            -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1

        $LoadedVersion = if ($null -ne $LoadedModule) {
            $LoadedModule.Version
        }
        else {
            $ExistingTenantCommand.Version
        }

        if ([version]$LoadedVersion -lt $MinimumDagVersion) {
            throw @"
Os comandos SharePoint estão carregados, mas a versão é insuficiente.
Carregada: $LoadedVersion
Mínima para Data Access Governance: $MinimumDagVersion
"@
        }

        Write-Host (
            ' Comandos SharePoint já disponíveis. ' +
            'O módulo não será importado novamente.'
        ) -ForegroundColor Green

        if ($null -ne $LoadedModule) {
            return $LoadedModule
        }

        return [PSCustomObject]@{
            Name    = 'Microsoft.Online.SharePoint.PowerShell'
            Version = [version]$LoadedVersion
            Path    = [string]$ExistingTenantCommand.Module.Path
        }
    }

    $Module = Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -eq $Module) {
        throw @'
O módulo Microsoft.Online.SharePoint.PowerShell não foi encontrado.
Instale ou atualize o módulo antes de executar o item AUTO-34.
'@
    }
    if ($Module.Version -lt $MinimumDagVersion) {
        throw @"
Versão do módulo SharePoint Online insuficiente.
Instalada: $($Module.Version)
Mínima para Data Access Governance: $MinimumDagVersion
"@
    }

    if ([string]::IsNullOrWhiteSpace([string]$Module.Path)) {
        throw @"
O módulo SharePoint Online foi localizado, mas seu caminho não foi retornado.
Versão localizada: $($Module.Version)
"@
    }

    try {
        Import-Module `
            -Name $Module.Path `
            -Force `
            -ErrorAction Stop |
            Out-Null
    }
    catch {
        throw @"
O módulo Microsoft.Online.SharePoint.PowerShell foi localizado, mas a
importação direta pelo caminho completo falhou.

Versão localizada: $($Module.Version)
Caminho localizado: $($Module.Path)

Detalhe:
$($_.Exception.Message)

Abra um novo terminal PowerShell 7 e valide manualmente:

`$SpoModule = Get-Module -ListAvailable `
    -Name Microsoft.Online.SharePoint.PowerShell |
    Sort-Object Version -Descending |
    Select-Object -First 1

Import-Module -Name `$SpoModule.Path -Force -ErrorAction Stop
"@
    }

    $RequiredSharePointCommands = @(
        'Connect-SPOService',
        'Get-SPOTenant',
        'Get-SPOSite',
        'Get-SPODataAccessGovernanceInsight',
        'Start-SPODataAccessGovernanceInsight',
        'Export-SPODataAccessGovernanceInsight'
    )
    $MissingSharePointCommands = @(
        $RequiredSharePointCommands |
            Where-Object {
                $null -eq (
                    Get-Command `
                        -Name $_ `
                        -ErrorAction SilentlyContinue
                )
            }
    )
    if ($MissingSharePointCommands.Count -gt 0) {
        throw (
            'O módulo foi importado, mas faltam comandos obrigatórios: ' +
            ($MissingSharePointCommands -join ', ')
        )
    }

    Write-Host (
        " Módulo SharePoint importado diretamente: $($Module.Version)"
    ) -ForegroundColor Green

    return $Module
}
function Test-SharePointSession {
    try {
        $null = Get-SPOTenant -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}
function Connect-SharePointWhenNecessary {
    param(
        [Parameter(Mandatory = $true)][string]$AdminUrl,
        [Parameter(Mandatory = $true)][string]$ExpectedAccount
    )
    if (Test-SharePointSession) {
        Write-Host ' Sessão SharePoint existente confirmada.' -ForegroundColor Green
        return
    }
    Write-Host ' Será aberta autenticação do SharePoint Online.' -ForegroundColor Yellow
    Write-Host " Use somente: $ExpectedAccount" -ForegroundColor Yellow
    $ConnectCommand = Get-Command Connect-SPOService -ErrorAction Stop
    $Parameters = @{
        Url         = $AdminUrl
        ErrorAction = 'Stop'
    }
    if ($ConnectCommand.Parameters.ContainsKey('UseSystemBrowser')) {
        $Parameters['UseSystemBrowser'] = $true
    }
    Connect-SPOService @Parameters
    if (-not (Test-SharePointSession)) {
        throw 'Get-SPOTenant não confirmou a sessão administrativa do SharePoint.'
    }
}
function Get-SharingClassification {
    param([AllowNull()][object]$Value)
    switch ([string]$Value) {
        'ExternalUserAndGuestSharing' {
            'Alto potencial: links Anyone e novos convidados podem ser permitidos.'
        }
        'ExternalUserSharingOnly' {
            'Moderado-alto: novos convidados podem ser permitidos.'
        }
        'ExistingExternalUserSharingOnly' {
            'Moderado: somente convidados existentes.'
        }
        'Disabled' {
            'Exposição externa reduzida: compartilhamento externo desabilitado.'
        }
        default {
            'Não classificado; revisar o valor retornado.'
        }
    }
}
function Convert-DagReportToEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Report,
        [Parameter(Mandatory = $true)][string]$Consulta
    )
    [PSCustomObject]@{
        DataHoraUtc     = (Get-Date).ToUniversalTime()
        Consulta        = $Consulta
        ReportId        = [string](Get-FirstPropertyValue $Report @('ReportID', 'ReportId', 'Id'))
        Name            = [string](Get-FirstPropertyValue $Report @('Name', 'ReportName'))
        ReportEntity    = [string](Get-FirstPropertyValue $Report @('ReportEntity', 'Entity'))
        ReportType      = [string](Get-FirstPropertyValue $Report @('ReportType', 'Type'))
        Workload        = [string](Get-FirstPropertyValue $Report @('Workload'))
        Status          = [string](Get-FirstPropertyValue $Report @('Status', 'ReportStatus'))
        SiteCount       = [string](Get-FirstPropertyValue $Report @('SiteCount', 'NumberOfSites', 'SitesCount'))
        CreatedDateTime = [string](Get-FirstPropertyValue $Report @(
            'CreatedDateTime',
            'CreatedTime',
            'CreatedDate'
        ))
        ReportStartTime = [string](Get-FirstPropertyValue $Report @('ReportStartTime', 'StartTime'))
        ReportEndTime   = [string](Get-FirstPropertyValue $Report @('ReportEndTime', 'EndTime'))
    }
}
function Get-ActivityEntities {
    param([Parameter(Mandatory = $true)][string]$Scope)
    switch ($Scope) {
        'Sites' { @('EveryoneExceptExternalUsersAtSite') }
        'Itens' { @('EveryoneExceptExternalUsersForItems') }
        'Ambos' {
            @(
                'EveryoneExceptExternalUsersAtSite',
                'EveryoneExceptExternalUsersForItems'
            )
        }
    }
}
function Get-CollectionStatusValue {
    param([AllowNull()][object]$Result)
    if ($null -eq $Result) {
        return ''
    }
    $Status = Get-FirstPropertyValue `
        -Object $Result `
        -Names @('Status', 'DataCollectionStatus', 'State')
    if ($null -ne $Status) {
        return [string]$Status
    }
    return [string]$Result
}
function Assert-ChangeConfirmation {
    param([Parameter(Mandatory = $true)][string]$RequestedAction)
    $ChangingActions = @(
        'HabilitarColeta',
        'DesabilitarColeta',
        'IniciarRelatorioAtividadeSites',
        'IniciarRelatorioAtividadeItens',
        'IniciarBaselinePermissoes',
        'IniciarSnapshotDetalhadoEEEU',
        'ConfigurarCompartilhamentoSite'
    )
    if ($RequestedAction -notin $ChangingActions) {
        return
    }
    if (-not $ConfirmarAlteracao.IsPresent) {
        throw "A ação $RequestedAction exige -ConfirmarAlteracao."
    }
    if ([string]::IsNullOrWhiteSpace($Justificativa)) {
        throw "A ação $RequestedAction exige -Justificativa."
    }
}
Assert-ChangeConfirmation -RequestedAction $Acao
$PreflightPath = Join-Path $PSScriptRoot '00-preflight.ps1'
if (-not (Test-Path -LiteralPath $PreflightPath)) {
    throw "00-preflight.ps1 não foi encontrado em: $PSScriptRoot"
}
# O preflight compartilhado mantém a trava histórica ApplyChanges=False.
# A saída dele é suprimida para não sugerir que esta versão seja somente
# leitura. Nesta versão, qualquer alteração é controlada exclusivamente por
# -Acao, -ConfirmarAlteracao e -Justificativa.
. $PreflightPath 6>$null
if ([string]::IsNullOrWhiteSpace($SharePointTenantPrefix)) {
    if (
        -not [string]::IsNullOrWhiteSpace([string]$TenantPrefix) -and
        $TenantPrefix -match '^[a-zA-Z0-9-]+$'
    ) {
        $SharePointTenantPrefix = $TenantPrefix
    }
    else {
        $SharePointTenantPrefix = Read-Host 'Informe o prefixo do SharePoint'
    }
}
$SharePointTenantPrefix = $SharePointTenantPrefix.Trim()
if ($SharePointTenantPrefix -notmatch '^[a-zA-Z0-9-]+$') {
    throw 'Informe somente o prefixo do SharePoint, sem URL, domínio ou barras.'
}
$SharePointAdminUrl = "https://$SharePointTenantPrefix-admin.sharepoint.com"
$SharePointRootUrl = "https://$SharePointTenantPrefix.sharepoint.com"
if ($Acao -eq 'ConfigurarCompartilhamentoSite') {
    if ([string]::IsNullOrWhiteSpace($SiteUrl)) {
        throw 'ConfigurarCompartilhamentoSite exige -SiteUrl.'
    }
    if ([string]::IsNullOrWhiteSpace($SharingCapability)) {
        throw 'ConfigurarCompartilhamentoSite exige -SharingCapability.'
    }
    $NormalizedRoot = $SharePointRootUrl.TrimEnd('/').ToLowerInvariant()
    $NormalizedSite = $SiteUrl.TrimEnd('/').ToLowerInvariant()
    if (-not $NormalizedSite.StartsWith($NormalizedRoot)) {
        throw 'O SiteUrl informado não pertence ao tenant SharePoint esperado.'
    }
}
if ($Acao -in @('ConsultarRelatorio', 'ExportarRelatorio')) {
    if ($ReportId -eq [Guid]::Empty) {
        throw "A ação $Acao exige -ReportId."
    }
}
$EvidenceRoot = Join-Path $PSScriptRoot 'evidencias\\AUTO-34-SharePoint-SAM-Oversharing'
$EvidenceDirectory = Join-Path $EvidenceRoot $Stamp
New-Item -Path $EvidenceDirectory -ItemType Directory -Force | Out-Null
$Paths = @{
    Log              = Join-Path $EvidenceDirectory 'execucao.log'
    Context          = Join-Path $EvidenceDirectory 'contexto.csv'
    Commands         = Join-Path $EvidenceDirectory 'modulos-comandos.csv'
    Roles            = Join-Path $EvidenceDirectory 'funcoes-administrativas.csv'
    Licenses         = Join-Path $EvidenceDirectory 'licencas-tenant.csv'
    Tenant           = Join-Path $EvidenceDirectory 'tenant-sharing.csv'
    Sites            = Join-Path $EvidenceDirectory 'sites-sharing.csv'
    SiteErrors       = Join-Path $EvidenceDirectory 'sites-erros.csv'
    DagQueries       = Join-Path $EvidenceDirectory 'dag-consultas.csv'
    DagReports       = Join-Path $EvidenceDirectory 'dag-reports.csv'
    CollectionBefore = Join-Path $EvidenceDirectory 'coleta-antes.csv'
    CollectionAfter  = Join-Path $EvidenceDirectory 'coleta-depois.csv'
    ConfigBefore     = Join-Path $EvidenceDirectory 'configuracao-antes.csv'
    ConfigAfter      = Join-Path $EvidenceDirectory 'configuracao-depois.csv'
    Actions          = Join-Path $EvidenceDirectory 'acoes.csv'
    SummaryCsv       = Join-Path $EvidenceDirectory 'resumo.csv'
    SummaryJson      = Join-Path $EvidenceDirectory 'resumo.json'
}
$CommandEvidence = New-Object System.Collections.ArrayList
$RoleEvidence = @()
$LicenseEvidence = @()
$SiteResults = New-Object System.Collections.ArrayList
$SiteErrors = New-Object System.Collections.ArrayList
$DagQueryEvidence = New-Object System.Collections.ArrayList
$DagReportEvidence = New-Object System.Collections.ArrayList
$CollectionBefore = New-Object System.Collections.ArrayList
$CollectionAfter = New-Object System.Collections.ArrayList
$ActionEvidence = New-Object System.Collections.ArrayList
$QualityGate = 'Falha'
$LicenseAssessment = 'Não avaliado'
$HasBaseLicense = $false
$HasSamCandidate = $false
$HasE5Candidate = $false
$HasSharePointAdminRole = $false
$HasSamAdminRole = $false
$SitesEnumerated = 0
$SitesWithErrors = 0
$ReportsFound = 0
$ReportStartedId = ''
$ExportedReportPath = ''
try {
    Start-Transcript -LiteralPath $Paths.Log -Force | Out-Null
    $TranscriptStarted = $true
    Write-Host ''
    Write-Host '============================================================'
    Write-Host " $AutomationId - $AutomationName"
    Write-Host " Ação: $Acao"
    Write-Host " Tenant esperado: $TenantId"
    Write-Host " Conta esperada: $AdminUPN"
    Write-Host " Admin Center: $SharePointAdminUrl"
    Write-Host " Evidências: $EvidenceDirectory"
    Write-Host '============================================================'
    Write-Step 'Validando módulos e comandos'
    Import-ModuleForCommand Connect-MgGraph Microsoft.Graph.Authentication
    Import-ModuleForCommand Get-MgUser Microsoft.Graph.Users
    Import-ModuleForCommand Get-MgSubscribedSku Microsoft.Graph.Identity.DirectoryManagement
    Import-ModuleForCommand `
        Get-MgRoleManagementDirectoryRoleAssignment `
        Microsoft.Graph.Identity.Governance
    Import-ModuleForCommand `
        Get-MgRoleManagementDirectoryRoleDefinition `
        Microsoft.Graph.Identity.Governance
    $SharePointModule = Import-SharePointModule
    $CommandNames = @(
        'Connect-MgGraph',
        'Get-MgContext',
        'Get-MgUser',
        'Get-MgSubscribedSku',
        'Get-MgRoleManagementDirectoryRoleAssignment',
        'Get-MgRoleManagementDirectoryRoleDefinition',
        'Connect-SPOService',
        'Get-SPOTenant',
        'Get-SPOSite',
        'Set-SPOSite',
        'Get-SPODataAccessGovernanceInsight',
        'Start-SPODataAccessGovernanceInsight',
        'Export-SPODataAccessGovernanceInsight',
        'Get-SPOAuditDataCollectionStatusForActivityInsights',
        'Start-SPOAuditDataCollectionForActivityInsights',
        'Stop-SPOAuditDataCollectionForActivityInsights'
    )
    foreach ($CommandName in $CommandNames) {
        $Command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
        [void]$CommandEvidence.Add([PSCustomObject]@{
            Tipo       = 'Cmdlet'
            Nome       = $CommandName
            Disponivel = ($null -ne $Command)
            Modulo     = if ($null -ne $Command) { $Command.ModuleName } else { '' }
        })
    }
    [void]$CommandEvidence.Add([PSCustomObject]@{
        Tipo       = 'Módulo'
        Nome       = 'Microsoft.Online.SharePoint.PowerShell'
        Disponivel = $true
        Modulo     = [string]$SharePointModule.Version
    })
    Export-Records $Paths.Commands @($CommandEvidence) 'Módulos e comandos'
    $RequiredForAction = @{
        Consultar = @(
            'Get-SPOTenant',
            'Get-SPOSite',
            'Get-SPODataAccessGovernanceInsight'
        )
        HabilitarColeta = @(
            'Get-SPOAuditDataCollectionStatusForActivityInsights',
            'Start-SPOAuditDataCollectionForActivityInsights'
        )
        DesabilitarColeta = @(
            'Get-SPOAuditDataCollectionStatusForActivityInsights',
            'Stop-SPOAuditDataCollectionForActivityInsights'
        )
        IniciarRelatorioAtividadeSites = @('Start-SPODataAccessGovernanceInsight')
        IniciarRelatorioAtividadeItens = @('Start-SPODataAccessGovernanceInsight')
        IniciarBaselinePermissoes = @('Start-SPODataAccessGovernanceInsight')
        IniciarSnapshotDetalhadoEEEU = @('Start-SPODataAccessGovernanceInsight')
        ConsultarRelatorio = @('Get-SPODataAccessGovernanceInsight')
        ExportarRelatorio = @(
            'Get-SPODataAccessGovernanceInsight',
            'Export-SPODataAccessGovernanceInsight'
        )
        ConfigurarCompartilhamentoSite = @('Get-SPOSite', 'Set-SPOSite')
    }
    $MissingForAction = @(
        $RequiredForAction[$Acao] | Where-Object {
            $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue)
        }
    )
    if ($MissingForAction.Count -gt 0) {
        throw "Comandos ausentes para $Acao`: $($MissingForAction -join ', ')"
    }
    Write-Step 'Validando tenant, conta e escopos do Graph'
    $RequiredGraphScopes = @(
        'User.Read.All',
        'Organization.Read.All',
        'RoleManagement.Read.Directory'
    )
    $GraphContext = Get-MgContext
    $ReconnectGraph = $false
    if ($null -eq $GraphContext) {
        $ReconnectGraph = $true
    }
    elseif (
        -not [string]::Equals(
            [string]$GraphContext.TenantId,
            [string]$TenantId,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $ReconnectGraph = $true
    }
    elseif (
        -not [string]::Equals(
            [string]$GraphContext.Account,
            [string]$AdminUPN,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $ReconnectGraph = $true
    }
    else {
        foreach ($Scope in $RequiredGraphScopes) {
            if ($GraphContext.Scopes -notcontains $Scope) {
                $ReconnectGraph = $true
                break
            }
        }
    }
    if ($ReconnectGraph) {
        if ($null -ne $GraphContext) {
            Disconnect-MgGraph | Out-Null
        }
        Write-Host " Autentique no Graph com: $AdminUPN" -ForegroundColor Yellow
        Connect-MgGraph `
            -TenantId $TenantId `
            -Scopes $RequiredGraphScopes `
            -ContextScope Process `
            -NoWelcome `
            -ErrorAction Stop
        $GraphContext = Get-MgContext
    }
    if ($null -eq $GraphContext) {
        throw 'A autenticação não criou contexto do Microsoft Graph.'
    }
    if (
        -not [string]::Equals(
            [string]$GraphContext.TenantId,
            [string]$TenantId,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Tenant Graph incorreto. Esperado: $TenantId; atual: $($GraphContext.TenantId)"
    }
    if (
        -not [string]::Equals(
            [string]$GraphContext.Account,
            [string]$AdminUPN,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Conta Graph incorreta. Esperada: $AdminUPN; atual: $($GraphContext.Account)"
    }
    $SignedInUser = Get-MgUser `
        -UserId $AdminUPN `
        -Property Id,DisplayName,UserPrincipalName,AccountEnabled `
        -ErrorAction Stop
    if (-not $SignedInUser.AccountEnabled) {
        throw 'A conta administrativa está desabilitada no Microsoft Entra ID.'
    }
    Write-Step 'Validando funções administrativas'
    $Assignments = @(
        Get-MgRoleManagementDirectoryRoleAssignment `
            -Filter "principalId eq '$($SignedInUser.Id)'" `
            -All `
            -ErrorAction Stop
    )
    $RoleEvidence = @(
        foreach ($Assignment in $Assignments) {
            $Definition = Get-MgRoleManagementDirectoryRoleDefinition `
                -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId `
                -ErrorAction Stop
            [PSCustomObject]@{
                Conta             = $AdminUPN
                PrincipalId       = $SignedInUser.Id
                Funcao            = $Definition.DisplayName
                RoleDefinitionId  = $Assignment.RoleDefinitionId
                RoleAssignmentId  = $Assignment.Id
                DirectoryScopeId  = $Assignment.DirectoryScopeId
            }
        }
    )
    Export-Records $Paths.Roles $RoleEvidence 'Funções administrativas'
    $RoleNames = @($RoleEvidence | Select-Object -ExpandProperty Funcao)
    $HasGlobalAdminRole = (
        $RoleNames -contains 'Global Administrator' -or
        $RoleNames -contains 'Company Administrator'
    )
    $HasSharePointAdminRole = (
        $RoleNames -contains 'SharePoint Administrator' -or
        $HasGlobalAdminRole
    )
    $HasSamAdminRole = (
        $RoleNames -contains 'SharePoint Advanced Management Administrator'
    )
    if (-not $HasSharePointAdminRole) {
        throw 'A conta não possui Global Administrator nem SharePoint Administrator.'
    }
    if ($Acao -eq 'IniciarSnapshotDetalhadoEEEU' -and -not $HasSamAdminRole) {
        throw @'
O snapshot detalhado de Everyone/EEEU exige a função
SharePoint Advanced Management Administrator.
'@
    }
    Write-Step 'Inventariando licenças do tenant'
    $SubscribedSkus = @(Get-MgSubscribedSku -All -ErrorAction Stop)
    $LicenseEvidence = @(
        foreach ($Sku in $SubscribedSkus) {
            $Enabled = 0
            if ($null -ne $Sku.PrepaidUnits) {
                $Enabled = [int]$Sku.PrepaidUnits.Enabled
            }
            [PSCustomObject]@{
                SkuPartNumber  = [string]$Sku.SkuPartNumber
                SkuId          = [string]$Sku.SkuId
                Capacidade     = [string]$Sku.CapabilityStatus
                UnidadesAtivas = $Enabled
                UnidadesUsadas = [int]$Sku.ConsumedUnits
            }
        }
    )
    Export-Records $Paths.Licenses $LicenseEvidence 'Licenças do tenant'
    $EnabledSkus = @(
        $LicenseEvidence | Where-Object {
            $_.Capacidade -eq 'Enabled' -and $_.UnidadesAtivas -gt 0
        }
    )
    $HasBaseLicense = @(
        $EnabledSkus | Where-Object {
            $_.SkuPartNumber -match 'ENTERPRISEPACK|ENTERPRISEPREMIUM|Microsoft_365_E[1357]|SPE_E[1357]'
        }
    ).Count -gt 0
    $HasE5Candidate = @(
        $EnabledSkus | Where-Object {
            $_.SkuPartNumber -match 'E5|ENTERPRISEPREMIUM'
        }
    ).Count -gt 0
    $HasSamCandidate = @(
        $EnabledSkus | Where-Object {
            $_.SkuPartNumber -match (
                'COPILOT|' +
                'SHAREPOINT.*ADVANCED|' +
                'ADVANCED.*SHAREPOINT|' +
                'M365.*E7|Microsoft_365_E7|SPE_E7'
            )
        }
    ).Count -gt 0
    $LicenseAssessment = if ($HasSamCandidate) {
        'SKU candidata a Copilot, SAM ou E7 encontrada; validar funcionalmente.'
    }
    elseif ($HasE5Candidate) {
        'Microsoft 365/Office 365 E5 encontrado, sem SKU SAM/Copilot identificada; atividade EEEU pode exigir coleta manual e snapshots/remediações avançadas devem ser validados funcionalmente.'
    }
    elseif ($HasBaseLicense) {
        'Assinatura base encontrada, sem SKU SAM/Copilot identificada.'
    }
    else {
        'Assinatura base e SKU SAM/Copilot não foram identificadas pelos nomes dos SKUs.'
    }
    Write-Step 'Validando a sessão do SharePoint'
    Connect-SharePointWhenNecessary `
        -AdminUrl $SharePointAdminUrl `
        -ExpectedAccount $AdminUPN
    $TenantSettings = Get-SPOTenant -ErrorAction Stop
    $TenantEvidence = [PSCustomObject]@{
        DataHoraUtc                         = (Get-Date).ToUniversalTime()
        SharingCapability                   = [string](Get-SafeProperty $TenantSettings 'SharingCapability')
        DefaultSharingLinkType              = [string](Get-SafeProperty $TenantSettings 'DefaultSharingLinkType')
        DefaultLinkPermission               = [string](Get-SafeProperty $TenantSettings 'DefaultLinkPermission')
        ShowEveryoneClaim                   = [string](Get-SafeProperty $TenantSettings 'ShowEveryoneClaim')
        ShowEveryoneExceptExternalUsersClaim = [string](Get-SafeProperty $TenantSettings 'ShowEveryoneExceptExternalUsersClaim')
        SharingDomainRestrictionMode        = [string](Get-SafeProperty $TenantSettings 'SharingDomainRestrictionMode')
        ExternalUserExpirationRequired      = [string](Get-SafeProperty $TenantSettings 'ExternalUserExpirationRequired')
        ExternalUserExpireInDays            = [string](Get-SafeProperty $TenantSettings 'ExternalUserExpireInDays')
        ClassificacaoConfiguracao           = Get-SharingClassification (
            Get-SafeProperty $TenantSettings 'SharingCapability'
        )
        Observacao                          = 'Configuração potencial; não comprova oversharing efetivo.'
    }
    Export-Records $Paths.Tenant @($TenantEvidence) 'Get-SPOTenant'
    $ContextEvidence = [PSCustomObject]@{
        DataHoraUtc                   = (Get-Date).ToUniversalTime()
        Automacao                     = $AutomationId
        Nome                          = $AutomationName
        Acao                          = $Acao
        TenantIdEsperado              = $TenantId
        TenantIdGraph                 = $GraphContext.TenantId
        ContaEsperada                 = $AdminUPN
        ContaGraph                    = $GraphContext.Account
        ContaHabilitada               = $SignedInUser.AccountEnabled
        EscoposGraph                  = ($GraphContext.Scopes -join '; ')
        FuncoesAtivas                 = ($RoleNames -join '; ')
        SharePointAdminUrl            = $SharePointAdminUrl
        SharePointRootUrl             = $SharePointRootUrl
        ModuloSharePoint              = 'Microsoft.Online.SharePoint.PowerShell'
        VersaoModuloSharePoint        = [string]$SharePointModule.Version
        PowerShellVersion             = [string]$PSVersionTable.PSVersion
        PowerShellEdition             = [string]$PSVersionTable.PSEdition
        IncludePersonalSites          = $IncludePersonalSites.IsPresent
        ConfirmarAlteracao            = $ConfirmarAlteracao.IsPresent
        Justificativa                 = $Justificativa
        PossuiFuncaoSharePointAdmin   = $HasSharePointAdminRole
        PossuiFuncaoSamAdmin          = $HasSamAdminRole
        PossuiLicencaBaseCandidata    = $HasBaseLicense
        PossuiE5Candidata             = $HasE5Candidate
        PossuiSamOuCopilotCandidata   = $HasSamCandidate
        AvaliacaoLicenciamento        = $LicenseAssessment
    }
    Export-Records $Paths.Context @($ContextEvidence) 'Contexto da execução'
    switch ($Acao) {
        'Consultar' {
            Write-Step 'Coletando configurações por site'
            $SiteIndex = @(
                Get-SPOSite `
                    -Limit All `
                    -IncludePersonalSite:$IncludePersonalSites.IsPresent `
                    -ErrorAction Stop |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]$_.Url)
                    }
            )
            $SitesEnumerated = $SiteIndex.Count
            $Current = 0
            foreach ($IndexItem in $SiteIndex) {
                $Current++
                $Percent = if ($SiteIndex.Count -gt 0) {
                    [math]::Round(($Current / $SiteIndex.Count) * 100, 0)
                }
                else {
                    100
                }
                Write-Progress `
                    -Activity 'Consultando sites SharePoint' `
                    -Status "$Current de $($SiteIndex.Count)" `
                    -PercentComplete $Percent
                try {
                    $Site = Get-SPOSite -Identity $IndexItem.Url -ErrorAction Stop
                    $SiteSharing = Get-SafeProperty $Site 'SharingCapability'
                    [void]$SiteResults.Add([PSCustomObject]@{
                        DataHoraUtc                  = (Get-Date).ToUniversalTime()
                        Url                          = [string](Get-SafeProperty $Site 'Url')
                        Title                        = [string](Get-SafeProperty $Site 'Title')
                        Template                     = [string](Get-SafeProperty $Site 'Template')
                        LockState                    = [string](Get-SafeProperty $Site 'LockState')
                        SharingCapability            = [string]$SiteSharing
                        DefaultSharingLinkType       = [string](Get-SafeProperty $Site 'DefaultSharingLinkType')
                        DefaultLinkPermission        = [string](Get-SafeProperty $Site 'DefaultLinkPermission')
                        DisableCompanyWideSharingLinks = [string](Get-SafeProperty $Site 'DisableCompanyWideSharingLinks')
                        SharingDomainRestrictionMode = [string](Get-SafeProperty $Site 'SharingDomainRestrictionMode')
                        ExternalUserExpirationInDays = [string](Get-SafeProperty $Site 'ExternalUserExpirationInDays')
                        AnonymousLinkExpirationInDays = [string](Get-SafeProperty $Site 'AnonymousLinkExpirationInDays')
                        SensitivityLabel             = [string](Get-SafeProperty $Site 'SensitivityLabel')
                        ConditionalAccessPolicy      = [string](Get-SafeProperty $Site 'ConditionalAccessPolicy')
                        ClassificacaoConfiguracao    = Get-SharingClassification $SiteSharing
                        Observacao                   = 'Configuração potencial; não comprova oversharing.'
                    })
                }
                catch {
                    [void]$SiteErrors.Add([PSCustomObject]@{
                        DataHoraUtc = (Get-Date).ToUniversalTime()
                        Url         = [string]$IndexItem.Url
                        Etapa       = 'Get-SPOSite -Identity'
                        Erro        = $_.Exception.Message
                    })
                }
            }
            Write-Progress -Activity 'Consultando sites SharePoint' -Completed
            $SitesWithErrors = $SiteErrors.Count
            Export-Records $Paths.Sites @($SiteResults) 'Get-SPOSite por Identity'
            Export-Records `
                $Paths.SiteErrors `
                @($SiteErrors) `
                'Erros por site' `
                'Nenhum erro registrado na coleta por site.'
            Write-Step 'Inventariando relatórios Data Access Governance'
            $Queries = @(
                [PSCustomObject]@{
                    Nome       = 'Atividade EEEU no nível do site'
                    Parameters = @{
                        ReportEntity = 'EveryoneExceptExternalUsersAtSite'
                        Workload     = 'SharePoint'
                        ReportType   = 'RecentActivity'
                    }
                },
                [PSCustomObject]@{
                    Nome       = 'Atividade EEEU no nível de itens'
                    Parameters = @{
                        ReportEntity = 'EveryoneExceptExternalUsersForItems'
                        Workload     = 'SharePoint'
                        ReportType   = 'RecentActivity'
                    }
                },
                [PSCustomObject]@{
                    Nome       = 'Baseline de permissões do SharePoint'
                    Parameters = @{
                        ReportEntity = 'PermissionedUsers'
                        Workload     = 'SharePoint'
                        ReportType   = 'Snapshot'
                    }
                },
                [PSCustomObject]@{
                    Nome       = 'Snapshot detalhado Everyone/EEEU'
                    Parameters = @{
                        ReportEntity = 'EveryoneExceptExternalUsers'
                        ReportType   = 'Snapshot'
                    }
                }
            )
            foreach ($Query in $Queries) {
                try {
                    $QueryParameters = $Query.Parameters
                    $Reports = @(
                        Get-SPODataAccessGovernanceInsight @QueryParameters `
                            -ErrorAction Stop
                    )
                    [void]$DagQueryEvidence.Add([PSCustomObject]@{
                        Consulta  = $Query.Nome
                        Status    = 'Sucesso'
                        Quantidade = $Reports.Count
                        Detalhe   = if ($Reports.Count -gt 0) {
                            'Relatórios existentes encontrados.'
                        }
                        else {
                            'Consulta concluída sem relatórios existentes.'
                        }
                    })
                    foreach ($Report in $Reports) {
                        [void]$DagReportEvidence.Add(
                            (Convert-DagReportToEvidence $Report $Query.Nome)
                        )
                    }
                }
                catch {
                    [void]$DagQueryEvidence.Add([PSCustomObject]@{
                        Consulta   = $Query.Nome
                        Status     = 'Falha'
                        Quantidade = 0
                        Detalhe    = $_.Exception.Message
                    })
                }
            }
            $ReportsFound = $DagReportEvidence.Count
            Export-Records $Paths.DagQueries @($DagQueryEvidence) 'Consultas DAG'
            Export-Records `
                $Paths.DagReports `
                @($DagReportEvidence) `
                'Relatórios DAG' `
                'Consultas concluídas sem relatórios existentes.'
            $QualityGate = if ($SitesWithErrors -eq 0) {
                'Aprovado - coleta administrativa'
            }
            else {
                'Parcial - erros na coleta por site'
            }
        }
        'HabilitarColeta' {
            Write-Step 'Habilitando coleta de atividade EEEU'
            foreach ($Entity in (Get-ActivityEntities $EscopoEEEU)) {
                $Before = Get-SPOAuditDataCollectionStatusForActivityInsights `
                    -ReportEntity $Entity `
                    -ErrorAction Stop
                $BeforeStatus = Get-CollectionStatusValue $Before
                [void]$CollectionBefore.Add([PSCustomObject]@{
                    ReportEntity = $Entity
                    Status       = $BeforeStatus
                })
                Start-SPOAuditDataCollectionForActivityInsights `
                    -ReportEntity $Entity `
                    -ErrorAction Stop
                $After = Get-SPOAuditDataCollectionStatusForActivityInsights `
                    -ReportEntity $Entity `
                    -ErrorAction Stop
                $AfterStatus = Get-CollectionStatusValue $After
                [void]$CollectionAfter.Add([PSCustomObject]@{
                    ReportEntity = $Entity
                    Status       = $AfterStatus
                })
                [void]$ActionEvidence.Add([PSCustomObject]@{
                    Acao         = $Acao
                    ReportEntity = $Entity
                    Antes        = $BeforeStatus
                    Depois       = $AfterStatus
                    Justificativa = $Justificativa
                })
            }
            Export-Records $Paths.CollectionBefore @($CollectionBefore) 'Coleta antes'
            Export-Records $Paths.CollectionAfter @($CollectionAfter) 'Coleta depois'
            $QualityGate = if (
                @($CollectionAfter | Where-Object { $_.Status -ne 'InProgress' }).Count -eq 0
            ) {
                'Aprovado - coleta em andamento'
            }
            else {
                'Parcial - revisar estado da coleta'
            }
        }
        'DesabilitarColeta' {
            Write-Step 'Desabilitando coleta de atividade EEEU'
            foreach ($Entity in (Get-ActivityEntities $EscopoEEEU)) {
                $Before = Get-SPOAuditDataCollectionStatusForActivityInsights `
                    -ReportEntity $Entity `
                    -ErrorAction Stop
                $BeforeStatus = Get-CollectionStatusValue $Before
                [void]$CollectionBefore.Add([PSCustomObject]@{
                    ReportEntity = $Entity
                    Status       = $BeforeStatus
                })
                Stop-SPOAuditDataCollectionForActivityInsights `
                    -ReportEntity $Entity `
                    -ErrorAction Stop
                $After = Get-SPOAuditDataCollectionStatusForActivityInsights `
                    -ReportEntity $Entity `
                    -ErrorAction Stop
                $AfterStatus = Get-CollectionStatusValue $After
                [void]$CollectionAfter.Add([PSCustomObject]@{
                    ReportEntity = $Entity
                    Status       = $AfterStatus
                })
                [void]$ActionEvidence.Add([PSCustomObject]@{
                    Acao          = $Acao
                    ReportEntity  = $Entity
                    Antes         = $BeforeStatus
                    Depois        = $AfterStatus
                    Justificativa = $Justificativa
                })
            }
            Export-Records $Paths.CollectionBefore @($CollectionBefore) 'Coleta antes'
            Export-Records $Paths.CollectionAfter @($CollectionAfter) 'Coleta depois'
            $QualityGate = if (
                @($CollectionAfter | Where-Object { $_.Status -ne 'Paused' }).Count -eq 0
            ) {
                'Aprovado - coleta pausada'
            }
            else {
                'Parcial - revisar estado da coleta'
            }
        }
        'IniciarRelatorioAtividadeSites' {
            Write-Step 'Iniciando relatório de atividade EEEU por site'
            $Status = Get-SPOAuditDataCollectionStatusForActivityInsights `
                -ReportEntity EveryoneExceptExternalUsersAtSite `
                -ErrorAction Stop
            $StatusValue = Get-CollectionStatusValue $Status
            if ($StatusValue -ne 'InProgress' -and -not $HasSamCandidate) {
                throw @"
A coleta para EveryoneExceptExternalUsersAtSite não está InProgress.
Execute HabilitarColeta e aguarde pelo menos 24 horas antes do relatório.
Estado atual: $StatusValue
"@
            }
            $Created = Start-SPODataAccessGovernanceInsight `
                -ReportEntity EveryoneExceptExternalUsersAtSite `
                -Workload SharePoint `
                -ReportType RecentActivity `
                -Name $NomeRelatorio `
                -ErrorAction Stop
            $CreatedEvidence = Convert-DagReportToEvidence $Created 'Relatório EEEU por site'
            [void]$DagReportEvidence.Add($CreatedEvidence)
            $ReportStartedId = $CreatedEvidence.ReportId
            $QualityGate = if ([string]::IsNullOrWhiteSpace($ReportStartedId)) {
                'Parcial - relatório iniciado sem ReportId capturado'
            }
            else {
                'Aprovado - relatório iniciado'
            }
        }
        'IniciarRelatorioAtividadeItens' {
            Write-Step 'Iniciando relatório de atividade EEEU por item'
            $Status = Get-SPOAuditDataCollectionStatusForActivityInsights `
                -ReportEntity EveryoneExceptExternalUsersForItems `
                -ErrorAction Stop
            $StatusValue = Get-CollectionStatusValue $Status
            if ($StatusValue -ne 'InProgress' -and -not $HasSamCandidate) {
                throw @"
A coleta para EveryoneExceptExternalUsersForItems não está InProgress.
Execute HabilitarColeta e aguarde pelo menos 24 horas antes do relatório.
Estado atual: $StatusValue
"@
            }
            $Created = Start-SPODataAccessGovernanceInsight `
                -ReportEntity EveryoneExceptExternalUsersForItems `
                -Workload SharePoint `
                -ReportType RecentActivity `
                -Name $NomeRelatorio `
                -ErrorAction Stop
            $CreatedEvidence = Convert-DagReportToEvidence $Created 'Relatório EEEU por item'
            [void]$DagReportEvidence.Add($CreatedEvidence)
            $ReportStartedId = $CreatedEvidence.ReportId
            $QualityGate = if ([string]::IsNullOrWhiteSpace($ReportStartedId)) {
                'Parcial - relatório iniciado sem ReportId capturado'
            }
            else {
                'Aprovado - relatório iniciado'
            }
        }
        'IniciarBaselinePermissoes' {
            Write-Step 'Iniciando baseline de permissões do SharePoint'
            $Created = Start-SPODataAccessGovernanceInsight `
                -ReportEntity PermissionedUsers `
                -Workload SharePoint `
                -ReportType Snapshot `
                -Name $NomeRelatorio `
                -CountOfUsersMoreThan $CountOfUsersMoreThan `
                -ErrorAction Stop
            $CreatedEvidence = Convert-DagReportToEvidence $Created 'Baseline de permissões'
            [void]$DagReportEvidence.Add($CreatedEvidence)
            $ReportStartedId = $CreatedEvidence.ReportId
            $QualityGate = if ([string]::IsNullOrWhiteSpace($ReportStartedId)) {
                'Parcial - baseline iniciado sem ReportId capturado'
            }
            else {
                'Aprovado - baseline iniciado'
            }
        }
        'IniciarSnapshotDetalhadoEEEU' {
            Write-Step 'Iniciando snapshot detalhado Everyone/EEEU'
            $Baseline = @(
                Get-SPODataAccessGovernanceInsight `
                    -ReportEntity PermissionedUsers `
                    -Workload SharePoint `
                    -ReportType Snapshot `
                    -ErrorAction Stop
            )
            if ($Baseline.Count -eq 0) {
                throw @'
O snapshot detalhado Everyone/EEEU exige que o baseline de permissões
da organização tenha sido gerado pelo menos uma vez.
'@
            }
            $Created = Start-SPODataAccessGovernanceInsight `
                -ReportEntity EveryoneExceptExternalUsers `
                -ReportType Snapshot `
                -ErrorAction Stop
            $CreatedEvidence = Convert-DagReportToEvidence $Created 'Snapshot detalhado Everyone/EEEU'
            [void]$DagReportEvidence.Add($CreatedEvidence)
            $ReportStartedId = $CreatedEvidence.ReportId
            $QualityGate = if ([string]::IsNullOrWhiteSpace($ReportStartedId)) {
                'Parcial - snapshot iniciado sem ReportId capturado'
            }
            else {
                'Aprovado - snapshot detalhado iniciado'
            }
        }
        'ConsultarRelatorio' {
            Write-Step 'Consultando relatório por ReportId'
            $Report = Get-SPODataAccessGovernanceInsight `
                -ReportID $ReportId `
                -ErrorAction Stop
            $Evidence = Convert-DagReportToEvidence $Report 'Consulta por ReportId'
            [void]$DagReportEvidence.Add($Evidence)
            $ReportsFound = 1
            $QualityGate = 'Aprovado - relatório consultado'
        }
        'ExportarRelatorio' {
            Write-Step 'Validando e exportando relatório'
            $Report = Get-SPODataAccessGovernanceInsight `
                -ReportID $ReportId `
                -ErrorAction Stop
            $Evidence = Convert-DagReportToEvidence $Report 'Exportação por ReportId'
            [void]$DagReportEvidence.Add($Evidence)
            if ($Evidence.Status -notmatch 'Completed|Available|Ready') {
                throw "O relatório ainda não está concluído. Status atual: $($Evidence.Status)"
            }
            Export-SPODataAccessGovernanceInsight `
                -ReportID $ReportId `
                -DownloadPath $EvidenceDirectory `
                -ErrorAction Stop
            $ExportedReportPath = $EvidenceDirectory
            $QualityGate = 'Aprovado - relatório exportado'
        }
        'ConfigurarCompartilhamentoSite' {
            Write-Step 'Alterando compartilhamento do site de laboratório'
            $Before = Get-SPOSite -Identity $SiteUrl -ErrorAction Stop
            $BeforeEvidence = [PSCustomObject]@{
                DataHoraUtc       = (Get-Date).ToUniversalTime()
                Url               = [string]$Before.Url
                Title             = [string]$Before.Title
                SharingCapability = [string]$Before.SharingCapability
            }
            Export-Records $Paths.ConfigBefore @($BeforeEvidence) 'Configuração antes'
            Set-SPOSite `
                -Identity $SiteUrl `
                -SharingCapability $SharingCapability `
                -ErrorAction Stop
            $After = Get-SPOSite -Identity $SiteUrl -ErrorAction Stop
            $AfterEvidence = [PSCustomObject]@{
                DataHoraUtc       = (Get-Date).ToUniversalTime()
                Url               = [string]$After.Url
                Title             = [string]$After.Title
                SharingCapability = [string]$After.SharingCapability
            }
            Export-Records $Paths.ConfigAfter @($AfterEvidence) 'Configuração depois'
            [void]$ActionEvidence.Add([PSCustomObject]@{
                Acao          = $Acao
                Recurso       = $SiteUrl
                Antes         = $BeforeEvidence.SharingCapability
                Depois        = $AfterEvidence.SharingCapability
                Justificativa = $Justificativa
            })
            $QualityGate = if (
                $AfterEvidence.SharingCapability -eq $SharingCapability
            ) {
                'Aprovado - configuração alterada e verificada'
            }
            else {
                'Falha - estado final diferente do solicitado'
            }
        }
    }
    Export-Records `
        $Paths.Actions `
        @($ActionEvidence) `
        'Ações administrativas' `
        'Nenhuma alteração administrativa executada.'
    Export-Records `
        $Paths.DagReports `
        @($DagReportEvidence) `
        'Relatórios DAG' `
        'Nenhum relatório retornado nesta ação.'
    $Summary = [PSCustomObject]@{
        Automacao                   = $AutomationId
        Nome                        = $AutomationName
        Acao                        = $Acao
        Inicio                      = $StartedAt
        Fim                         = Get-Date
        TenantId                    = $TenantId
        Conta                       = $AdminUPN
        SharePointAdminUrl          = $SharePointAdminUrl
        VersaoModuloSharePoint      = [string]$SharePointModule.Version
        FuncoesAtivas               = ($RoleNames -join '; ')
        PossuiSharePointAdmin       = $HasSharePointAdminRole
        PossuiSamAdmin              = $HasSamAdminRole
        AvaliacaoLicenciamento      = $LicenseAssessment
        SitesEnumerados             = $SitesEnumerated
        SitesComErro                = $SitesWithErrors
        RelatoriosEncontrados       = $ReportsFound
        ReportIdIniciado            = $ReportStartedId
        DiretorioExportacao         = $ExportedReportPath
        ConfirmarAlteracao          = $ConfirmarAlteracao.IsPresent
        Justificativa               = $Justificativa
        QualityGate                 = $QualityGate
        PastaEvidencias             = $EvidenceDirectory
        Conclusao                   = (
            'A configuração de compartilhamento indica exposição potencial. ' +
            'Oversharing efetivo depende da análise dos relatórios DAG, do ' +
            'contexto do conteúdo e da validação dos proprietários.'
        )
    }
    Export-Records $Paths.SummaryCsv @($Summary) 'Resumo AUTO-34'
    $Summary |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $Paths.SummaryJson -Encoding utf8
    $Completed = $true
    Write-Host ''
    Write-Host '============================================================'
    Write-Host " AUTO-34 FINALIZADA - $QualityGate"
    Write-Host '============================================================'
    Write-Host "Ação: $Acao"
    Write-Host "Licenciamento: $LicenseAssessment"
    Write-Host "Sites enumerados: $SitesEnumerated"
    Write-Host "Sites com erro: $SitesWithErrors"
    Write-Host "ReportId iniciado: $ReportStartedId"
    Write-Host "Evidências: $EvidenceDirectory"
    Write-Host '============================================================' -ForegroundColor Green
}
catch {
    $FailureSummary = [PSCustomObject]@{
        Automacao       = $AutomationId
        Nome            = $AutomationName
        Acao            = $Acao
        Inicio          = $StartedAt
        Fim             = Get-Date
        QualityGate     = 'Falha'
        Erro            = $_.Exception.Message
        PastaEvidencias = $EvidenceDirectory
    }
    try {
        Export-Records $Paths.SummaryCsv @($FailureSummary) 'Resumo de falha AUTO-34'
        $FailureSummary |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $Paths.SummaryJson -Encoding utf8
    }
    catch {
        Write-Warning 'Não foi possível gravar o resumo de falha.'
    }
    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' AUTO-34 ENCERRADA COM ERRO' -ForegroundColor Red
    Write-Host '============================================================'
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Evidências: $EvidenceDirectory" -ForegroundColor Yellow
    throw
}
finally {
    if ($TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Warning 'Não foi possível encerrar o transcript de forma limpa.'
        }
    }
    if (-not $Completed) {
        Write-Host 'Execução não concluída. Revise execucao.log e resumo.json.' `
            -ForegroundColor Yellow
    }
}
