# OBJETIVO:
# Validar e operar, de forma controlada, os grupos Copilot-Premium e
# Copilot-Geral no tenant de laboratório.
# FERRAMENTA:
# Microsoft Graph PowerShell SDK.
# PERMISSÃO:
# Consulta: Group.Read.All, User.Read.All, Organization.Read.All e
# RoleManagement.Read.Directory.
# Criação: Group.ReadWrite.All.
# Associação ou remoção de membro: GroupMember.ReadWrite.All.
# LICENÇA:
# A criação e a associação aos grupos não atribuem licença automaticamente.
# Este código apenas inventaria as licenças do tenant e as licenças já
# atribuídas aos grupos. Não atribui nem remove SKU.
# EFEITO:
# Consulta grupos, owners, membros, funções e licenças. Mediante confirmação,
# cria grupos e adiciona ou remove um usuário de teste.
# RECURSO-ALVO:
# Grupos de segurança cloud-only Copilot-Premium e Copilot-Geral.
# PARÂMETROS EDITÁVEIS:
# Acao, GrupoAlvo, UsuarioTesteUPN, TenantIdEsperado, ContaEsperada e
# ConfirmarAlteracao.
# EVIDÊNCIAS:
# evidencias\AUTO-22-Grupos-Premium-Geral\<timestamp>.
# RISCOS:
# Adicionar um usuário a um grupo que já tenha políticas, acessos ou licenças
# atribuídos pode conceder serviços ou permissões ao usuário.
# ATENÇÃO:
# Alterações exigem -ConfirmarAlteracao. O script não exclui grupos e não
# atribui ou remove licenças. Use somente objetos do tenant de laboratório.

[CmdletBinding()]
param(
    [ValidateSet('Consultar', 'CriarGrupos', 'AdicionarMembro', 'RemoverMembro')]
    [string]$Acao = 'Consultar',

    [ValidateSet('Copilot-Premium', 'Copilot-Geral', 'Ambos')]
    [string]$GrupoAlvo = 'Ambos',

    [string]$UsuarioTesteUPN = '',

    [string]$TenantIdEsperado = 'd7935522-6fc7-408d-8633-e4109183c63f',

    [string]$ContaEsperada = 'admin@m365mcp79922602.onmicrosoft.com',

    [switch]$ConfirmarAlteracao
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AutomationId = 'AUTO-22'
$AutomationName = 'Grupos Premium e geral'
$ExecutionStarted = Get-Date
$Timestamp = $ExecutionStarted.ToString('yyyyMMdd-HHmmss')
$IsMutation = $Acao -ne 'Consultar'
$GraphConnectedByScript = $false
$ChangesExecuted = $false
$ActionEvidence = [System.Collections.Generic.List[object]]::new()
$ErrorEvidence = [System.Collections.Generic.List[object]]::new()

$Definitions = @(
    [pscustomobject]@{
        DisplayName  = 'Copilot-Premium'
        MailNickname = 'copilotpremium'
        Description  = 'Grupo de segurança do laboratório para usuários do escopo Copilot Premium.'
    },
    [pscustomobject]@{
        DisplayName  = 'Copilot-Geral'
        MailNickname = 'copilotgeral'
        Description  = 'Grupo de segurança do laboratório para usuários do escopo geral do Copilot.'
    }
)

if ($GrupoAlvo -ne 'Ambos') {
    $Definitions = @($Definitions | Where-Object DisplayName -eq $GrupoAlvo)
}

$ScriptBasePath = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    (Get-Location).Path
}
else {
    $PSScriptRoot
}

$EvidenceDirectory = Join-Path `
    -Path $ScriptBasePath `
    -ChildPath "evidencias\AUTO-22-Grupos-Premium-Geral\$Timestamp"

New-Item -Path $EvidenceDirectory -ItemType Directory -Force | Out-Null

$Paths = @{
    Log            = Join-Path $EvidenceDirectory 'execucao.log'
    Context        = Join-Path $EvidenceDirectory 'contexto.csv'
    Commands       = Join-Path $EvidenceDirectory 'modulos-comandos.csv'
    Roles          = Join-Path $EvidenceDirectory 'funcoes-administrativas.csv'
    Licenses       = Join-Path $EvidenceDirectory 'licencas-tenant.csv'
    BeforeGroups   = Join-Path $EvidenceDirectory 'configuracao-antes.csv'
    BeforeMembers  = Join-Path $EvidenceDirectory 'membros-antes.csv'
    AfterGroups    = Join-Path $EvidenceDirectory 'configuracao-depois.csv'
    AfterMembers   = Join-Path $EvidenceDirectory 'membros-depois.csv'
    Actions        = Join-Path $EvidenceDirectory 'acoes.csv'
    Errors         = Join-Path $EvidenceDirectory 'erros.csv'
    Summary        = Join-Path $EvidenceDirectory 'resumo.csv'
}

