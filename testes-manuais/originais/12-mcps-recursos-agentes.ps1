#requires -Version 5.1
<#
.SYNOPSIS
    AUTO-12 - MCPs e recursos para agentes.

.DESCRIPTION
    Valida pre-requisitos, consulta conectores, prepara acesso temporario,
    cria ou atualiza um conector e classifica o conector em politica DLP.

    FERRAMENTA:
    - Windows PowerShell 5.1
    - Microsoft Power Platform CLI (pac)
    - Microsoft Graph PowerShell
    - Microsoft.PowerApps.Administration.PowerShell
    - Microsoft.PowerApps.PowerShell

    PERMISSAO:
    - Conta autorizada no tenant e no ambiente de laboratorio.
    - As operacoes de alteracao exigem funcao administrativa compativel.

    LICENCA:
    - As licencas sao inventariadas pelo script quando a sessao Graph
      estiver disponivel. A existencia de uma SKU nao substitui a validacao
      funcional do recurso no ambiente.

    EFEITO:
    - Validar e Consultar nao devem alterar configuracoes.
    - PrepararAcesso, Criar, Atualizar e Classificar alteram o ambiente.

    ATENCAO:
    - As acoes de alteracao exigem -ConfirmarAlteracao e -Justificativa.
    - Use somente ambiente e credenciais de laboratorio.
    - Nao armazene senha, token, codigo MFA ou segredo neste arquivo.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'Validar',
        'Consultar',
        'PrepararAcesso',
        'Criar',
        'Atualizar',
        'ClassificarBusiness',
        'ClassificarNonBusiness'
    )]
    [string]$Acao,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AdminUPN,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentId,

    [string]$ApiDefinitionPath,
    [string]$ApiPropertiesPath,
    [string]$ConnectorId,
    [string]$ConnectorName,
    [string]$DlpPolicyId,
    [string]$Justificativa,
    [switch]$ConfirmarAlteracao,

    [string]$EvidenceRoot = (Join-Path -Path $PSScriptRoot -ChildPath 'evidencias\AUTO-12-MCPs-e-recursos')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Script:AutomationId = 'AUTO-12'
$Script:AutomationName = 'MCPs e recursos para agentes'
$Script:StartTime = Get-Date
$Script:QualityGate = 'Nao avaliado'
$Script:FinalError = $null
$Script:TranscriptStarted = $false
$Script:PowerPlatformConnected = $false

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Text)

    Write-Host ''
    Write-Host ('=' * 53) -ForegroundColor Cyan
    Write-Host (' ' + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 53) -ForegroundColor Cyan
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][string]$Text
    )

    Write-Host ('{0}. {1}' -f $Number, $Text) -ForegroundColor Cyan
}

function New-DirectoryIfMissing {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content
    )

    $Encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, [string]$Content, $Encoding)
}

function Export-Utf8Csv {
    <#
        Implementacao deliberadamente simples para Windows PowerShell 5.1.
        Nao recebe colecoes genericas diretamente em Export-Csv. Cada item e
        copiado para um array PowerShell comum antes da conversao.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][object]$InputObject
    )

    $Rows = @()

    if ($null -ne $InputObject) {
        foreach ($Item in $InputObject) {
            if ($null -ne $Item) {
                $Rows += $Item
            }
        }
    }

    if ($Rows.Count -eq 0) {
        Write-Utf8Text -Path $Path -Content ''
        return
    }

    $CsvLines = @($Rows | ConvertTo-Csv -NoTypeInformation)
    $Encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($Path, [string[]]$CsvLines, $Encoding)
}

function Get-SafePropertyValue {
    <#
        Le uma propriedade sem depender de capitalizacao ou do tipo concreto
        retornado pelo modulo. Suporta PSCustomObject, objetos .NET,
        Hashtable e outros IDictionary.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [AllowNull()][object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    foreach ($Name in $Names) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($Key in @($InputObject.Keys)) {
                if ([string]$Key -ieq $Name) {
                    return $InputObject[$Key]
                }
            }
        }

        $Property = $InputObject.PSObject.Properties |
            Where-Object { $_.Name -ieq $Name } |
            Select-Object -First 1

        if ($null -ne $Property) {
            return $Property.Value
        }
    }

    return $DefaultValue
}

function Convert-ValueToEvidenceText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [string] -or $Value -is [ValueType]) {
        return [string]$Value
    }

    try {
        return ($Value | ConvertTo-Json -Depth 12 -Compress -ErrorAction Stop)
    }
    catch {
        return (($Value | Out-String).Trim())
    }
}

function Assert-GuidValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$ParameterName
    )

    $ParsedGuid = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$ParsedGuid)) {
        throw ('O parametro {0} nao contem um GUID valido: {1}' -f $ParameterName, $Value)
    }
}

