<#
# OBJETIVO:
# Validar e operar, de forma controlada, a política de Acesso Condicional
# "MFA Copilot" para os grupos Copilot-Premium e Copilot-Geral.
#
# FERRAMENTA:
# Microsoft Graph PowerShell
# - Microsoft.Graph.Authentication
# - Microsoft.Graph.Identity.SignIns
# - Microsoft.Graph.Groups
# - Microsoft.Graph.Users
#
# PERMISSÃO:
# Consulta:
# - Policy.Read.All
# - Group.Read.All
# - User.Read.All
#
# Alteração:
# - Policy.ReadWrite.ConditionalAccess
#
# LICENÇA:
# - Microsoft Entra ID P1, P2 ou avaliação compatível.
#
# EFEITO:
# - Consultar: nenhuma alteração.
# - Previsualizar: nenhuma alteração.
# - CriarReportOnly: cria a política somente em report-only.
# - Habilitar: muda a política para enabled.
# - Desabilitar: muda a política para disabled.
# - Reverter: exclui somente a política validada pela AUTO-33.
#
# RECURSO-ALVO:
# - Política: MFA Copilot
# - Grupos: Copilot-Premium e Copilot-Geral
# - Recurso: Office365
# - Controle: MFA
#
# PARÂMETROS EDITÁVEIS:
# - Acao
# - TenantIdEsperado
# - ContaEsperada
# - PolicyIdConhecido
# - EmergencyAccessUPNs
# - Justificativa
# - EvidenceRoot
#
# EVIDÊNCIAS:
# - execucao.log
# - contexto.csv
# - grupos-antes.csv
# - politica-antes.csv
# - corpo-proposto.json
# - acoes.csv
# - grupos-depois.csv
# - politica-depois.csv
# - resumo.csv
# - erros.csv, quando aplicável
# - referencia-politica.json
#
# RISCOS:
# - Uma política habilitada pode bloquear autenticações.
# - Uma segunda criação poderia gerar política duplicada.
# - A exclusão remove a política do tenant.
#
# ATENÇÃO:
# - Execute primeiro Consultar.
# - CriarReportOnly nunca habilita a política.
# - O ID retornado pela criação é preservado localmente.
# - O script consulta diretamente pelo ID antes de considerar a política ausente.
# - Um ID conhecido não resolvido bloqueia nova criação.
# - Habilitar exige conta de emergência e frase de risco.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet(
        'Consultar',
        'Previsualizar',
        'CriarReportOnly',
        'Habilitar',
        'Desabilitar',
        'Reverter'
    )]
    [string]$Acao = 'Consultar',

    [Parameter(Mandatory = $false)]
    [string]$TenantIdEsperado =
        'd7935522-6fc7-408d-8633-e4109183c63f',

    [Parameter(Mandatory = $false)]
    [string]$ContaEsperada =
        'admin@m365mcp79922602.onmicrosoft.com',

    [Parameter(Mandatory = $false)]
    [string]$PolicyIdConhecido =
        '89d3e965-33be-4170-9b8e-cf5fefdb8ba9',

    [Parameter(Mandatory = $false)]
    [string[]]$EmergencyAccessUPNs = @(),

    [Parameter(Mandatory = $false)]
    [switch]$ConfirmarAlteracao,

    [Parameter(Mandatory = $false)]
    [string]$ConfirmacaoRisco = '',

    [Parameter(Mandatory = $false)]
    [string]$Justificativa = '',

    [Parameter(Mandatory = $false)]
    [string]$EvidenceRoot = '',

    [Parameter(Mandatory = $false)]
    [ValidateRange(15, 300)]
    [int]$TempoMaximoValidacaoSegundos = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# 1. CONFIGURAÇÃO CONTROLADA
# ============================================================

$AutomationId = 'AUTO-33'
$AutomationName = 'MFA para o Copilot'
$PolicyDisplayName = 'MFA Copilot'
$ExpectedTargetResource = 'Office365'

$ExpectedGroupDisplayNames = @(
    'Copilot-Premium',
    'Copilot-Geral'
)

$ChangeActions = @(
    'CriarReportOnly',
    'Habilitar',
    'Desabilitar',
    'Reverter'
)

$ReadScopes = @(
    'Policy.Read.All',
    'Group.Read.All',
    'User.Read.All'
)

$WriteScopes = @(
    'Policy.Read.All',
    'Policy.ReadWrite.ConditionalAccess',
    'Group.Read.All',
    'User.Read.All'
)

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    throw 'Salve e execute o código como arquivo.ps1.'
}

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = Join-Path `
        -Path $PSScriptRoot `
        -ChildPath 'evidencias'
}

$AutomationEvidenceRoot = Join-Path `
    -Path $EvidenceRoot `
    -ChildPath 'AUTO-33-MFA-Copilot'

$PolicyReferencePath = Join-Path `
    -Path $AutomationEvidenceRoot `
    -ChildPath 'referencia-politica.json'

# ============================================================
# 2. GUARDRAILS
# ============================================================

$ParsedTenantId = [Guid]::Empty

if (
    -not [Guid]::TryParse(
        $TenantIdEsperado,
        [ref]$ParsedTenantId
    )
) {
    throw "TenantIdEsperado inválido: $TenantIdEsperado"
}

if (
    $ContaEsperada -notmatch
    '^[^@\s]+@[^@\s]+\.[^@\s]+$'
) {
    throw "ContaEsperada inválida: $ContaEsperada"
}