function Export-EvidenceCsv {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path
    )

    @($InputObject) |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
}

function ConvertTo-ODataStringLiteral {
    param([Parameter(Mandatory)][string]$Value)
    $Value.Replace("'", "''")
}

function Get-ExactGroups {
    param([Parameter(Mandatory)][string]$DisplayName)

    $EscapedName = ConvertTo-ODataStringLiteral -Value $DisplayName

    # CORREÇÃO: HasMembersWithLicenseErrors não pode ser usado em -Property.
    # A API aceita essa propriedade apenas como argumento de filtro.
    @(
        Get-MgGroup `
            -Filter "displayName eq '$EscapedName'" `
            -Property @(
                'Id',
                'DisplayName',
                'Description',
                'Mail',
                'MailNickname',
                'MailEnabled',
                'SecurityEnabled',
                'GroupTypes',
                'MembershipRule',
                'MembershipRuleProcessingState',
                'Visibility',
                'CreatedDateTime',
                'OnPremisesSyncEnabled',
                'IsAssignableToRole',
                'AssignedLicenses',
                'LicenseProcessingState'
            ) `
            -All `
            -ErrorAction Stop
    )
}

function Get-OwnerEvidence {
    param([Parameter(Mandatory)][string]$GroupId)

    $Owners = @(Get-MgGroupOwner -GroupId $GroupId -All -ErrorAction Stop)
    $Labels = foreach ($Owner in $Owners) {
        $Upn = $null
        $Name = $null
        if ($null -ne $Owner.AdditionalProperties) {
            $Upn = [string]$Owner.AdditionalProperties['userPrincipalName']
            $Name = [string]$Owner.AdditionalProperties['displayName']
        }

        if (-not [string]::IsNullOrWhiteSpace($Upn)) {
            $Upn
        }
        elseif (-not [string]::IsNullOrWhiteSpace($Name)) {
            "$Name [$($Owner.Id)]"
        }
        else {
            [string]$Owner.Id
        }
    }

    [pscustomobject]@{
        QuantidadeOwners = $Owners.Count
        OwnerIds         = (@($Owners.Id) -join ';')
        Owners           = ($Labels -join '; ')
    }
}