function Assert-UpnValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$ParameterName
    )

    if ($Value -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        throw ('O parametro {0} nao contem um UPN valido: {1}' -f $ParameterName, $Value)
    }
}

function Assert-FileValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ParameterName
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw ('O parametro {0} precisa ser informado.' -f $ParameterName)
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('Arquivo nao encontrado em {0}: {1}' -f $ParameterName, $Path)
    }
}

function Assert-ChangeAuthorization {
    if (-not $ConfirmarAlteracao.IsPresent) {
        throw 'A acao solicitada altera configuracoes. Informe -ConfirmarAlteracao.'
    }

    if ([string]::IsNullOrWhiteSpace($Justificativa)) {
        throw 'Informe -Justificativa para executar uma acao de alteracao.'
    }
}

function Get-CommandCapability {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Category,
        [string]$ExpectedModule
    )

    $Command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1

    [PSCustomObject]@{
        Categoria       = $Category
        Item            = $Name
        Disponivel      = ($null -ne $Command)
        Tipo             = if ($null -ne $Command) { [string]$Command.CommandType } else { 'Nao encontrado' }
        ModuloEsperado   = $ExpectedModule
        ModuloEncontrado = if ($null -ne $Command) { [string]$Command.Source } else { '' }
        Versao           = if (($null -ne $Command) -and ($null -ne $Command.Version)) { [string]$Command.Version } else { '' }
        Caminho          = if ($null -ne $Command) { [string]$Command.Definition } else { '' }
    }
}

function Get-ModuleCapability {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Category
    )

    $Module = Get-Module -ListAvailable -Name $Name |
        Sort-Object Version -Descending |
        Select-Object -First 1

    [PSCustomObject]@{
        Categoria       = $Category
        Item            = $Name
        Disponivel      = ($null -ne $Module)
        Tipo             = 'Modulo PowerShell'
        ModuloEsperado   = $Name
        ModuloEncontrado = if ($null -ne $Module) { [string]$Module.Name } else { '' }
        Versao           = if ($null -ne $Module) { [string]$Module.Version } else { '' }
        Caminho          = if ($null -ne $Module) { [string]$Module.Path } else { '' }
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [switch]$AllowFailure
    )

    $DisplayCommand = $FilePath + ' ' + ($ArgumentList -join ' ')
    Write-Host ('Executando: {0}' -f $DisplayCommand) -ForegroundColor DarkGray

    $PreviousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        $Output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousPreference
    }

    $Text = ($Output -join [Environment]::NewLine).Trim()

    if ((-not $AllowFailure.IsPresent) -and ($ExitCode -ne 0)) {
        throw ('Comando falhou com codigo {0}: {1}{2}{3}' -f $ExitCode, $DisplayCommand, [Environment]::NewLine, $Text)
    }

    [PSCustomObject]@{
        Command  = $DisplayCommand
        ExitCode = $ExitCode
        Output   = $Text
    }
}

function Import-RequiredModule {
    param([Parameter(Mandatory = $true)][string]$Name)

    $Module = Get-Module -ListAvailable -Name $Name |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -eq $Module) {
        throw ('Modulo obrigatorio nao encontrado: {0}' -f $Name)
    }

    Import-Module -Name $Name -DisableNameChecking -Force -ErrorAction Stop
    return $Module
}

function Connect-PowerPlatformIfNeeded {
    if ($Script:PowerPlatformConnected) {
        return
    }

    Import-RequiredModule -Name 'Microsoft.PowerApps.Administration.PowerShell' | Out-Null

    $ExistingAccount = $null
    if (Get-Command -Name Get-PowerAppsAccount -ErrorAction SilentlyContinue) {
        try {
            $ExistingAccount = Get-PowerAppsAccount -ErrorAction Stop
        }
        catch {
            $ExistingAccount = $null
        }
    }

    if ($null -eq $ExistingAccount) {
        Write-Host 'Abrindo autenticacao da Power Platform...' -ForegroundColor Yellow
        Add-PowerAppsAccount -Endpoint prod -TenantID $TenantId -ErrorAction Stop | Out-Null
    }

    $Script:PowerPlatformConnected = $true
}

function Get-PacIdentityEvidence {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)

    $AuthList = Invoke-NativeCommand -FilePath 'pac' -ArgumentList @('auth', 'list') -AllowFailure
    Write-Utf8Text -Path $Paths.PacAuthList -Content $AuthList.Output

    $AuthWho = Invoke-NativeCommand -FilePath 'pac' -ArgumentList @('auth', 'who') -AllowFailure
    Write-Utf8Text -Path $Paths.PacAuthWho -Content $AuthWho.Output

    $EnvWho = Invoke-NativeCommand -FilePath 'pac' -ArgumentList @('env', 'who', '--environment', $EnvironmentId) -AllowFailure
    Write-Utf8Text -Path $Paths.PacEnvWho -Content $EnvWho.Output

    [PSCustomObject]@{
        AuthListExitCode = $AuthList.ExitCode
        AuthWhoExitCode  = $AuthWho.ExitCode
        EnvWhoExitCode   = $EnvWho.ExitCode
        AuthListOutput   = $AuthList.Output
        AuthWhoOutput    = $AuthWho.Output
        EnvWhoOutput     = $EnvWho.Output
    }
}