if (
    -not [string]::IsNullOrWhiteSpace($PolicyIdConhecido)
) {
    $ParsedPolicyId = [Guid]::Empty

    if (
        -not [Guid]::TryParse(
            $PolicyIdConhecido,
            [ref]$ParsedPolicyId
        )
    ) {
        throw "PolicyIdConhecido inválido: $PolicyIdConhecido"
    }
}

if ($Acao -in $ChangeActions) {
    if (-not $ConfirmarAlteracao) {
        throw (
            "A ação '$Acao' altera o tenant. " +
            'Use -ConfirmarAlteracao.'
        )
    }

    if ([string]::IsNullOrWhiteSpace($Justificativa)) {
        throw (
            "A ação '$Acao' exige -Justificativa."
        )
    }
}

if ($Acao -eq 'Habilitar') {
    if (
        $ConfirmacaoRisco -cne
        'HABILITAR-MFA-COPILOT'
    ) {
        throw @'
Use a confirmação exata:

-ConfirmacaoRisco 'HABILITAR-MFA-COPILOT'
'@
    }

    if ($EmergencyAccessUPNs.Count -eq 0) {
        throw (
            'Habilitação bloqueada: informe uma conta ' +
            'de emergência adicional.'
        )
    }
}

if ($Acao -eq 'Reverter') {
    if (
        $ConfirmacaoRisco -cne
        'REMOVER-MFA-COPILOT'
    ) {
        throw @'
Use a confirmação exata:

-ConfirmacaoRisco 'REMOVER-MFA-COPILOT'
'@
    }
}

# ============================================================
# 3. EVIDÊNCIAS
# ============================================================

$StartedAt = Get-Date
$Timestamp = $StartedAt.ToString('yyyyMMdd-HHmmss')

$EvidenceDirectory = Join-Path `
    -Path $AutomationEvidenceRoot `
    -ChildPath "$Timestamp-$Acao"

New-Item `
    -Path $EvidenceDirectory `
    -ItemType Directory `
    -Force |
    Out-Null

$Paths = [ordered]@{
    Log = Join-Path $EvidenceDirectory 'execucao.log'
    Context = Join-Path $EvidenceDirectory 'contexto.csv'
    GroupsBefore = Join-Path $EvidenceDirectory 'grupos-antes.csv'
    PolicyBefore = Join-Path $EvidenceDirectory 'politica-antes.csv'
    ProposedBody = Join-Path $EvidenceDirectory 'corpo-proposto.json'
    Actions = Join-Path $EvidenceDirectory 'acoes.csv'
    GroupsAfter = Join-Path $EvidenceDirectory 'grupos-depois.csv'
    PolicyAfter = Join-Path $EvidenceDirectory 'politica-depois.csv'
    Summary = Join-Path $EvidenceDirectory 'resumo.csv'
    Errors = Join-Path $EvidenceDirectory 'erros.csv'
}

Start-Transcript `
    -Path $Paths.Log `
    -Force |
    Out-Null

$GraphConnectedByScript = $false
$ExecutionCompleted = $false
$Actions = [System.Collections.Generic.List[object]]::new()

# ============================================================
# 4. FUNÇÕES
# ============================================================

function Add-ActionRecord {
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Detail
    )

    $script:Actions.Add(
        [PSCustomObject]@{
            DataHora = (Get-Date).ToString('o')
            AcaoSolicitada = $script:Acao
            Operacao = $Operation
            Status = $Status
            Detalhe = $Detail
        }
    )
}

function Export-EvidenceCsv {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$InputObject
    )

    if ($InputObject.Count -gt 0) {
        $InputObject |
            Export-Csv `
                -LiteralPath $Path `
                -NoTypeInformation `
                -Encoding utf8
    }
    else {
        Set-Content `
            -LiteralPath $Path `
            -Value '' `
            -Encoding utf8
    }
}

function Save-PolicyReference {
    param(
        [Parameter(Mandatory)]
        [string]$PolicyId
    )

    [ordered]@{
        AutomationId = $script:AutomationId
        DisplayName = $script:PolicyDisplayName
        PolicyId = $PolicyId
        TenantId = $script:TenantIdEsperado
        DataHora = (Get-Date).ToString('o')
    } |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -LiteralPath $script:PolicyReferencePath `
            -Encoding utf8
}