function Get-GroupSnapshot {
    param(
        [Parameter(Mandatory)][object[]]$GroupDefinitions,
        [Parameter(Mandatory)][object[]]$SubscribedSkus
    )

    $Rows = [System.Collections.Generic.List[object]]::new()

    foreach ($Definition in $GroupDefinitions) {
        $Matches = @(Get-ExactGroups -DisplayName $Definition.DisplayName)

        if ($Matches.Count -eq 0) {
            $Rows.Add([pscustomobject]@{
                NomeConsultado               = $Definition.DisplayName
                StatusConsulta               = 'Não encontrado'
                QuantidadeCorrespondencias   = 0
                Id                           = $null
                DisplayName                  = $null
                Description                  = $null
                MailNickname                 = $null
                MailEnabled                  = $null
                SecurityEnabled              = $null
                GroupTypes                   = $null
                TipoMembro                   = $null
                MembershipRule               = $null
                MembershipRuleProcessingState = $null
                CreatedDateTime              = $null
                OnPremisesSyncEnabled        = $null
                IsAssignableToRole           = $null
                QuantidadeOwners             = 0
                OwnerIds                     = $null
                Owners                       = $null
                QuantidadeLicencas            = 0
                SkuIdsAtribuidos              = $null
                SkuPartNumbersAtribuidos      = $null
                EstadoProcessamentoLicenca    = $null
                PossuiErrosDeLicenca          = 'Não consultado nesta versão'
            })
            continue
        }

        foreach ($Group in $Matches) {
            $OwnerEvidence = Get-OwnerEvidence -GroupId $Group.Id
            $AssignedSkuIds = @(
                $Group.AssignedLicenses |
                    ForEach-Object { [string]$_.SkuId }
            )
            $AssignedSkuNames = foreach ($SkuId in $AssignedSkuIds) {
                $Sku = $SubscribedSkus |
                    Where-Object { [string]$_.SkuId -eq $SkuId } |
                    Select-Object -First 1
                if ($null -ne $Sku) {
                    [string]$Sku.SkuPartNumber
                }
                else {
                    "SKU não localizada [$SkuId]"
                }
            }

            $LicenseState = $null
            if ($null -ne $Group.LicenseProcessingState) {
                $LicenseState = $Group.LicenseProcessingState.State
            }

            $Rows.Add([pscustomobject]@{
                NomeConsultado               = $Definition.DisplayName
                StatusConsulta               = if ($Matches.Count -eq 1) {
                    'Encontrado único'
                }
                else {
                    'Duplicidade de DisplayName'
                }
                QuantidadeCorrespondencias   = $Matches.Count
                Id                           = $Group.Id
                DisplayName                  = $Group.DisplayName
                Description                  = $Group.Description
                MailNickname                 = $Group.MailNickname
                MailEnabled                  = $Group.MailEnabled
                SecurityEnabled              = $Group.SecurityEnabled
                GroupTypes                   = (@($Group.GroupTypes) -join ';')
                TipoMembro                   = if (
                    @($Group.GroupTypes) -contains 'DynamicMembership'
                ) { 'Dinâmico' } else { 'Atribuído' }
                MembershipRule               = $Group.MembershipRule
                MembershipRuleProcessingState = $Group.MembershipRuleProcessingState
                CreatedDateTime              = $Group.CreatedDateTime
                OnPremisesSyncEnabled        = $Group.OnPremisesSyncEnabled
                IsAssignableToRole           = $Group.IsAssignableToRole
                QuantidadeOwners             = $OwnerEvidence.QuantidadeOwners
                OwnerIds                     = $OwnerEvidence.OwnerIds
                Owners                       = $OwnerEvidence.Owners
                QuantidadeLicencas            = $AssignedSkuIds.Count
                SkuIdsAtribuidos              = ($AssignedSkuIds -join ';')
                SkuPartNumbersAtribuidos      = ($AssignedSkuNames -join ';')
                EstadoProcessamentoLicenca    = $LicenseState
                PossuiErrosDeLicenca          = 'Não consultado nesta versão'
            })
        }
    }

    @($Rows)
}

function Get-MemberSnapshot {
    param([Parameter(Mandatory)][object[]]$GroupDefinitions)

    $Rows = [System.Collections.Generic.List[object]]::new()

    foreach ($Definition in $GroupDefinitions) {
        $Matches = @(Get-ExactGroups -DisplayName $Definition.DisplayName)

        if ($Matches.Count -ne 1) {
            $Rows.Add([pscustomobject]@{
                GrupoDisplayName = $Definition.DisplayName
                GroupId          = $null
                ConsultaMembros  = if ($Matches.Count -eq 0) {
                    'Não aplicável: grupo ausente'
                }
                else {
                    'Não executada: grupo duplicado'
                }
                MemberId         = $null
                TipoObjeto       = $null
            })
            continue
        }

        $Group = $Matches[0]
        $Members = @(Get-MgGroupMember -GroupId $Group.Id -All -ErrorAction Stop)

        if ($Members.Count -eq 0) {
            $Rows.Add([pscustomobject]@{
                GrupoDisplayName = $Group.DisplayName
                GroupId          = $Group.Id
                ConsultaMembros  = 'Concluída: sem membros'
                MemberId         = $null
                TipoObjeto       = $null
            })
            continue
        }

        foreach ($Member in $Members) {
            $MemberType = $null
            if ($null -ne $Member.AdditionalProperties) {
                $MemberType = $Member.AdditionalProperties['@odata.type']
            }

            $Rows.Add([pscustomobject]@{
                GrupoDisplayName = $Group.DisplayName
                GroupId          = $Group.Id
                ConsultaMembros  = 'Concluída'
                MemberId         = $Member.Id
                TipoObjeto       = $MemberType
            })
        }
    }

    @($Rows)
}