function Get-GraphEvidence {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)

    $RoleRows = @()
    $TenantLicenseRows = @()
    $UserLicenseRows = @()
    $GraphContextRow = @()

    $GraphAuthModule = Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication' |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -eq $GraphAuthModule) {
        $GraphContextRow += [PSCustomObject]@{
            Conectado = $false
            TenantId  = ''
            Conta     = ''
            Scopes    = ''
            Observacao = 'Microsoft.Graph.Authentication nao encontrado.'
        }

        Export-Utf8Csv -Path $Paths.GraphContext -InputObject $GraphContextRow
        Export-Utf8Csv -Path $Paths.AdminRoles -InputObject $RoleRows
        Export-Utf8Csv -Path $Paths.TenantLicenses -InputObject $TenantLicenseRows
        Export-Utf8Csv -Path $Paths.UserLicenses -InputObject $UserLicenseRows
        return
    }

    Import-Module Microsoft.Graph.Authentication -Force -ErrorAction Stop
    $Context = Get-MgContext -ErrorAction SilentlyContinue

    if ($null -eq $Context) {
        $GraphContextRow += [PSCustomObject]@{
            Conectado = $false
            TenantId  = ''
            Conta     = ''
            Scopes    = ''
            Observacao = 'Nenhuma sessao Microsoft Graph ativa.'
        }

        Export-Utf8Csv -Path $Paths.GraphContext -InputObject $GraphContextRow
        Export-Utf8Csv -Path $Paths.AdminRoles -InputObject $RoleRows
        Export-Utf8Csv -Path $Paths.TenantLicenses -InputObject $TenantLicenseRows
        Export-Utf8Csv -Path $Paths.UserLicenses -InputObject $UserLicenseRows
        return
    }

    $GraphContextRow += [PSCustomObject]@{
        Conectado = $true
        TenantId  = [string]$Context.TenantId
        Conta     = [string]$Context.Account
        Scopes    = (@($Context.Scopes) -join ';')
        Observacao = ''
    }

    if (Get-Command -Name Get-MgSubscribedSku -ErrorAction SilentlyContinue) {
        try {
            foreach ($Sku in @(Get-MgSubscribedSku -All -ErrorAction Stop)) {
                $TenantLicenseRows += [PSCustomObject]@{
                    SkuPartNumber = [string]$Sku.SkuPartNumber
                    SkuId         = [string]$Sku.SkuId
                    ConsumedUnits = [string]$Sku.ConsumedUnits
                    EnabledUnits  = if ($null -ne $Sku.PrepaidUnits) { [string]$Sku.PrepaidUnits.Enabled } else { '' }
                    WarningUnits  = if ($null -ne $Sku.PrepaidUnits) { [string]$Sku.PrepaidUnits.Warning } else { '' }
                    SuspendedUnits = if ($null -ne $Sku.PrepaidUnits) { [string]$Sku.PrepaidUnits.Suspended } else { '' }
                }
            }
        }
        catch {
            $TenantLicenseRows += [PSCustomObject]@{
                SkuPartNumber = ''
                SkuId = ''
                ConsumedUnits = ''
                EnabledUnits = ''
                WarningUnits = ''
                SuspendedUnits = ''
                Erro = $_.Exception.Message
            }
        }
    }

    $User = $null
    if (Get-Command -Name Get-MgUser -ErrorAction SilentlyContinue) {
        try {
            $User = Get-MgUser -UserId $AdminUPN -Property 'id,userPrincipalName,accountEnabled,assignedLicenses,assignedPlans' -ErrorAction Stop

            foreach ($License in @($User.AssignedLicenses)) {
                $UserLicenseRows += [PSCustomObject]@{
                    UserPrincipalName = [string]$User.UserPrincipalName
                    AccountEnabled    = [string]$User.AccountEnabled
                    SkuId             = [string]$License.SkuId
                    DisabledPlans     = (@($License.DisabledPlans) -join ';')
                }
            }

            if (@($User.AssignedLicenses).Count -eq 0) {
                $UserLicenseRows += [PSCustomObject]@{
                    UserPrincipalName = [string]$User.UserPrincipalName
                    AccountEnabled    = [string]$User.AccountEnabled
                    SkuId             = ''
                    DisabledPlans     = ''
                }
            }
        }
        catch {
            $UserLicenseRows += [PSCustomObject]@{
                UserPrincipalName = $AdminUPN
                AccountEnabled = ''
                SkuId = ''
                DisabledPlans = ''
                Erro = $_.Exception.Message
            }
        }
    }

    if (($null -ne $User) -and
        (Get-Command -Name Get-MgRoleManagementDirectoryRoleAssignment -ErrorAction SilentlyContinue) -and
        (Get-Command -Name Get-MgRoleManagementDirectoryRoleDefinition -ErrorAction SilentlyContinue)) {
        try {
            $Assignments = @(Get-MgRoleManagementDirectoryRoleAssignment -Filter ("principalId eq '{0}'" -f $User.Id) -All -ErrorAction Stop)

            foreach ($Assignment in $Assignments) {
                $Definition = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId -ErrorAction Stop
                $RoleRows += [PSCustomObject]@{
                    UserPrincipalName = [string]$User.UserPrincipalName
                    RoleName          = [string]$Definition.DisplayName
                    RoleDefinitionId  = [string]$Assignment.RoleDefinitionId
                    DirectoryScopeId  = [string]$Assignment.DirectoryScopeId
                    AssignmentId      = [string]$Assignment.Id
                }
            }
        }
        catch {
            $RoleRows += [PSCustomObject]@{
                UserPrincipalName = $AdminUPN
                RoleName = ''
                RoleDefinitionId = ''
                DirectoryScopeId = ''
                AssignmentId = ''
                Erro = $_.Exception.Message
            }
        }
    }

    Export-Utf8Csv -Path $Paths.GraphContext -InputObject $GraphContextRow
    Export-Utf8Csv -Path $Paths.AdminRoles -InputObject $RoleRows
    Export-Utf8Csv -Path $Paths.TenantLicenses -InputObject $TenantLicenseRows
    Export-Utf8Csv -Path $Paths.UserLicenses -InputObject $UserLicenseRows
}