function Get-SavedPolicyId {
    if (
        -not (
            Test-Path `
                -LiteralPath $script:PolicyReferencePath
        )
    ) {
        return $null
    }

    try {
        $Reference = Get-Content `
            -LiteralPath $script:PolicyReferencePath `
            -Raw `
            -Encoding utf8 |
            ConvertFrom-Json

        if (
            $Reference.TenantId -ne
            $script:TenantIdEsperado
        ) {
            throw (
                'A referência local pertence a outro tenant.'
            )
        }

        if (
            $Reference.DisplayName -ne
            $script:PolicyDisplayName
        ) {
            throw (
                'A referência local pertence a outra política.'
            )
        }

        return [string]$Reference.PolicyId
    }
    catch {
        throw (
            'A referência local da política não pôde ser validada. ' +
            $_.Exception.Message
        )
    }
}

function Get-UserStrict {
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName
    )

    try {
        return Get-MgUser `
            -UserId $UserPrincipalName `
            -Property @(
                'id',
                'displayName',
                'userPrincipalName',
                'accountEnabled'
            ) `
            -ErrorAction Stop
    }
    catch {
        throw (
            "Usuário não localizado: $UserPrincipalName. " +
            $_.Exception.Message
        )
    }
}

function Get-Auto33Groups {
    $Results = @()

    foreach (
        $GroupName in
        $script:ExpectedGroupDisplayNames
    ) {
        $EscapedName = $GroupName.Replace(
            "'",
            "''"
        )

        try {
            $Matches = @(
                Get-MgGroup `
                    -Filter "displayName eq '$EscapedName'" `
                    -Property @(
                        'id',
                        'displayName',
                        'description',
                        'groupTypes',
                        'mail',
                        'mailEnabled',
                        'securityEnabled',
                        'membershipRule',
                        'membershipRuleProcessingState',
                        'createdDateTime'
                    ) `
                    -All `
                    -ErrorAction Stop
            )
        }
        catch {
            throw (
                "Falha ao consultar '$GroupName'. " +
                $_.Exception.Message
            )
        }

        if ($Matches.Count -eq 0) {
            $Results += [PSCustomObject]@{
                NomeConsultado = $GroupName
                StatusConsulta = 'Não encontrado'
                ConsultaConcluida = $true
                QuantidadeCorrespondencias = 0
                CorrespondenciaUnica = $false
                Id = $null
                DisplayName = $null
                Description = $null
                GroupTypes = $null
                Mail = $null
                MailEnabled = $null
                SecurityEnabled = $null
                MembershipRule = $null
                MembershipRuleProcessingState = $null
                CreatedDateTime = $null
                Observacao = 'Ausência confirmada.'
            }

            continue
        }

        foreach ($Group in $Matches) {
            $Results += [PSCustomObject]@{
                NomeConsultado = $GroupName
                StatusConsulta = if (
                    $Matches.Count -eq 1
                ) {
                    'Encontrado único'
                }
                else {
                    'Duplicidade'
                }
                ConsultaConcluida = $true
                QuantidadeCorrespondencias = $Matches.Count
                CorrespondenciaUnica = (
                    $Matches.Count -eq 1
                )
                Id = [string]$Group.Id
                DisplayName = [string]$Group.DisplayName
                Description = [string]$Group.Description
                GroupTypes = (
                    @($Group.GroupTypes) -join '; '
                )
                Mail = [string]$Group.Mail
                MailEnabled = $Group.MailEnabled
                SecurityEnabled = $Group.SecurityEnabled
                MembershipRule = [string]$Group.MembershipRule
                MembershipRuleProcessingState = (
                    [string]$Group.MembershipRuleProcessingState
                )
                CreatedDateTime = $Group.CreatedDateTime
                Observacao = if (
                    $Matches.Count -eq 1
                ) {
                    'Objeto identificado sem alterações.'
                }
                else {
                    'Alterações bloqueadas por duplicidade.'
                }
            }
        }
    }

    return @($Results)
}

function Get-PoliciesByName {
    try {
        return @(
            Get-MgIdentityConditionalAccessPolicy `
                -All `
                -ErrorAction Stop |
                Where-Object {
                    $_.DisplayName -eq
                    $script:PolicyDisplayName
                }
        )
    }
    catch {
        throw (
            'Falha ao listar políticas. ' +
            $_.Exception.Message
        )
    }
}

function Get-PolicyByIdSafe {
    param(
        [Parameter(Mandatory)]
        [string]$PolicyId
    )

    try {
        $Policy =
            Get-MgIdentityConditionalAccessPolicy `
                -ConditionalAccessPolicyId $PolicyId `
                -ErrorAction Stop

        if (
            $Policy.DisplayName -ne
            $script:PolicyDisplayName
        ) {
            throw (
                "O ID $PolicyId pertence à política " +
                "'$($Policy.DisplayName)', não à política " +
                "'$($script:PolicyDisplayName)'."
            )
        }

        return $Policy
    }
    catch {
        return $null
    }
}

function Resolve-Auto33Policies {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$PreferredPolicyId
    )

    $ByName = @(Get-PoliciesByName)

    if ($ByName.Count -gt 0) {
        return @($ByName)
    }

    if (
        -not [string]::IsNullOrWhiteSpace(
            $PreferredPolicyId
        )
    ) {
        $ById = Get-PolicyByIdSafe `
            -PolicyId $PreferredPolicyId

        if ($null -ne $ById) {
            return @($ById)
        }
    }

    return @()
}