function Wait-ForGroupReplication {
    param([Parameter(Mandatory)][string]$GroupId)

    for ($Attempt = 1; $Attempt -le 10; $Attempt++) {
        try {
            $null = Get-MgGroup -GroupId $GroupId -Property @('Id', 'DisplayName') -ErrorAction Stop
            return
        }
        catch {
            if ($Attempt -eq 10) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

function Test-MembershipState {
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$DirectoryObjectId,
        [Parameter(Mandatory)][bool]$ShouldExist
    )

    for ($Attempt = 1; $Attempt -le 12; $Attempt++) {
        $Ids = @(
            Get-MgGroupMember -GroupId $GroupId -All -ErrorAction Stop |
                ForEach-Object { [string]$_.Id }
        )
        if (($DirectoryObjectId -in $Ids) -eq $ShouldExist) {
            return $true
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

Start-Transcript -Path $Paths.Log -Force | Out-Null

try {
    Write-Host ''
    Write-Host '============================================================'
    Write-Host " $AutomationId - $AutomationName"
    Write-Host " Ação: $Acao"
    Write-Host " Grupo alvo: $GrupoAlvo"
    Write-Host " Evidências: $EvidenceDirectory"
    Write-Host '============================================================'

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'Execute o script no PowerShell 7 ou superior.'
    }

    if ($IsMutation -and -not $ConfirmarAlteracao.IsPresent) {
        throw 'A ação altera o tenant. Execute novamente com -ConfirmarAlteracao após revisar os parâmetros.'
    }

    if (
        $Acao -in @('AdicionarMembro', 'RemoverMembro') -and
        [string]::IsNullOrWhiteSpace($UsuarioTesteUPN)
    ) {
        throw 'Informe -UsuarioTesteUPN com uma conta dedicada do laboratório.'
    }

    $RequiredCommands = @(
        'Connect-MgGraph', 'Disconnect-MgGraph', 'Get-MgContext',
        'Get-MgUser', 'Get-MgSubscribedSku', 'Get-MgGroup',
        'Get-MgGroupOwner', 'Get-MgGroupMember',
        'Get-MgRoleManagementDirectoryRoleAssignment',
        'Get-MgRoleManagementDirectoryRoleDefinition'
    )
    if ($Acao -eq 'CriarGrupos') {
        $RequiredCommands += @('New-MgGroup', 'New-MgGroupOwnerByRef')
    }
    if ($Acao -eq 'AdicionarMembro') {
        $RequiredCommands += 'New-MgGroupMember'
    }
    if ($Acao -eq 'RemoverMembro') {
        $RequiredCommands += 'Remove-MgGroupMemberByRef'
    }

    $CommandEvidence = foreach ($CommandName in ($RequiredCommands | Sort-Object -Unique)) {
        $Command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Comando    = $CommandName
            Disponivel = ($null -ne $Command)
            Tipo       = if ($Command) { $Command.CommandType } else { $null }
            Modulo     = if ($Command) { $Command.ModuleName } else { $null }
            Versao     = if ($Command -and $Command.Module) {
                $Command.Module.Version
            }
            else { $null }
        }
    }
    Export-EvidenceCsv -InputObject $CommandEvidence -Path $Paths.Commands

    $MissingCommands = @($CommandEvidence | Where-Object Disponivel -eq $false)
    if ($MissingCommands.Count -gt 0) {
        throw ('Comandos ausentes: ' + ($MissingCommands.Comando -join ', '))
    }

    $RequiredScopes = @(
        'Group.Read.All', 'User.Read.All', 'Organization.Read.All',
        'RoleManagement.Read.Directory'
    )
    if ($Acao -eq 'CriarGrupos') {
        $RequiredScopes += 'Group.ReadWrite.All'
    }
    if ($Acao -in @('AdicionarMembro', 'RemoverMembro')) {
        $RequiredScopes += 'GroupMember.ReadWrite.All'
    }
    $RequiredScopes = @($RequiredScopes | Sort-Object -Unique)

    if ($null -ne (Get-MgContext -ErrorAction SilentlyContinue)) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }

    Connect-MgGraph `
        -TenantId $TenantIdEsperado `
        -Scopes $RequiredScopes `
        -ContextScope Process `
        -UseDeviceCode `
        -NoWelcome `
        -ErrorAction Stop
    $GraphConnectedByScript = $true

    $Context = Get-MgContext -ErrorAction Stop
    if ($null -eq $Context) {
        throw 'A autenticação não produziu um contexto do Microsoft Graph.'
    }
    if ($Context.TenantId -ne $TenantIdEsperado) {
        throw "Tenant incorreto. Esperado: $TenantIdEsperado. Conectado: $($Context.TenantId)."
    }
    if (-not [string]::Equals(
        [string]$Context.Account,
        [string]$ContaEsperada,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Conta incorreta. Esperada: $ContaEsperada. Conectada: $($Context.Account)."
    }

    $MissingScopes = @($RequiredScopes | Where-Object { $_ -notin @($Context.Scopes) })
    if ($MissingScopes.Count -gt 0) {
        throw ('Escopos ausentes: ' + ($MissingScopes -join ', '))
    }

    $AdminUser = Get-MgUser `
        -UserId $ContaEsperada `
        -Property @('Id', 'DisplayName', 'UserPrincipalName', 'AccountEnabled', 'UsageLocation') `
        -ErrorAction Stop
    if ($AdminUser.AccountEnabled -ne $true) {
        throw 'A conta administrativa esperada não está habilitada.'
    }

    $RoleAssignments = @(
        Get-MgRoleManagementDirectoryRoleAssignment `
            -Filter "principalId eq '$($AdminUser.Id)'" `
            -All `
            -ErrorAction Stop
    )
    $RoleEvidence = foreach ($Assignment in $RoleAssignments) {
        $Definition = Get-MgRoleManagementDirectoryRoleDefinition `
            -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId `
            -ErrorAction Stop
        [pscustomobject]@{
            Conta            = $ContaEsperada
            PrincipalId      = $AdminUser.Id
            Funcao           = $Definition.DisplayName
            RoleDefinitionId = $Assignment.RoleDefinitionId
            RoleAssignmentId = $Assignment.Id
            DirectoryScopeId = $Assignment.DirectoryScopeId
        }
    }
    Export-EvidenceCsv -InputObject $RoleEvidence -Path $Paths.Roles

    $AcceptedRoles = @(
        'Global Administrator', 'Groups Administrator',
        'User Administrator', 'Directory Writers'
    )
    $HasAcceptedRole = @(
        $RoleEvidence | Where-Object Funcao -in $AcceptedRoles
    ).Count -gt 0
    if (-not $HasAcceptedRole) {
        throw 'A conta não possui uma função ativa aceita para a prova.'
    }

    $SubscribedSkus = @(Get-MgSubscribedSku -All -ErrorAction Stop)
    $LicenseEvidence = foreach ($Sku in $SubscribedSkus) {
        $EnabledUnits = [int]$Sku.PrepaidUnits.Enabled
        $ConsumedUnits = [int]$Sku.ConsumedUnits
        [pscustomobject]@{
            SkuPartNumber       = $Sku.SkuPartNumber
            SkuId               = $Sku.SkuId
            Capacidade          = $Sku.CapabilityStatus
            UnidadesAtivas      = $EnabledUnits
            UnidadesUsadas      = $ConsumedUnits
            UnidadesDisponiveis = ($EnabledUnits - $ConsumedUnits)
            CandidataCopilot    = ([string]$Sku.SkuPartNumber -match 'COPILOT')
            AplicaSeA           = $Sku.AppliesTo
            ServicePlans        = (@($Sku.ServicePlans.ServicePlanName) -join ';')
        }
    }
    Export-EvidenceCsv -InputObject $LicenseEvidence -Path $Paths.Licenses

    $ContextEvidence = [pscustomobject]@{
        DataHora               = $ExecutionStarted.ToString('o')
        AutomationId           = $AutomationId
        AutomationName         = $AutomationName
        Acao                   = $Acao
        GrupoAlvo              = $GrupoAlvo
        UsuarioTesteUPN        = $UsuarioTesteUPN
        TenantIdEsperado       = $TenantIdEsperado
        TenantIdConectado      = $Context.TenantId
        TenantCorreto          = ($Context.TenantId -eq $TenantIdEsperado)
        ContaEsperada          = $ContaEsperada
        ContaConectada         = $Context.Account
        ContaCorreta           = $true
        ContaHabilitada        = $AdminUser.AccountEnabled
        PowerShellVersion      = $PSVersionTable.PSVersion.ToString()
        PowerShellEdition      = $PSVersionTable.PSEdition
        EscoposObrigatorios    = ($RequiredScopes -join ';')
        EscoposAtivos          = (@($Context.Scopes) -join ';')
        FuncaoAceitaConfirmada = $HasAcceptedRole
        ConfirmarAlteracao     = $ConfirmarAlteracao.IsPresent
        PastaEvidencias        = $EvidenceDirectory
    }
    Export-EvidenceCsv -InputObject $ContextEvidence -Path $Paths.Context

    $BeforeGroups = @(Get-GroupSnapshot -GroupDefinitions $Definitions -SubscribedSkus $SubscribedSkus)
    $BeforeMembers = @(Get-MemberSnapshot -GroupDefinitions $Definitions)
    Export-EvidenceCsv -InputObject $BeforeGroups -Path $Paths.BeforeGroups
    Export-EvidenceCsv -InputObject $BeforeMembers -Path $Paths.BeforeMembers

    $Duplicates = @($BeforeGroups | Where-Object QuantidadeCorrespondencias -gt 1)
    if ($IsMutation -and $Duplicates.Count -gt 0) {
        throw ('Duplicidade de DisplayName: ' + (($Duplicates.NomeConsultado | Sort-Object -Unique) -join ', '))
    }

    switch ($Acao) {
        'Consultar' {
            $ActionEvidence.Add([pscustomobject]@{
                DataHora  = (Get-Date).ToString('o')
                Acao      = $Acao
                Grupo     = $GrupoAlvo
                ObjetoId  = $null
                Resultado = 'Consulta concluída; nenhuma alteração executada'
            })
        }

        'CriarGrupos' {
            foreach ($Definition in $Definitions) {
                $Existing = @(Get-ExactGroups -DisplayName $Definition.DisplayName)
                if ($Existing.Count -eq 1) {
                    $ActionEvidence.Add([pscustomobject]@{
                        DataHora  = (Get-Date).ToString('o')
                        Acao      = $Acao
                        Grupo     = $Definition.DisplayName
                        ObjetoId  = $Existing[0].Id
                        Resultado = 'Grupo já existia; criação ignorada'
                    })
                    continue
                }

                $EscapedNickname = ConvertTo-ODataStringLiteral -Value $Definition.MailNickname
                $NicknameConflict = @(
                    Get-MgGroup `
                        -Filter "mailNickname eq '$EscapedNickname'" `
                        -Property @('Id', 'DisplayName', 'MailNickname') `
                        -All `
                        -ErrorAction Stop
                )
                if ($NicknameConflict.Count -gt 0) {
                    throw "O mailNickname $($Definition.MailNickname) já está em uso."
                }

                $NewGroup = New-MgGroup `
                    -DisplayName $Definition.DisplayName `
                    -Description $Definition.Description `
                    -MailEnabled:$false `
                    -MailNickname $Definition.MailNickname `
                    -SecurityEnabled:$true `
                    -GroupTypes @() `
                    -ErrorAction Stop
                $ChangesExecuted = $true
                Wait-ForGroupReplication -GroupId $NewGroup.Id

                $OwnerReference = @{
                    '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($AdminUser.Id)"
                }
                $OwnerAdded = $false
                for ($Attempt = 1; $Attempt -le 8; $Attempt++) {
                    try {
                        New-MgGroupOwnerByRef `
                            -GroupId $NewGroup.Id `
                            -BodyParameter $OwnerReference `
                            -ErrorAction Stop
                        $OwnerAdded = $true
                        break
                    }
                    catch {
                        if ($Attempt -eq 8) { throw }
                        Start-Sleep -Seconds 5
                    }
                }
                if (-not $OwnerAdded) {
                    throw "O grupo $($Definition.DisplayName) foi criado, mas o owner não foi confirmado."
                }

                $ActionEvidence.Add([pscustomobject]@{
                    DataHora  = (Get-Date).ToString('o')
                    Acao      = $Acao
                    Grupo     = $Definition.DisplayName
                    ObjetoId  = $NewGroup.Id
                    Resultado = 'Grupo criado e conta administrativa adicionada como owner'
                })
            }
        }

        'AdicionarMembro' {
            $TestUser = Get-MgUser `
                -UserId $UsuarioTesteUPN `
                -Property @('Id', 'UserPrincipalName', 'AccountEnabled', 'UsageLocation') `
                -ErrorAction Stop
            if ($TestUser.AccountEnabled -ne $true) {
                throw 'O usuário de teste não está habilitado.'
            }

            foreach ($Definition in $Definitions) {
                $Group = @(Get-ExactGroups -DisplayName $Definition.DisplayName)
                if ($Group.Count -ne 1) {
                    throw "O grupo $($Definition.DisplayName) precisa existir uma única vez."
                }
                if (@($Group[0].GroupTypes) -contains 'DynamicMembership') {
                    throw "O grupo $($Definition.DisplayName) é dinâmico."
                }

                $CurrentIds = @(
                    Get-MgGroupMember -GroupId $Group[0].Id -All -ErrorAction Stop |
                        ForEach-Object { [string]$_.Id }
                )
                if ($TestUser.Id -in $CurrentIds) {
                    $ActionEvidence.Add([pscustomobject]@{
                        DataHora  = (Get-Date).ToString('o')
                        Acao      = $Acao
                        Grupo     = $Definition.DisplayName
                        ObjetoId  = $TestUser.Id
                        Resultado = 'Usuário já era membro; inclusão ignorada'
                    })
                    continue
                }

                New-MgGroupMember `
                    -GroupId $Group[0].Id `
                    -DirectoryObjectId $TestUser.Id `
                    -ErrorAction Stop
                $ChangesExecuted = $true

                if (-not (Test-MembershipState `
                    -GroupId $Group[0].Id `
                    -DirectoryObjectId $TestUser.Id `
                    -ShouldExist $true
                )) {
                    throw "A associação em $($Definition.DisplayName) não foi confirmada."
                }

                $ActionEvidence.Add([pscustomobject]@{
                    DataHora  = (Get-Date).ToString('o')
                    Acao      = $Acao
                    Grupo     = $Definition.DisplayName
                    ObjetoId  = $TestUser.Id
                    Resultado = 'Usuário adicionado e associação confirmada'
                })
            }
        }

        'RemoverMembro' {
            $TestUser = Get-MgUser `
                -UserId $UsuarioTesteUPN `
                -Property @('Id', 'UserPrincipalName') `
                -ErrorAction Stop

            foreach ($Definition in $Definitions) {
                $Group = @(Get-ExactGroups -DisplayName $Definition.DisplayName)
                if ($Group.Count -ne 1) {
                    throw "O grupo $($Definition.DisplayName) precisa existir uma única vez."
                }
                if (@($Group[0].GroupTypes) -contains 'DynamicMembership') {
                    throw "O grupo $($Definition.DisplayName) é dinâmico."
                }

                $CurrentIds = @(
                    Get-MgGroupMember -GroupId $Group[0].Id -All -ErrorAction Stop |
                        ForEach-Object { [string]$_.Id }
                )
                if ($TestUser.Id -notin $CurrentIds) {
                    $ActionEvidence.Add([pscustomobject]@{
                        DataHora  = (Get-Date).ToString('o')
                        Acao      = $Acao
                        Grupo     = $Definition.DisplayName
                        ObjetoId  = $TestUser.Id
                        Resultado = 'Usuário não era membro; remoção ignorada'
                    })
                    continue
                }

                Remove-MgGroupMemberByRef `
                    -GroupId $Group[0].Id `
                    -DirectoryObjectId $TestUser.Id `
                    -Confirm:$false `
                    -ErrorAction Stop
                $ChangesExecuted = $true

                if (-not (Test-MembershipState `
                    -GroupId $Group[0].Id `
                    -DirectoryObjectId $TestUser.Id `
                    -ShouldExist $false
                )) {
                    throw "A remoção em $($Definition.DisplayName) não foi confirmada."
                }

                $ActionEvidence.Add([pscustomobject]@{
                    DataHora  = (Get-Date).ToString('o')
                    Acao      = $Acao
                    Grupo     = $Definition.DisplayName
                    ObjetoId  = $TestUser.Id
                    Resultado = 'Usuário removido e ausência confirmada'
                })
            }
        }
    }

    Export-EvidenceCsv -InputObject $ActionEvidence -Path $Paths.Actions

    $AfterGroups = @(Get-GroupSnapshot -GroupDefinitions $Definitions -SubscribedSkus $SubscribedSkus)
    $AfterMembers = @(Get-MemberSnapshot -GroupDefinitions $Definitions)
    Export-EvidenceCsv -InputObject $AfterGroups -Path $Paths.AfterGroups
    Export-EvidenceCsv -InputObject $AfterMembers -Path $Paths.AfterMembers

    $ValidationApproved = $true
    $ValidationNotes = [System.Collections.Generic.List[string]]::new()

    foreach ($Definition in $Definitions) {
        $After = @($AfterGroups | Where-Object NomeConsultado -eq $Definition.DisplayName)

        if ($Acao -eq 'Consultar') {
            if ($After.Count -eq 0) {
                $ValidationApproved = $false
                $ValidationNotes.Add("A consulta não produziu registro para $($Definition.DisplayName).")
            }
            continue
        }

        if ($After.Count -ne 1 -or $After[0].QuantidadeCorrespondencias -ne 1) {
            $ValidationApproved = $false
            $ValidationNotes.Add("O grupo $($Definition.DisplayName) não ficou único.")
            continue
        }

        if ($Acao -eq 'CriarGrupos') {
            if (
                $After[0].SecurityEnabled -ne $true -or
                $After[0].MailEnabled -ne $false -or
                $After[0].MailNickname -ne $Definition.MailNickname -or
                $After[0].QuantidadeOwners -lt 1
            ) {
                $ValidationApproved = $false
                $ValidationNotes.Add("As propriedades de $($Definition.DisplayName) não correspondem ao esperado.")
            }
        }
    }

    if ($Acao -in @('AdicionarMembro', 'RemoverMembro')) {
        $TestUserFinal = Get-MgUser -UserId $UsuarioTesteUPN -Property @('Id') -ErrorAction Stop
        foreach ($Definition in $Definitions) {
            $GroupFinal = @(Get-ExactGroups -DisplayName $Definition.DisplayName)
            if ($GroupFinal.Count -ne 1) {
                $ValidationApproved = $false
                continue
            }
            $FinalIds = @(
                Get-MgGroupMember -GroupId $GroupFinal[0].Id -All -ErrorAction Stop |
                    ForEach-Object { [string]$_.Id }
            )
            $Exists = $TestUserFinal.Id -in $FinalIds
            $Expected = ($Acao -eq 'AdicionarMembro')
            if ($Exists -ne $Expected) {
                $ValidationApproved = $false
                $ValidationNotes.Add("O estado do membro em $($Definition.DisplayName) não corresponde ao esperado.")
            }
        }
    }

    if ($ValidationNotes.Count -eq 0) {
        $ValidationNotes.Add('Todas as validações objetivas da ação foram aprovadas.')
    }

    $Summary = [pscustomobject]@{
        DataHoraInicio      = $ExecutionStarted.ToString('o')
        DataHoraFim         = (Get-Date).ToString('o')
        Item                = $AutomationId
        Controle            = $AutomationName
        AcaoSolicitada      = $Acao
        GrupoAlvo           = $GrupoAlvo
        UsuarioTesteUPN     = $UsuarioTesteUPN
        Tenant              = $Context.TenantId
        Conta               = $Context.Account
        AlteracaoExecutada  = $ChangesExecuted
        ExecucaoConcluida   = $true
        ValidacaoAprovada   = $ValidationApproved
        ObservacaoValidacao = ($ValidationNotes -join ' ')
        LicencaAtribuida    = $false
        LicencaRemovida     = $false
        GrupoExcluido       = $false
        PastaEvidencias     = $EvidenceDirectory
    }
    Export-EvidenceCsv -InputObject $Summary -Path $Paths.Summary

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' RESULTADO DA PROVA'
    Write-Host '============================================================'
    $Summary | Format-List

    if (-not $ValidationApproved) {
        throw 'A execução terminou, mas a validação objetiva não foi aprovada.'
    }

    Write-Host 'Item 22 concluído com validação aprovada.' -ForegroundColor Green
}
catch {
    $Message = $_.Exception.Message
    $ErrorEvidence.Add([pscustomobject]@{
        DataHora = (Get-Date).ToString('o')
        Etapa    = 'Execução'
        Mensagem = $Message
    })
    Export-EvidenceCsv -InputObject $ErrorEvidence -Path $Paths.Errors

    $FailureSummary = [pscustomobject]@{
        DataHoraInicio      = $ExecutionStarted.ToString('o')
        DataHoraFim         = (Get-Date).ToString('o')
        Item                = $AutomationId
        Controle            = $AutomationName
        AcaoSolicitada      = $Acao
        GrupoAlvo           = $GrupoAlvo
        UsuarioTesteUPN     = $UsuarioTesteUPN
        AlteracaoExecutada  = $ChangesExecuted
        ExecucaoConcluida   = $false
        ValidacaoAprovada   = $false
        ObservacaoValidacao = $Message
        LicencaAtribuida    = $false
        LicencaRemovida     = $false
        GrupoExcluido       = $false
        PastaEvidencias     = $EvidenceDirectory
    }
    Export-EvidenceCsv -InputObject $FailureSummary -Path $Paths.Summary

    Write-Host ''
    Write-Host 'A prova do item 22 não foi concluída.' -ForegroundColor Red
    Write-Host $Message -ForegroundColor Red
    throw
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
    if ($GraphConnectedByScript) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
}