function Get-PreflightEvidence {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)

    Write-Step -Number 1 -Text 'Validando modulos, comandos e PAC CLI...'

    $Capabilities = @()

    $Capabilities += Get-CommandCapability -Name 'pac' -Category 'Executavel' -ExpectedModule 'Power Platform CLI'
    $Capabilities += Get-CommandCapability -Name 'Connect-MgGraph' -Category 'Microsoft Graph' -ExpectedModule 'Microsoft.Graph.Authentication'
    $Capabilities += Get-CommandCapability -Name 'Get-MgContext' -Category 'Microsoft Graph' -ExpectedModule 'Microsoft.Graph.Authentication'
    $Capabilities += Get-CommandCapability -Name 'Get-MgUser' -Category 'Microsoft Graph' -ExpectedModule 'Microsoft.Graph.Users'
    $Capabilities += Get-CommandCapability -Name 'Get-MgSubscribedSku' -Category 'Microsoft Graph' -ExpectedModule 'Microsoft.Graph.Identity.DirectoryManagement'
    $Capabilities += Get-CommandCapability -Name 'Add-PowerAppsAccount' -Category 'Power Platform' -ExpectedModule 'Microsoft.PowerApps.Administration.PowerShell'
    $Capabilities += Get-CommandCapability -Name 'Get-DlpPolicy' -Category 'Power Platform' -ExpectedModule 'Microsoft.PowerApps.Administration.PowerShell'
    $Capabilities += Get-CommandCapability -Name 'Add-CustomConnectorToPolicy' -Category 'Power Platform' -ExpectedModule 'Microsoft.PowerApps.Administration.PowerShell'

    $Capabilities += Get-ModuleCapability -Name 'Microsoft.Graph.Authentication' -Category 'Modulo'
    $Capabilities += Get-ModuleCapability -Name 'Microsoft.Graph.Users' -Category 'Modulo'
    $Capabilities += Get-ModuleCapability -Name 'Microsoft.Graph.Identity.DirectoryManagement' -Category 'Modulo'
    $Capabilities += Get-ModuleCapability -Name 'Microsoft.Graph.Identity.Governance' -Category 'Modulo'
    $Capabilities += Get-ModuleCapability -Name 'Microsoft.PowerApps.Administration.PowerShell' -Category 'Modulo'
    $Capabilities += Get-ModuleCapability -Name 'Microsoft.PowerApps.PowerShell' -Category 'Modulo'

    Export-Utf8Csv -Path $Paths.Modules -InputObject $Capabilities

    $RequiredFailures = @($Capabilities | Where-Object {
        ($_.Item -in @(
            'pac',
            'Microsoft.PowerApps.Administration.PowerShell',
            'Microsoft.PowerApps.PowerShell'
        )) -and (-not $_.Disponivel)
    })

    if ($RequiredFailures.Count -gt 0) {
        $MissingNames = @($RequiredFailures | ForEach-Object { $_.Item }) -join ', '
        throw ('Pre-requisitos obrigatorios nao encontrados: {0}' -f $MissingNames)
    }

    $PacHelp = Invoke-NativeCommand -FilePath 'pac' -ArgumentList @('help') -AllowFailure
    Write-Utf8Text -Path $Paths.PacHelp -Content $PacHelp.Output

    if ($PacHelp.ExitCode -ne 0) {
        throw 'O executavel pac foi encontrado, mas pac help nao concluiu com sucesso.'
    }

    $PacIdentity = Get-PacIdentityEvidence -Paths $Paths

    if ($PacIdentity.AuthWhoExitCode -ne 0) {
        throw 'pac auth who falhou. Crie ou selecione um perfil PAC valido antes de continuar.'
    }

    if ($PacIdentity.EnvWhoExitCode -ne 0) {
        throw 'pac env who falhou. Confirme o Environment ID e o acesso da conta ao ambiente.'
    }

    Get-GraphEvidence -Paths $Paths

    $ContextRows = @()
    $ContextRows += [PSCustomObject]@{
        DataHora                = Get-Date
        AutomationId            = $Script:AutomationId
        AutomationName          = $Script:AutomationName
        Acao                    = $Acao
        TenantId                = $TenantId
        AdminUPN                = $AdminUPN
        EnvironmentId           = $EnvironmentId
        ComputerName            = $env:COMPUTERNAME
        WindowsUser             = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        PowerShellVersion       = [string]$PSVersionTable.PSVersion
        PowerShellEdition       = [string]$PSVersionTable.PSEdition
        PacAuthWhoExitCode      = $PacIdentity.AuthWhoExitCode
        PacEnvWhoExitCode       = $PacIdentity.EnvWhoExitCode
        ConfirmarAlteracao      = $ConfirmarAlteracao.IsPresent
        Justificativa           = $Justificativa
        EvidenceFolder          = $Paths.Folder
    }

    Export-Utf8Csv -Path $Paths.Context -InputObject $ContextRows

    Write-Host 'Preflight concluido.' -ForegroundColor Green
}