function Wait-Auto33Policy {
    param(
        [Parameter(Mandatory)]
        [bool]$ShouldExist,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$PreferredPolicyId,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$ExpectedState,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $Deadline = (Get-Date).AddSeconds(
        $TimeoutSeconds
    )

    do {
        $Policies = @(
            Resolve-Auto33Policies `
                -PreferredPolicyId $PreferredPolicyId
        )

        if (-not $ShouldExist) {
            if ($Policies.Count -eq 0) {
                return @()
            }
        }
        elseif ($Policies.Count -eq 1) {
            if (
                [string]::IsNullOrWhiteSpace(
                    $ExpectedState
                ) -or
                [string]$Policies[0].State -eq
                $ExpectedState
            ) {
                return @($Policies)
            }
        }

        Start-Sleep -Seconds 5
    }
    while ((Get-Date) -lt $Deadline)

    return @(
        Resolve-Auto33Policies `
            -PreferredPolicyId $PreferredPolicyId
    )
}

function Convert-PolicyToEvidence {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Policies
    )

    if ($Policies.Count -eq 0) {
        return @(
            [PSCustomObject]@{
                StatusConsulta = 'Não encontrada'
                ConsultaConcluida = $true
                QuantidadeCorrespondencias = 0
                PolicyId = $null
                DisplayName = $script:PolicyDisplayName
                State = $null
                CreatedDateTime = $null
                ModifiedDateTime = $null
                IncludeGroups = $null
                ExcludeGroups = $null
                IncludeUsers = $null
                ExcludeUsers = $null
                IncludeApplications = $null
                ExcludeApplications = $null
                ClientAppTypes = $null
                GrantOperator = $null
                BuiltInControls = $null
                Observacao = 'Ausência confirmada.'
            }
        )
    }

    $Results = @()

    foreach ($Policy in $Policies) {
        $Results += [PSCustomObject]@{
            StatusConsulta = if (
                $Policies.Count -eq 1
            ) {
                'Encontrada única'
            }
            else {
                'Duplicidade'
            }
            ConsultaConcluida = $true
            QuantidadeCorrespondencias = (
                $Policies.Count
            )
            PolicyId = [string]$Policy.Id
            DisplayName = [string]$Policy.DisplayName
            State = [string]$Policy.State
            CreatedDateTime = $Policy.CreatedDateTime
            ModifiedDateTime = $Policy.ModifiedDateTime
            IncludeGroups = (
                @(
                    $Policy.Conditions.Users.IncludeGroups |
                        ForEach-Object { [string]$_ }
                ) -join '; '
            )
            ExcludeGroups = (
                @(
                    $Policy.Conditions.Users.ExcludeGroups |
                        ForEach-Object { [string]$_ }
                ) -join '; '
            )
            IncludeUsers = (
                @(
                    $Policy.Conditions.Users.IncludeUsers |
                        ForEach-Object { [string]$_ }
                ) -join '; '
            )
            ExcludeUsers = (
                @(
                    $Policy.Conditions.Users.ExcludeUsers |
                        ForEach-Object { [string]$_ }
                ) -join '; '
            )
            IncludeApplications = (
                @(
                    $Policy.Conditions.Applications.
                        IncludeApplications |
                        ForEach-Object { [string]$_ }
                ) -join '; '
            )
            ExcludeApplications = (
                @(
                    $Policy.Conditions.Applications.
                        ExcludeApplications |
                        ForEach-Object { [string]$_ }
                ) -join '; '
            )
            ClientAppTypes = (
                @(
                    $Policy.Conditions.ClientAppTypes |
                        ForEach-Object { [string]$_ }
                ) -join '; '
            )
            GrantOperator = (
                [string]$Policy.GrantControls.Operator
            )
            BuiltInControls = (
                @(
                    $Policy.GrantControls.BuiltInControls |
                        ForEach-Object { [string]$_ }
                ) -join '; '
            )
            Observacao = if (
                $Policies.Count -eq 1
            ) {
                'Política identificada.'
            }
            else {
                'Alterações bloqueadas por duplicidade.'
            }
        }
    }

    return @($Results)
}

function Test-Auto33Policy {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Policy,

        [Parameter(Mandatory)]
        [string[]]$ExpectedGroupIds,

        [Parameter(Mandatory)]
        [string[]]$RequiredExcludedUserIds
    )

    if ($null -eq $Policy) {
        return [PSCustomObject]@{
            Exists = $false
            RequiresMfa = $false
            TargetsOffice365 = $false
            CoversAllClientApps = $false
            IncludesAllExpectedGroups = $false
            IncludesOnlyExpectedGroups = $false
            ExcludesRequiredUsers = $false
            CoreConfigurationValid = $false
            State = $null
        }
    }

    $IncludeGroups = @(
        $Policy.Conditions.Users.IncludeGroups |
            ForEach-Object { [string]$_ }
    )

    $ExcludeUsers = @(
        $Policy.Conditions.Users.ExcludeUsers |
            ForEach-Object { [string]$_ }
    )

    $IncludeApplications = @(
        $Policy.Conditions.Applications.
            IncludeApplications |
            ForEach-Object { [string]$_ }
    )

    $ClientAppTypes = @(
        $Policy.Conditions.ClientAppTypes |
            ForEach-Object { [string]$_ }
    )

    $BuiltInControls = @(
        $Policy.GrantControls.BuiltInControls |
            ForEach-Object { [string]$_ }
    )

    $MissingGroups = @(
        $ExpectedGroupIds |
            Where-Object {
                $_ -notin $IncludeGroups
            }
    )

    $UnexpectedGroups = @(
        $IncludeGroups |
            Where-Object {
                $_ -notin $ExpectedGroupIds
            }
    )

    $MissingExclusions = @(
        $RequiredExcludedUserIds |
            Where-Object {
                $_ -notin $ExcludeUsers
            }
    )

    $RequiresMfa = (
        $BuiltInControls -contains 'mfa'
    )

    $TargetsOffice365 = (
        $IncludeApplications -contains
        $script:ExpectedTargetResource
    )

    $CoversAllClientApps = (
        $ClientAppTypes -contains 'all'
    )

    $IncludesAllExpectedGroups = (
        $MissingGroups.Count -eq 0
    )

    $IncludesOnlyExpectedGroups = (
        $IncludesAllExpectedGroups -and
        $UnexpectedGroups.Count -eq 0
    )

    $ExcludesRequiredUsers = (
        $MissingExclusions.Count -eq 0
    )

    return [PSCustomObject]@{
        Exists = $true
        RequiresMfa = $RequiresMfa
        TargetsOffice365 = $TargetsOffice365
        CoversAllClientApps = $CoversAllClientApps
        IncludesAllExpectedGroups = (
            $IncludesAllExpectedGroups
        )
        IncludesOnlyExpectedGroups = (
            $IncludesOnlyExpectedGroups
        )
        ExcludesRequiredUsers = (
            $ExcludesRequiredUsers
        )
        CoreConfigurationValid = (
            $RequiresMfa -and
            $TargetsOffice365 -and
            $CoversAllClientApps -and
            $IncludesAllExpectedGroups -and
            $IncludesOnlyExpectedGroups -and
            $ExcludesRequiredUsers
        )
        State = [string]$Policy.State
    }
}