function Get-ConnectorInventory {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $Result = Invoke-NativeCommand -FilePath 'pac' -ArgumentList @('connector', 'list', '--environment', $EnvironmentId) -AllowFailure
    Write-Utf8Text -Path $OutputPath -Content $Result.Output

    if ($Result.ExitCode -ne 0) {
        throw ('Nao foi possivel listar os conectores do ambiente. Saida: {0}' -f $Result.Output)
    }

    return $Result
}

function Get-DlpInventory {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)

    Connect-PowerPlatformIfNeeded

    $DlpCommandName = if (Get-Command -Name Get-AdminDlpPolicy -ErrorAction SilentlyContinue) {
        'Get-AdminDlpPolicy'
    }
    elseif (Get-Command -Name Get-DlpPolicy -ErrorAction SilentlyContinue) {
        'Get-DlpPolicy'
    }
    else {
        throw 'Nenhum comando de consulta DLP foi encontrado: Get-AdminDlpPolicy ou Get-DlpPolicy.'
    }

    if ($DlpCommandName -eq 'Get-AdminDlpPolicy') {
        $Policies = @(Get-AdminDlpPolicy -ErrorAction Stop)
    }
    else {
        $Policies = @(Get-DlpPolicy -ErrorAction Stop)
    }

    try {
        $RawJson = $Policies | ConvertTo-Json -Depth 30 -ErrorAction Stop
        Write-Utf8Text -Path $Paths.DlpPoliciesRaw -Content $RawJson
    }
    catch {
        $RawText = $Policies | Format-List * -Force | Out-String
        Write-Utf8Text -Path $Paths.DlpPoliciesRaw -Content $RawText
    }

    $PolicyRows = @()
    $PolicyIndex = 0

    foreach ($Policy in $Policies) {
        $PolicyIndex++

        $PropertyNames = @(
            $Policy.PSObject.Properties |
                ForEach-Object { $_.Name }
        )

        $DisplayName = Get-SafePropertyValue -InputObject $Policy -Names @(
            'DisplayName',
            'displayName',
            'Name',
            'name'
        )

        $PolicyName = Get-SafePropertyValue -InputObject $Policy -Names @(
            'PolicyName',
            'policyName',
            'PolicyId',
            'policyId',
            'Id',
            'id'
        )

        $EnvironmentType = Get-SafePropertyValue -InputObject $Policy -Names @(
            'EnvironmentType',
            'environmentType',
            'Type',
            'type'
        )

        $CreatedTime = Get-SafePropertyValue -InputObject $Policy -Names @(
            'CreatedTime',
            'createdTime',
            'CreatedAt',
            'createdAt'
        )

        $LastModifiedTime = Get-SafePropertyValue -InputObject $Policy -Names @(
            'LastModifiedTime',
            'lastModifiedTime',
            'ModifiedTime',
            'modifiedTime',
            'UpdatedAt',
            'updatedAt'
        )

        $DefaultClassification = Get-SafePropertyValue -InputObject $Policy -Names @(
            'DefaultConnectorClassification',
            'defaultConnectorClassification',
            'DefaultConnectorsClassification',
            'defaultConnectorsClassification'
        )

        $Environments = Get-SafePropertyValue -InputObject $Policy -Names @(
            'Environments',
            'environments'
        )

        $ConnectorGroups = Get-SafePropertyValue -InputObject $Policy -Names @(
            'ConnectorGroups',
            'connectorGroups'
        )

        $PolicyRows += [PSCustomObject]@{
            Indice                         = $PolicyIndex
            ComandoConsulta                = $DlpCommandName
            DisplayName                    = Convert-ValueToEvidenceText -Value $DisplayName
            PolicyName                     = Convert-ValueToEvidenceText -Value $PolicyName
            EnvironmentType                = Convert-ValueToEvidenceText -Value $EnvironmentType
            DefaultConnectorClassification = Convert-ValueToEvidenceText -Value $DefaultClassification
            CreatedTime                    = Convert-ValueToEvidenceText -Value $CreatedTime
            LastModifiedTime               = Convert-ValueToEvidenceText -Value $LastModifiedTime
            Environments                   = Convert-ValueToEvidenceText -Value $Environments
            ConnectorGroups                = Convert-ValueToEvidenceText -Value $ConnectorGroups
            TipoObjeto                     = [string]$Policy.GetType().FullName
            PropriedadesDisponiveis         = ($PropertyNames -join ';')
        }
    }

    Export-Utf8Csv -Path $Paths.DlpPolicies -InputObject $PolicyRows

    if ($Policies.Count -eq 0) {
        Write-Warning 'A consulta DLP nao retornou politicas.'
    }
    else {
        Write-Host ('Politicas DLP encontradas: {0}' -f $Policies.Count) -ForegroundColor Green
    }

    return $PolicyRows
}

function Invoke-ConsultAction {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)

    Write-Step -Number 2 -Text 'Coletando inventario de conectores e politicas DLP...'

    Get-ConnectorInventory -Paths $Paths -OutputPath $Paths.ConnectorsBefore | Out-Null
    Get-DlpInventory -Paths $Paths | Out-Null

    Write-Host 'Consulta concluida sem alteracao intencional.' -ForegroundColor Green
}

function Invoke-PrepareAccessAction {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)

    Assert-ChangeAuthorization

    Write-Step -Number 2 -Text 'Preparando acesso administrativo temporario ao ambiente...'

    $Arguments = @('admin', 'self-elevate', '--environment', $EnvironmentId)
    $Result = Invoke-NativeCommand -FilePath 'pac' -ArgumentList $Arguments
    Write-Utf8Text -Path $Paths.ActionResult -Content $Result.Output

    Write-Host 'Solicitacao de self-elevate concluida.' -ForegroundColor Green
}

function Invoke-CreateConnectorAction {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)

    Assert-ChangeAuthorization
    Assert-FileValue -Path $ApiDefinitionPath -ParameterName 'ApiDefinitionPath'
    Assert-FileValue -Path $ApiPropertiesPath -ParameterName 'ApiPropertiesPath'

    if ([string]::IsNullOrWhiteSpace($ConnectorName)) {
        throw 'Informe -ConnectorName para criar o conector.'
    }

    Write-Step -Number 2 -Text 'Registrando inventario anterior...'
    Get-ConnectorInventory -Paths $Paths -OutputPath $Paths.ConnectorsBefore | Out-Null

    Write-Step -Number 3 -Text 'Criando o conector no ambiente de laboratorio...'

    $Arguments = @(
        'connector', 'create',
        '--api-definition-file', $ApiDefinitionPath,
        '--api-properties-file', $ApiPropertiesPath,
        '--environment', $EnvironmentId
    )

    $Result = Invoke-NativeCommand -FilePath 'pac' -ArgumentList $Arguments
    Write-Utf8Text -Path $Paths.ActionResult -Content $Result.Output

    Write-Step -Number 4 -Text 'Registrando inventario posterior...'
    Get-ConnectorInventory -Paths $Paths -OutputPath $Paths.ConnectorsAfter | Out-Null

    Write-Host 'Criacao do conector concluida. Revise as evidencias.' -ForegroundColor Green
}