# ============================================================
# 5. EXECUÇÃO
# ============================================================

try {
    Write-Host ''
    Write-Host '============================================================'
    Write-Host " $AutomationId - $AutomationName"
    Write-Host " Ação: $Acao"
    Write-Host '============================================================'
    Write-Host ''

    if (
        $PSVersionTable.PSEdition -ne 'Core' -or
        $PSVersionTable.PSVersion.Major -lt 7
    ) {
        throw 'Execute no PowerShell 7.'
    }

    $RequiredCommands = @(
        'Connect-MgGraph',
        'Disconnect-MgGraph',
        'Get-MgContext',
        'Get-MgGroup',
        'Get-MgUser',
        'Get-MgIdentityConditionalAccessPolicy'
    )

    if ($Acao -in $ChangeActions) {
        $RequiredCommands += @(
            'New-MgIdentityConditionalAccessPolicy',
            'Update-MgIdentityConditionalAccessPolicy',
            'Remove-MgIdentityConditionalAccessPolicy'
        )
    }

    $MissingCommands = @(
        foreach ($CommandName in $RequiredCommands) {
            if (
                $null -eq (
                    Get-Command `
                        -Name $CommandName `
                        -ErrorAction SilentlyContinue
                )
            ) {
                $CommandName
            }
        }
    )

    if ($MissingCommands.Count -gt 0) {
        throw (
            'Comandos ausentes: ' +
            ($MissingCommands -join ', ')
        )
    }

    $ExistingContext = Get-MgContext `
        -ErrorAction SilentlyContinue

    if ($null -ne $ExistingContext) {
        Disconnect-MgGraph `
            -ErrorAction SilentlyContinue |
            Out-Null
    }

    $RequestedScopes = if (
        $Acao -in $ChangeActions
    ) {
        $WriteScopes
    }
    else {
        $ReadScopes
    }

    Connect-MgGraph `
        -TenantId $TenantIdEsperado `
        -Scopes $RequestedScopes `
        -ContextScope Process `
        -UseDeviceCode `
        -NoWelcome `
        -ErrorAction Stop

    $GraphConnectedByScript = $true
    $GraphContext = Get-MgContext -ErrorAction Stop

    if (
        $GraphContext.TenantId -ne
        $TenantIdEsperado
    ) {
        throw 'Tenant autenticado diferente do esperado.'
    }

    if (
        -not [string]::Equals(
            [string]$GraphContext.Account,
            [string]$ContaEsperada,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'Conta autenticada diferente da esperada.'
    }

    $ActiveScopes = @($GraphContext.Scopes)

    $MissingScopes = @(
        $RequestedScopes |
            Where-Object {
                $_ -notin $ActiveScopes
            }
    )

    if ($MissingScopes.Count -gt 0) {
        throw (
            'Escopos ausentes: ' +
            ($MissingScopes -join ', ')
        )
    }

    $AdminUser = Get-UserStrict `
        -UserPrincipalName $ContaEsperada

    $EmergencyUsers = @()

    foreach ($EmergencyUPN in $EmergencyAccessUPNs) {
        if (
            [string]::Equals(
                $EmergencyUPN,
                $ContaEsperada,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw (
                'A conta de emergência deve ser diferente ' +
                'da conta administrativa principal.'
            )
        }

        $EmergencyUsers += Get-UserStrict `
            -UserPrincipalName $EmergencyUPN
    }

    $RequiredExcludedUserIds = @(
        [string]$AdminUser.Id
    )

    $RequiredExcludedUserIds += @(
        $EmergencyUsers |
            ForEach-Object {
                [string]$_.Id
            }
    )

    $RequiredExcludedUserIds = @(
        $RequiredExcludedUserIds |
            Select-Object -Unique
    )

    $SavedPolicyId = Get-SavedPolicyId

    $EffectivePolicyId = if (
        -not [string]::IsNullOrWhiteSpace(
            $PolicyIdConhecido
        )
    ) {
        $PolicyIdConhecido
    }
    elseif (
        -not [string]::IsNullOrWhiteSpace(
            $SavedPolicyId
        )
    ) {
        $SavedPolicyId
    }
    else {
        $null
    }

    [PSCustomObject]@{
        AutomationId = $AutomationId
        DataInicio = $StartedAt.ToString('o')
        Acao = $Acao
        TenantIdEsperado = $TenantIdEsperado
        TenantIdAutenticado = $GraphContext.TenantId
        ContaEsperada = $ContaEsperada
        ContaAutenticada = $GraphContext.Account
        ContaAdministrativaId = $AdminUser.Id
        ContasEmergencia = (
            $EmergencyAccessUPNs -join '; '
        )
        ContasExcluidasIds = (
            $RequiredExcludedUserIds -join '; '
        )
        PolicyIdParametro = $PolicyIdConhecido
        PolicyIdReferenciaLocal = $SavedPolicyId
        PolicyIdEfetivo = $EffectivePolicyId
        EscoposSolicitados = (
            $RequestedScopes -join '; '
        )
        EscoposAtivos = (
            $ActiveScopes -join '; '
        )
        ConfirmarAlteracao = [bool]$ConfirmarAlteracao
        Justificativa = $Justificativa
        PastaEvidencias = $EvidenceDirectory
    } |
        Export-Csv `
            -LiteralPath $Paths.Context `
            -NoTypeInformation `
            -Encoding utf8

    # ========================================================
    # 6. BASELINE
    # ========================================================

    $GroupsBefore = @(Get-Auto33Groups)

    $PoliciesBefore = @(
        Resolve-Auto33Policies `
            -PreferredPolicyId $EffectivePolicyId
    )

    Export-EvidenceCsv `
        -Path $Paths.GroupsBefore `
        -InputObject $GroupsBefore

    Export-EvidenceCsv `
        -Path $Paths.PolicyBefore `
        -InputObject @(
            Convert-PolicyToEvidence `
                -Policies $PoliciesBefore
        )

    $UniqueGroups = @(
        $GroupsBefore |
            Where-Object CorrespondenciaUnica -eq $true
    )

    if (
        $UniqueGroups.Count -ne
        $ExpectedGroupDisplayNames.Count
    ) {
        throw (
            'Os grupos esperados não foram encontrados ' +
            'de forma única.'
        )
    }

    $ExpectedGroupIds = @(
        foreach (
            $ExpectedName in
            $ExpectedGroupDisplayNames
        ) {
            $Match = @(
                $UniqueGroups |
                    Where-Object {
                        $_.NomeConsultado -eq
                        $ExpectedName
                    }
            )

            if ($Match.Count -ne 1) {
                throw (
                    "Grupo não resolvido: $ExpectedName"
                )
            }

            [string]$Match[0].Id
        }
    )

    if ($PoliciesBefore.Count -gt 1) {
        throw 'Foram encontradas políticas duplicadas.'
    }

    $PolicyBefore = if (
        $PoliciesBefore.Count -eq 1
    ) {
        $PoliciesBefore[0]
    }
    else {
        $null
    }

    if ($null -ne $PolicyBefore) {
        $EffectivePolicyId = [string]$PolicyBefore.Id

        Save-PolicyReference `
            -PolicyId $EffectivePolicyId
    }

    $BeforeAssessment = Test-Auto33Policy `
        -Policy $PolicyBefore `
        -ExpectedGroupIds $ExpectedGroupIds `
        -RequiredExcludedUserIds $RequiredExcludedUserIds

    # ========================================================
    # 7. CORPO PROPOSTO
    # ========================================================

    $ConditionalAccessBody = @{
        DisplayName = $PolicyDisplayName

        State = 'enabledForReportingButNotEnforced'

        Conditions = @{
            Users = @{
                IncludeGroups = @($ExpectedGroupIds)
                ExcludeUsers = @(
                    $RequiredExcludedUserIds
                )
            }

            Applications = @{
                IncludeApplications = @(
                    $ExpectedTargetResource
                )
            }

            ClientAppTypes = @('all')
        }

        GrantControls = @{
            Operator = 'OR'
            BuiltInControls = @('mfa')
        }
    }

    $ConditionalAccessBody |
        ConvertTo-Json -Depth 20 |
        Set-Content `
            -LiteralPath $Paths.ProposedBody `
            -Encoding utf8

    # ========================================================
    # 8. AÇÃO
    # ========================================================

    $ExpectedAfterState = $null
    $ShouldExistAfter = $true

    switch ($Acao) {
        'Consultar' {
            Add-ActionRecord `
                -Operation 'Consultar' `
                -Status 'Sucesso' `
                -Detail 'Consulta concluída.'

            $ShouldExistAfter = (
                $PoliciesBefore.Count -eq 1
            )

            $ExpectedAfterState = $BeforeAssessment.State
        }

        'Previsualizar' {
            Add-ActionRecord `
                -Operation 'Previsualizar' `
                -Status 'Sucesso' `
                -Detail (
                    'Corpo proposto gerado sem alteração.'
                )

            $ShouldExistAfter = (
                $PoliciesBefore.Count -eq 1
            )

            $ExpectedAfterState = $BeforeAssessment.State
        }

        'CriarReportOnly' {
            if ($null -eq $PolicyBefore) {
                if (
                    -not [string]::IsNullOrWhiteSpace(
                        $EffectivePolicyId
                    )
                ) {
                    throw @"
Existe um ID conhecido para a política, mas ele ainda não pôde ser resolvido:

$EffectivePolicyId

Nova criação bloqueada para evitar duplicidade.
Execute Consultar novamente.
"@
                }

                $CreatedPolicy =
                    New-MgIdentityConditionalAccessPolicy `
                        -BodyParameter $ConditionalAccessBody `
                        -ErrorAction Stop

                $EffectivePolicyId = [string]$CreatedPolicy.Id

                Save-PolicyReference `
                    -PolicyId $EffectivePolicyId

                Add-ActionRecord `
                    -Operation 'CriarReportOnly' `
                    -Status 'Sucesso' `
                    -Detail (
                        'Política criada em report-only. ' +
                        "Id=$EffectivePolicyId"
                    )
            }
            elseif (
                $BeforeAssessment.CoreConfigurationValid -and
                $BeforeAssessment.State -eq
                'enabledForReportingButNotEnforced'
            ) {
                Add-ActionRecord `
                    -Operation 'CriarReportOnly' `
                    -Status 'Ignorado' `
                    -Detail (
                        'Política já existente e válida. ' +
                        'Idempotência confirmada.'
                    )
            }
            else {
                throw (
                    'A política existe, mas diverge do ' +
                    'desenho esperado.'
                )
            }

            $ShouldExistAfter = $true
            $ExpectedAfterState =
                'enabledForReportingButNotEnforced'
        }

        'Habilitar' {
            if ($null -eq $PolicyBefore) {
                throw 'A política não existe.'
            }

            if (-not $BeforeAssessment.CoreConfigurationValid) {
                throw 'A configuração da política é inválida.'
            }

            if ($BeforeAssessment.State -eq 'enabled') {
                Add-ActionRecord `
                    -Operation 'Habilitar' `
                    -Status 'Ignorado' `
                    -Detail 'Política já habilitada.'
            }
            else {
                Update-MgIdentityConditionalAccessPolicy `
                    -ConditionalAccessPolicyId $PolicyBefore.Id `
                    -BodyParameter @{
                        State = 'enabled'
                    } `
                    -ErrorAction Stop

                Add-ActionRecord `
                    -Operation 'Habilitar' `
                    -Status 'Sucesso' `
                    -Detail 'State=enabled.'
            }

            $EffectivePolicyId = [string]$PolicyBefore.Id
            $ShouldExistAfter = $true
            $ExpectedAfterState = 'enabled'
        }

        'Desabilitar' {
            if ($null -eq $PolicyBefore) {
                throw 'A política não existe.'
            }

            if ($BeforeAssessment.State -eq 'disabled') {
                Add-ActionRecord `
                    -Operation 'Desabilitar' `
                    -Status 'Ignorado' `
                    -Detail 'Política já desabilitada.'
            }
            else {
                Update-MgIdentityConditionalAccessPolicy `
                    -ConditionalAccessPolicyId $PolicyBefore.Id `
                    -BodyParameter @{
                        State = 'disabled'
                    } `
                    -ErrorAction Stop

                Add-ActionRecord `
                    -Operation 'Desabilitar' `
                    -Status 'Sucesso' `
                    -Detail 'State=disabled.'
            }

            $EffectivePolicyId = [string]$PolicyBefore.Id
            $ShouldExistAfter = $true
            $ExpectedAfterState = 'disabled'
        }

        'Reverter' {
            if ($null -eq $PolicyBefore) {
                Add-ActionRecord `
                    -Operation 'Reverter' `
                    -Status 'Ignorado' `
                    -Detail 'Política já ausente.'
            }
            else {
                if (
                    -not $BeforeAssessment.
                        CoreConfigurationValid
                ) {
                    throw (
                        'Exclusão bloqueada: a política não ' +
                        'corresponde ao desenho AUTO-33.'
                    )
                }

                Remove-MgIdentityConditionalAccessPolicy `
                    -ConditionalAccessPolicyId $PolicyBefore.Id `
                    -Confirm:$false `
                    -ErrorAction Stop

                Add-ActionRecord `
                    -Operation 'Reverter' `
                    -Status 'Sucesso' `
                    -Detail 'Política removida.'
            }

            $ShouldExistAfter = $false
            $ExpectedAfterState = $null
        }
    }

    # ========================================================
    # 9. VALIDAÇÃO POSTERIOR COM RETENTATIVAS
    # ========================================================

    Write-Host ''
    Write-Host (
        'Validando o estado posterior por até ' +
        "$TempoMaximoValidacaoSegundos segundos..."
    )

    $PoliciesAfter = @(
        Wait-Auto33Policy `
            -ShouldExist $ShouldExistAfter `
            -PreferredPolicyId $EffectivePolicyId `
            -ExpectedState $ExpectedAfterState `
            -TimeoutSeconds $TempoMaximoValidacaoSegundos
    )

    $GroupsAfter = @(Get-Auto33Groups)

    Export-EvidenceCsv `
        -Path $Paths.GroupsAfter `
        -InputObject $GroupsAfter

    Export-EvidenceCsv `
        -Path $Paths.PolicyAfter `
        -InputObject @(
            Convert-PolicyToEvidence `
                -Policies $PoliciesAfter
        )

    Export-EvidenceCsv `
        -Path $Paths.Actions `
        -InputObject @($Actions)

    if ($PoliciesAfter.Count -gt 1) {
        throw (
            'A validação posterior encontrou duplicidade.'
        )
    }

    $PolicyAfter = if (
        $PoliciesAfter.Count -eq 1
    ) {
        $PoliciesAfter[0]
    }
    else {
        $null
    }

    $AfterAssessment = Test-Auto33Policy `
        -Policy $PolicyAfter `
        -ExpectedGroupIds $ExpectedGroupIds `
        -RequiredExcludedUserIds $RequiredExcludedUserIds

    $ValidationApproved = switch ($Acao) {
        'Consultar' {
            if ($ShouldExistAfter) {
                $PoliciesAfter.Count -eq 1
            }
            else {
                $PoliciesAfter.Count -eq 0
            }
        }

        'Previsualizar' {
            Test-Path `
                -LiteralPath $Paths.ProposedBody
        }

        'CriarReportOnly' {
            (
                $PoliciesAfter.Count -eq 1 -and
                $AfterAssessment.CoreConfigurationValid -and
                $AfterAssessment.State -eq
                'enabledForReportingButNotEnforced'
            )
        }

        'Habilitar' {
            (
                $PoliciesAfter.Count -eq 1 -and
                $AfterAssessment.CoreConfigurationValid -and
                $AfterAssessment.State -eq 'enabled'
            )
        }

        'Desabilitar' {
            (
                $PoliciesAfter.Count -eq 1 -and
                $AfterAssessment.State -eq 'disabled'
            )
        }

        'Reverter' {
            $PoliciesAfter.Count -eq 0
        }
    }

    $ChangeExecuted = @(
        $Actions |
            Where-Object Status -eq 'Sucesso' |
            Where-Object {
                $_.Operacao -in $ChangeActions
            }
    ).Count -gt 0

    if (
        $Acao -eq 'Reverter' -and
        $ValidationApproved -and
        (
            Test-Path `
                -LiteralPath $PolicyReferencePath
        )
    ) {
        Remove-Item `
            -LiteralPath $PolicyReferencePath `
            -Force
    }

    $Summary = [PSCustomObject]@{
        AutomationId = $AutomationId
        AutomationName = $AutomationName
        DataInicio = $StartedAt.ToString('o')
        DataFim = (Get-Date).ToString('o')
        Tenant = $TenantIdEsperado
        Conta = $ContaEsperada
        Acao = $Acao
        Justificativa = $Justificativa
        PolicyIdEfetivo = $EffectivePolicyId
        GruposUnicosAntes = $true
        PolicyCountBefore = $PoliciesBefore.Count
        PolicyStateBefore = $BeforeAssessment.State
        PolicyCountAfter = $PoliciesAfter.Count
        PolicyStateAfter = $AfterAssessment.State
        CoreConfigurationValidAfter = (
            $AfterAssessment.CoreConfigurationValid
        )
        RequiresMfaAfter = (
            $AfterAssessment.RequiresMfa
        )
        TargetsOffice365After = (
            $AfterAssessment.TargetsOffice365
        )
        CoversAllClientAppsAfter = (
            $AfterAssessment.CoversAllClientApps
        )
        IncludesAllExpectedGroupsAfter = (
            $AfterAssessment.IncludesAllExpectedGroups
        )
        IncludesOnlyExpectedGroupsAfter = (
            $AfterAssessment.IncludesOnlyExpectedGroups
        )
        ExcludesRequiredUsersAfter = (
            $AfterAssessment.ExcludesRequiredUsers
        )
        AlteracaoExecutada = $ChangeExecuted
        ValidacaoAprovada = $ValidationApproved
        QualityGate = if ($ValidationApproved) {
            'Aprovado'
        }
        else {
            'Reprovado'
        }
        TempoMaximoValidacaoSegundos = (
            $TempoMaximoValidacaoSegundos
        )
        PastaEvidencias = $EvidenceDirectory
    }

    $Summary |
        Export-Csv `
            -LiteralPath $Paths.Summary `
            -NoTypeInformation `
            -Encoding utf8

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' RESULTADO DA AUTO-33'
    Write-Host '============================================================'
    Write-Host "Ação: $Acao"
    Write-Host "Policy ID: $EffectivePolicyId"
    Write-Host "Políticas antes: $($PoliciesBefore.Count)"
    Write-Host "Estado antes: $($BeforeAssessment.State)"
    Write-Host "Políticas depois: $($PoliciesAfter.Count)"
    Write-Host "Estado depois: $($AfterAssessment.State)"
    Write-Host "Alteração executada: $ChangeExecuted"
    Write-Host "Validação aprovada: $ValidationApproved"
    Write-Host "Quality Gate: $($Summary.QualityGate)"
    Write-Host "Evidências: $EvidenceDirectory"
    Write-Host '============================================================'

    if (-not $ValidationApproved) {
        throw (
            'O estado posterior não corresponde ao ' +
            'resultado esperado.'
        )
    }

    $ExecutionCompleted = $true
}
catch {
    [PSCustomObject]@{
        AutomationId = $AutomationId
        DataHora = (Get-Date).ToString('o')
        Acao = $Acao
        Mensagem = $_.Exception.Message
        Linha = $_.InvocationInfo.ScriptLineNumber
        Posicao = $_.InvocationInfo.PositionMessage
        AlteracaoExecutada = @(
            $Actions |
                Where-Object Status -eq 'Sucesso' |
                Where-Object {
                    $_.Operacao -in $ChangeActions
                }
        ).Count -gt 0
        PastaEvidencias = $EvidenceDirectory
    } |
        Export-Csv `
            -LiteralPath $Paths.Errors `
            -NoTypeInformation `
            -Encoding utf8

    Export-EvidenceCsv `
        -Path $Paths.Actions `
        -InputObject @($Actions)

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' EXECUÇÃO INTERROMPIDA'
    Write-Host '============================================================'
    Write-Host $_.Exception.Message `
        -ForegroundColor Red
    Write-Host "Evidências: $EvidenceDirectory"
    Write-Host '============================================================'

    throw
}
finally {
    if ($GraphConnectedByScript) {
        Disconnect-MgGraph `
            -ErrorAction SilentlyContinue |
            Out-Null
    }

    try {
        Stop-Transcript |
            Out-Null
    }
    catch {
        # O transcript pode não ter iniciado.
    }

    if (-not $ExecutionCompleted) {
        Write-Host ''
        Write-Host (
            'A AUTO-33 não terminou com o quality gate aprovado.'
        ) -ForegroundColor Yellow
    }
}