function Invoke-UpdateConnectorAction {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)

    Assert-ChangeAuthorization
    Assert-FileValue -Path $ApiDefinitionPath -ParameterName 'ApiDefinitionPath'
    Assert-FileValue -Path $ApiPropertiesPath -ParameterName 'ApiPropertiesPath'

    if ([string]::IsNullOrWhiteSpace($ConnectorId)) {
        throw 'Informe -ConnectorId para atualizar o conector.'
    }

    Write-Step -Number 2 -Text 'Registrando inventario anterior...'
    Get-ConnectorInventory -Paths $Paths -OutputPath $Paths.ConnectorsBefore | Out-Null

    Write-Step -Number 3 -Text 'Atualizando o conector no ambiente de laboratorio...'

    $Arguments = @(
        'connector', 'update',
        '--connector-id', $ConnectorId,
        '--api-definition-file', $ApiDefinitionPath,
        '--api-properties-file', $ApiPropertiesPath,
        '--environment', $EnvironmentId
    )

    $Result = Invoke-NativeCommand -FilePath 'pac' -ArgumentList $Arguments
    Write-Utf8Text -Path $Paths.ActionResult -Content $Result.Output

    Write-Step -Number 4 -Text 'Registrando inventario posterior...'
    Get-ConnectorInventory -Paths $Paths -OutputPath $Paths.ConnectorsAfter | Out-Null

    Write-Host 'Atualizacao do conector concluida. Revise as evidencias.' -ForegroundColor Green
}

function Invoke-DlpClassificationAction {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][ValidateSet('hbi', 'lbi')][string]$GroupName
    )

    Assert-ChangeAuthorization

    if ([string]::IsNullOrWhiteSpace($ConnectorId)) {
        throw 'Informe -ConnectorId para classificar o conector.'
    }

    if ([string]::IsNullOrWhiteSpace($ConnectorName)) {
        throw 'Informe -ConnectorName para classificar o conector.'
    }

    if ([string]::IsNullOrWhiteSpace($DlpPolicyId)) {
        throw 'Informe -DlpPolicyId para classificar o conector.'
    }

    Write-Step -Number 2 -Text 'Registrando configuracao DLP anterior...'
    $PoliciesBefore = @(Get-DlpInventory -Paths $Paths)
    Export-Utf8Csv -Path $Paths.ConfigurationBefore -InputObject $PoliciesBefore

    Write-Step -Number 3 -Text 'Classificando o conector na politica DLP...'

    Connect-PowerPlatformIfNeeded

    $Command = Get-Command -Name Add-CustomConnectorToPolicy -ErrorAction SilentlyContinue
    if ($null -eq $Command) {
        throw 'O comando Add-CustomConnectorToPolicy nao esta disponivel.'
    }

    $Parameters = @{
        PolicyName    = $DlpPolicyId
        ConnectorId   = $ConnectorId
        ConnectorName = $ConnectorName
        ConnectorType = 'Custom'
        GroupName     = $GroupName
        ErrorAction   = 'Stop'
    }

    $ClassificationResult = Add-CustomConnectorToPolicy @Parameters
    $ClassificationText = $ClassificationResult | Out-String
    Write-Utf8Text -Path $Paths.ActionResult -Content $ClassificationText

    Write-Step -Number 4 -Text 'Registrando configuracao DLP posterior...'
    $PoliciesAfter = @(Get-DlpInventory -Paths $Paths)
    Export-Utf8Csv -Path $Paths.ConfigurationAfter -InputObject $PoliciesAfter

    Write-Host ('Classificacao DLP concluida no grupo {0}.' -f $GroupName) -ForegroundColor Green
}

function Write-ManualValidationGuide {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)

    $Guide = @'
VALIDACAO MANUAL NO COPILOT STUDIO

1. Selecione o ambiente de laboratorio.
2. Abra um agente de teste dedicado.
3. Confirme que a orquestracao generativa esta habilitada.
4. Acesse Ferramentas e adicione uma ferramenta Model Context Protocol.
5. Selecione o conector criado para a prova AUTO-12.
6. Autorize somente com credenciais de laboratorio.
7. Revise as ferramentas e os recursos expostos.
8. Desative ferramentas que nao fazem parte da prova.
9. Execute um teste no painel de visualizacao.
10. Registre ferramenta chamada, argumentos, retorno e eventuais bloqueios DLP.
11. Publique somente se o criterio da prova exigir publicacao.

REVERSAO

- Remova o conector do agente de teste.
- Reverta a classificacao DLP somente mediante aprovacao.
- Exclua o conector somente mediante aprovacao e evidencia anterior.
- Registre data, executor, justificativa e resultado da reversao.
'@

    Write-Utf8Text -Path $Paths.ManualGuide -Content $Guide
}

function Write-RunSummary {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][string]$QualityGate,
        [AllowNull()][string]$ErrorMessage
    )

    $SummaryRows = @()
    $SummaryRows += [PSCustomObject]@{
        DataInicio      = $Script:StartTime
        DataFim         = Get-Date
        AutomationId    = $Script:AutomationId
        AutomationName  = $Script:AutomationName
        Tenant          = $TenantId
        Conta           = $AdminUPN
        Ambiente        = $EnvironmentId
        Acao            = $Acao
        QualityGate     = $QualityGate
        Erro            = $ErrorMessage
        PastaEvidencias = $Paths.Folder
    }

    Export-Utf8Csv -Path $Paths.Summary -InputObject $SummaryRows
}

Assert-GuidValue -Value $TenantId -ParameterName 'TenantId'
Assert-GuidValue -Value $EnvironmentId -ParameterName 'EnvironmentId'
Assert-UpnValue -Value $AdminUPN -ParameterName 'AdminUPN'

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Execute este script no Windows PowerShell 5.1 Desktop.'
}

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$EvidenceFolder = Join-Path -Path $EvidenceRoot -ChildPath $Timestamp
New-DirectoryIfMissing -Path $EvidenceFolder

$Paths = @{
    Folder              = $EvidenceFolder
    Transcript          = Join-Path $EvidenceFolder 'execucao.log'
    Context             = Join-Path $EvidenceFolder 'contexto.csv'
    Summary             = Join-Path $EvidenceFolder 'resumo.csv'
    Modules             = Join-Path $EvidenceFolder 'modulos-comandos.csv'
    GraphContext        = Join-Path $EvidenceFolder 'sessao-graph.csv'
    AdminRoles          = Join-Path $EvidenceFolder 'funcoes-administrativas.csv'
    TenantLicenses      = Join-Path $EvidenceFolder 'licencas-tenant.csv'
    UserLicenses        = Join-Path $EvidenceFolder 'licencas-conta.csv'
    PacHelp             = Join-Path $EvidenceFolder 'pac-help.txt'
    PacAuthList         = Join-Path $EvidenceFolder 'pac-auth-list.txt'
    PacAuthWho          = Join-Path $EvidenceFolder 'pac-auth-who.txt'
    PacEnvWho           = Join-Path $EvidenceFolder 'pac-env-who.txt'
    ConnectorsBefore    = Join-Path $EvidenceFolder 'conectores-antes.txt'
    ConnectorsAfter     = Join-Path $EvidenceFolder 'conectores-depois.txt'
    DlpPolicies         = Join-Path $EvidenceFolder 'politicas-dlp.csv'
    DlpPoliciesRaw      = Join-Path $EvidenceFolder 'politicas-dlp-bruto.json'
    ConfigurationBefore = Join-Path $EvidenceFolder 'configuracao-antes.csv'
    ConfigurationAfter  = Join-Path $EvidenceFolder 'configuracao-depois.csv'
    ActionResult        = Join-Path $EvidenceFolder 'resultado-acao.txt'
    ManualGuide         = Join-Path $EvidenceFolder 'validacao-manual-copilot-studio.txt'
}

try {
    Start-Transcript -Path $Paths.Transcript -Force | Out-Null
    $Script:TranscriptStarted = $true

    Write-Section -Text 'AUTO-12 - MCPs E RECURSOS PARA AGENTES'
    Write-Host ('Acao: {0}' -f $Acao)
    Write-Host ('Tenant: {0}' -f $TenantId)
    Write-Host ('Conta: {0}' -f $AdminUPN)
    Write-Host ('Ambiente: {0}' -f $EnvironmentId)
    Write-Host ('Evidencias: {0}' -f $EvidenceFolder)

    Get-PreflightEvidence -Paths $Paths
    Write-ManualValidationGuide -Paths $Paths

    switch ($Acao) {
        'Validar' {
            Write-Host 'Validacao concluida. Nenhuma alteracao foi solicitada.' -ForegroundColor Green
        }

        'Consultar' {
            Invoke-ConsultAction -Paths $Paths
        }

        'PrepararAcesso' {
            Invoke-PrepareAccessAction -Paths $Paths
        }

        'Criar' {
            Invoke-CreateConnectorAction -Paths $Paths
        }

        'Atualizar' {
            Invoke-UpdateConnectorAction -Paths $Paths
        }

        'ClassificarBusiness' {
            Invoke-DlpClassificationAction -Paths $Paths -GroupName 'hbi'
        }

        'ClassificarNonBusiness' {
            Invoke-DlpClassificationAction -Paths $Paths -GroupName 'lbi'
        }
    }

    $Script:QualityGate = 'Aprovado - acao concluida'
    Write-RunSummary -Paths $Paths -QualityGate $Script:QualityGate -ErrorMessage $null

    Write-Section -Text 'RESULTADO'
    Write-Host $Script:QualityGate -ForegroundColor Green
    Write-Host ('Evidencias: {0}' -f $EvidenceFolder) -ForegroundColor Green
}
catch {
    $Script:QualityGate = 'Reprovado - falha tecnica ou pre-requisito'
    $Script:FinalError = $_.Exception.Message

    try {
        Write-RunSummary -Paths $Paths -QualityGate $Script:QualityGate -ErrorMessage $Script:FinalError
    }
    catch {
        Write-Warning 'Nao foi possivel concluir o arquivo resumo.csv.'
    }

    Write-Host ''
    Write-Host ('Falha: {0}' -f $Script:FinalError) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    throw
}
finally {
    if ($Script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            # Nao substituir o erro principal por falha no encerramento do transcript.
        }
    }
}