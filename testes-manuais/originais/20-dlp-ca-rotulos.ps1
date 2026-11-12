<#
.SYNOPSIS
    AUTO-20 - Prova controlada de DLP, Acesso Condicional e rótulos de sensibilidade.

.DESCRIPTION
    Valida tenant, conta, sessão, módulos, comandos, escopos Graph, funções
    administrativas e licenças. Permite consultar, criar, habilitar, desabilitar
    e reverter somente os objetos de laboratório definidos neste arquivo.

    As alterações exigem -ConfirmarAlteracao e uma -Justificativa.

.NOTES
    OBJETIVO:
    - Comprovar a automação de DLP da Power Platform, Acesso Condicional,
      DLP do Microsoft Purview, rótulo de sensibilidade e política de publicação.

    FERRAMENTA:
    - Windows PowerShell 5.1
    - Microsoft.PowerApps.Administration.PowerShell
    - Microsoft.Graph.Authentication
    - Microsoft.Graph.Identity.SignIns
    - ExchangeOnlineManagement / Security & Compliance PowerShell

    PERMISSÃO:
    - Power Platform Administrator ou Global Administrator para DLP da Power Platform.
    - Graph delegado: Policy.Read.All, Policy.ReadWrite.ConditionalAccess,
      User.Read.All, Organization.Read.All e RoleManagement.Read.Directory.
    - Função Entra compatível com escrita de Acesso Condicional.
    - RBAC do Purview compatível com DLP e Information Protection.

    LICENÇA:
    - Acesso Condicional: Microsoft Entra ID P1 ou superior para os usuários abrangidos.
    - DLP e rótulos: licenciamento conforme workload e recurso utilizado.
    - O script registra SKUs e planos; a existência do SKU não substitui a validação funcional.

    EFEITO:
    - Consultar: nenhuma alteração administrativa.
    - CriarModelo: cria somente objetos com prefixo LAB-AUTO20.
    - HabilitarModelo: habilita CA, DLP Purview e publicação do rótulo de laboratório.
    - DesabilitarModelo: desabilita CA e DLP Purview e remove o rótulo da política de publicação.
    - ReverterModelo: remove somente os objetos de laboratório criados pelo script.

    RECURSO-ALVO:
    - Tenant de laboratório informado nos parâmetros.
    - Conta administrativa informada nos parâmetros.

    PARÂMETROS EDITÁVEIS:
    - TenantId
    - AdminUPN
    - Acao
    - Justificativa
    - EvidenceRoot
    - PowerPlatformEnvironmentType
    - nomes dos objetos LAB-AUTO20

    EVIDÊNCIAS:
    - contexto.csv
    - modulos-comandos.csv
    - funcoes-administrativas.csv
    - licencas-tenant.csv
    - configuracao-antes.json
    - configuracao-depois.json
    - acoes.csv
    - resumo.json
    - execucao.log

    RISCOS:
    - Uma política de Acesso Condicional habilitada pode bloquear autenticações.
    - DLP e rótulos podem levar tempo para distribuição.
    - A política DLP da Power Platform não possui estado habilitado/desabilitado equivalente.

    ATENÇÃO:
    - Execute primeiro com -Acao Consultar.
    - A política de Acesso Condicional é criada em report-only.
    - HabilitarModelo afeta somente a conta administrativa informada.
    - Não use nomes de produção nos parâmetros.
    - Microsoft Graph 2.41.x possui falha conhecida de autenticação
      RefreshCacheAsync; esta versão do script fixa os módulos Graph em 2.39.0.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet(
        'Consultar',
        'CriarModelo',
        'HabilitarModelo',
        'DesabilitarModelo',
        'ReverterModelo'
    )]
    [string]$Acao = 'Consultar',

    [Parameter(Mandatory = $false)]
    [string]$TenantId = 'd7935522-6fc7-408d-8633-e4109183c63f',

    [Parameter(Mandatory = $false)]
    [string]$AdminUPN = 'admin@m365mcp79922602.onmicrosoft.com',

    [Parameter(Mandatory = $false)]
    [version]$GraphModuleVersion = '2.39.0',

    [Parameter(Mandatory = $false)]
    [switch]$ConfirmarAlteracao,

    [Parameter(Mandatory = $false)]
    [string]$Justificativa = '',

    [Parameter(Mandatory = $false)]
    [string]$EvidenceRoot = (
        'C:\Users\PedroFrei\Documents\OneDrive - Bizapp\' +
        'Documentos\Projetos\coe-validacao-scripts\evidencias'
    ),

    [Parameter(Mandatory = $false)]
    [string]$PowerPlatformEnvironmentType = 'AllEnvironments',

    [Parameter(Mandatory = $false)]
    [string]$PowerPlatformDlpName = 'LAB-AUTO20-DLP-Agentes',

    [Parameter(Mandatory = $false)]
    [string]$ConditionalAccessName = 'LAB-AUTO20-CA-MFA-Admin',

    [Parameter(Mandatory = $false)]
    [string]$PurviewDlpName = 'LAB-AUTO20-DLP-Copilot',

    [Parameter(Mandatory = $false)]
    [string]$SensitivityLabelName = 'LAB-AUTO20-Confidencial',

    [Parameter(Mandatory = $false)]
    [string]$LabelPolicyName = 'LAB-AUTO20-Politica-Rotulos'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (
    $PSVersionTable.PSEdition -ne 'Desktop' -or
    $PSVersionTable.PSVersion.Major -ne 5
) {
    throw (
        'Execute no Windows PowerShell 5.1. ' +
        "Versão atual: $($PSVersionTable.PSVersion); " +
        "edição: $($PSVersionTable.PSEdition)."
    )
}

$ChangeActions = @(
    'CriarModelo',
    'HabilitarModelo',
    'DesabilitarModelo',
    'ReverterModelo'
)

if ($Acao -in $ChangeActions) {
    if (-not $ConfirmarAlteracao) {
        throw (
            "A ação '$Acao' altera o tenant. " +
            'Execute novamente com -ConfirmarAlteracao.'
        )
    }

    if ([string]::IsNullOrWhiteSpace($Justificativa)) {
        throw (
            "A ação '$Acao' exige -Justificativa com o motivo da prova."
        )
    }
}

foreach ($NameToValidate in @(
    $PowerPlatformDlpName,
    $ConditionalAccessName,
    $PurviewDlpName,
    $SensitivityLabelName,
    $LabelPolicyName
)) {
    if ($NameToValidate -notlike 'LAB-AUTO20-*') {
        throw (
            "Nome fora do padrão seguro LAB-AUTO20: $NameToValidate"
        )
    }
}

function Get-SafeProperty {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
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

function ConvertTo-SafeJson {
    param(
        [AllowNull()]
        [object]$Value,

        [int]$Depth = 30
    )

    if ($null -eq $Value) {
        return $null
    }

    return ($Value | ConvertTo-Json -Depth $Depth)
}

function Export-Utf8Csv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowNull()]
        [object[]]$InputObject,

        [string]$EmptyMessage = 'Nenhum registro encontrado.'
    )

    $Records = @($InputObject)
    if ($Records.Count -gt 0) {
        $Records |
            Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
        return
    }

    [PSCustomObject]@{
        DataHora = Get-Date
        Resultado = $EmptyMessage
    } |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Add-ActionRecord {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$List,

        [Parameter(Mandatory = $true)]
        [string]$Componente,

        [Parameter(Mandatory = $true)]
        [string]$Operacao,

        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'Sucesso',
            'Falha',
            'Bloqueado',
            'Ignorado',
            'Não aplicável'
        )]
        [string]$Status,

        [string]$Detalhe = ''
    )

    [void]$List.Add(
        [PSCustomObject]@{
            DataHora = Get-Date
            Componente = $Componente
            Operacao = $Operacao
            Status = $Status
            Detalhe = $Detalhe
        }
    )
}

function Get-LatestModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return (
        Get-Module -ListAvailable -Name $Name |
            Sort-Object Version -Descending |
            Select-Object -First 1
    )
}

function Test-TextEquals {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected
    )

    return [string]::Equals(
        [string]$Actual,
        [string]$Expected,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $Items = New-Object System.Collections.ArrayList
    $NextUri = $Uri

    while (-not [string]::IsNullOrWhiteSpace($NextUri)) {
        $Response = Invoke-MgGraphRequest `
            -Method GET `
            -Uri $NextUri `
            -OutputType PSObject `
            -ErrorAction Stop

        foreach ($Item in @($Response.value)) {
            [void]$Items.Add($Item)
        }

        $NextLinkProperty = $Response.PSObject.Properties['@odata.nextLink']
        if ($null -ne $NextLinkProperty) {
            $NextUri = [string]$NextLinkProperty.Value
        }
        else {
            $NextUri = ''
        }
    }

    return @($Items)
}

function Find-ByName {
    param(
        [AllowNull()]
        [object[]]$Items,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedName,

        [string[]]$Properties = @('Name', 'DisplayName')
    )

    foreach ($Item in @($Items)) {
        foreach ($Property in $Properties) {
            if (Test-TextEquals (Get-SafeProperty $Item $Property) $ExpectedName) {
                return $Item
            }
        }
    }

    return $null
}

function Get-Auto20State {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$PowerPlatformPolicies,

        [Parameter(Mandatory = $true)]
        [object[]]$ConditionalAccessPolicies,

        [Parameter(Mandatory = $true)]
        [object[]]$PurviewDlpPolicies,

        [Parameter(Mandatory = $true)]
        [object[]]$Labels,

        [Parameter(Mandatory = $true)]
        [object[]]$LabelPolicies
    )

    $PowerPlatformPolicy = Find-ByName `
        -Items $PowerPlatformPolicies `
        -ExpectedName $PowerPlatformDlpName `
        -Properties @('DisplayName', 'PolicyName', 'Name')

    $ConditionalAccessPolicy = Find-ByName `
        -Items $ConditionalAccessPolicies `
        -ExpectedName $ConditionalAccessName `
        -Properties @('DisplayName')

    $PurviewDlpPolicy = Find-ByName `
        -Items $PurviewDlpPolicies `
        -ExpectedName $PurviewDlpName `
        -Properties @('Name', 'DisplayName')

    $Label = Find-ByName `
        -Items $Labels `
        -ExpectedName $SensitivityLabelName `
        -Properties @('Name', 'DisplayName')

    $LabelPolicy = Find-ByName `
        -Items $LabelPolicies `
        -ExpectedName $LabelPolicyName `
        -Properties @('Name')

    return [ordered]@{
        PowerPlatformDlp = $PowerPlatformPolicy
        ConditionalAccess = $ConditionalAccessPolicy
        PurviewDlp = $PurviewDlpPolicy
        SensitivityLabel = $Label
        LabelPolicy = $LabelPolicy
    }
}

$StartedAt = Get-Date
$Stamp = $StartedAt.ToString('yyyyMMdd-HHmmss')
$EvidenceDirectory = Join-Path `
    (Join-Path $EvidenceRoot 'AUTO-20-DLP-CA-Rotulos') `
    $Stamp

New-Item -Path $EvidenceDirectory -ItemType Directory -Force | Out-Null

$Paths = @{
    Log = Join-Path $EvidenceDirectory 'execucao.log'
    Context = Join-Path $EvidenceDirectory 'contexto.csv'
    Modules = Join-Path $EvidenceDirectory 'modulos-comandos.csv'
    Roles = Join-Path $EvidenceDirectory 'funcoes-administrativas.csv'
    Licenses = Join-Path $EvidenceDirectory 'licencas-tenant.csv'
    Before = Join-Path $EvidenceDirectory 'configuracao-antes.json'
    After = Join-Path $EvidenceDirectory 'configuracao-depois.json'
    Actions = Join-Path $EvidenceDirectory 'acoes.csv'
    Summary = Join-Path $EvidenceDirectory 'resumo.json'
}

$Actions = New-Object System.Collections.ArrayList
$Capabilities = New-Object System.Collections.ArrayList
$GraphConnected = $false
$PurviewConnected = $false
$PurviewAvailable = $false
$PurviewBlockReason = ''
$PowerPlatformConnected = $false
$GraphContext = $null
$PurviewConnection = $null
$AdminUser = $null
$Roles = @()
$Skus = @()
$BeforeState = $null
$AfterState = $null
$FatalError = $null

Start-Transcript -LiteralPath $Paths.Log -Force | Out-Null

try {
    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' AUTO-20 - DLP, ACESSO CONDICIONAL E RÓTULOS'
    Write-Host " Ação: $Acao"
    Write-Host " Tenant esperado: $TenantId"
    Write-Host " Conta esperada: $AdminUPN"
    Write-Host '============================================================'

    $RequiredModules = @(
        'Microsoft.PowerApps.Administration.PowerShell'
    )
    $GraphModules = @(
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Identity.SignIns'
    )
    $PurviewModuleName = 'ExchangeOnlineManagement'

    foreach ($ModuleName in $RequiredModules) {
        $Module = Get-LatestModule -Name $ModuleName
        [void]$Capabilities.Add(
            [PSCustomObject]@{
                Tipo = 'Módulo'
                Nome = $ModuleName
                Disponivel = ($null -ne $Module)
                Origem = if ($Module) { $Module.Path } else { '' }
                Versao = if ($Module) { [string]$Module.Version } else { '' }
            }
        )
    }

    foreach ($ModuleName in $GraphModules) {
        $Module = Get-Module `
            -ListAvailable `
            -Name $ModuleName |
            Where-Object {
                $_.Version -eq $GraphModuleVersion
            } |
            Select-Object -First 1

        [void]$Capabilities.Add(
            [PSCustomObject]@{
                Tipo = 'Módulo Graph fixado'
                Nome = $ModuleName
                Disponivel = ($null -ne $Module)
                Origem = if ($Module) { $Module.Path } else { '' }
                Versao = if ($Module) {
                    [string]$Module.Version
                }
                else {
                    ''
                }
            }
        )
    }

    $PurviewModule = Get-LatestModule -Name $PurviewModuleName
    [void]$Capabilities.Add(
        [PSCustomObject]@{
            Tipo = 'Módulo opcional - Purview'
            Nome = $PurviewModuleName
            Disponivel = ($null -ne $PurviewModule)
            Origem = if ($PurviewModule) { $PurviewModule.Path } else { '' }
            Versao = if ($PurviewModule) {
                [string]$PurviewModule.Version
            }
            else {
                ''
            }
        }
    )

    $MissingModules = @(
        $Capabilities |
            Where-Object {
                $_.Tipo -in @('Módulo', 'Módulo Graph fixado') -and
                -not $_.Disponivel
            }
    )

    if ($MissingModules.Count -gt 0) {
        throw (
            'Módulos ausentes ou fora da versão exigida: ' +
            (($MissingModules | Select-Object -ExpandProperty Nome) -join ', ') +
            ". Versão Graph exigida: $GraphModuleVersion."
        )
    }

    foreach ($ModuleName in $RequiredModules) {
        Import-Module $ModuleName -ErrorAction Stop
    }

    $LoadedGraphModules = @(
        Get-Module |
            Where-Object {
                $_.Name -in $GraphModules -and
                $_.Version -ne $GraphModuleVersion
            }
    )

    if ($LoadedGraphModules.Count -gt 0) {
        throw (
            'Uma versão incompatível do Microsoft Graph já está carregada ' +
            'nesta janela. Feche o Windows PowerShell, abra uma nova janela ' +
            "e execute novamente. Versão exigida: $GraphModuleVersion."
        )
    }

    foreach ($ModuleName in $GraphModules) {
        Import-Module `
            -Name $ModuleName `
            -RequiredVersion $GraphModuleVersion `
            -ErrorAction Stop
    }

    $RequiredCommands = @(
        'Add-PowerAppsAccount',
        'Get-DlpPolicy',
        'New-DlpPolicy',
        'Remove-DlpPolicy',
        'Connect-MgGraph',
        'Get-MgContext',
        'Invoke-MgGraphRequest',
        'Get-MgIdentityConditionalAccessPolicy',
        'New-MgIdentityConditionalAccessPolicy',
        'Update-MgIdentityConditionalAccessPolicy',
        'Remove-MgIdentityConditionalAccessPolicy'
    )

    foreach ($CommandName in $RequiredCommands) {
        $Command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
        [void]$Capabilities.Add(
            [PSCustomObject]@{
                Tipo = 'Comando local'
                Nome = $CommandName
                Disponivel = ($null -ne $Command)
                Origem = if ($Command) { $Command.Source } else { '' }
                Versao = if ($Command) {
                    [string]$Command.Version
                }
                else {
                    ''
                }
            }
        )
    }

    Export-Utf8Csv -Path $Paths.Modules -InputObject @($Capabilities)

    $MissingCommands = @(
        $Capabilities |
            Where-Object {
                $_.Tipo -eq 'Comando local' -and -not $_.Disponivel
            }
    )

    if ($MissingCommands.Count -gt 0) {
        throw (
            'Comandos ausentes: ' +
            (($MissingCommands | Select-Object -ExpandProperty Nome) -join ', ')
        )
    }

    Write-Host ''
    Write-Host '1. Conectando à Power Platform...' -ForegroundColor Cyan
    Add-PowerAppsAccount `
        -Endpoint prod `
        -TenantID $TenantId `
        -ErrorAction Stop |
        Out-Null
    $PowerPlatformConnected = $true

    Write-Host '2. Conectando ao Microsoft Graph...' -ForegroundColor Cyan
    if ($null -ne (Get-MgContext -ErrorAction SilentlyContinue)) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }

    $GraphScopes = @(
        'Policy.Read.All',
        'Policy.ReadWrite.ConditionalAccess',
        'User.Read.All',
        'Organization.Read.All',
        'RoleManagement.Read.Directory'
    )

    Connect-MgGraph `
        -TenantId $TenantId `
        -Scopes $GraphScopes `
        -ContextScope Process `
        -UseDeviceCode `
        -NoWelcome `
        -ErrorAction Stop

    $GraphConnected = $true
    $GraphContext = Get-MgContext -ErrorAction Stop

    if (-not (Test-TextEquals $GraphContext.TenantId $TenantId)) {
        throw "Tenant Graph incorreto: $($GraphContext.TenantId)"
    }

    if (-not (Test-TextEquals $GraphContext.Account $AdminUPN)) {
        throw "Conta Graph incorreta: $($GraphContext.Account)"
    }

    $MissingScopes = @(
        $GraphScopes |
            Where-Object { $_ -notin @($GraphContext.Scopes) }
    )

    if ($MissingScopes.Count -gt 0) {
        throw "Escopos Graph ausentes: $($MissingScopes -join ', ')"
    }

    $EncodedAdminUPN = [System.Uri]::EscapeDataString($AdminUPN)
    $AdminUser = Invoke-MgGraphRequest `
        -Method GET `
        -Uri (
            '/v1.0/users/' + $EncodedAdminUPN +
            '?$select=id,displayName,userPrincipalName,accountEnabled'
        ) `
        -OutputType PSObject `
        -ErrorAction Stop

    if (-not $AdminUser.accountEnabled) {
        throw "A conta $AdminUPN está desabilitada."
    }

    $Skus = @(
        Get-GraphCollection -Uri '/v1.0/subscribedSkus'
    )

    $RoleAssignments = @(
        Get-GraphCollection -Uri (
            '/v1.0/roleManagement/directory/roleAssignments' +
            '?$filter=principalId%20eq%20%27' +
            [string]$AdminUser.id +
            '%27'
        )
    )

    $RoleDefinitions = @(
        Get-GraphCollection -Uri (
            '/v1.0/roleManagement/directory/roleDefinitions' +
            '?$select=id,displayName'
        )
    )

    $RoleDefinitionMap = @{}
    foreach ($Definition in $RoleDefinitions) {
        $RoleDefinitionMap[[string]$Definition.id] = $Definition
    }

    $Roles = @(
        foreach ($Assignment in $RoleAssignments) {
            $Definition = $RoleDefinitionMap[
                [string]$Assignment.roleDefinitionId
            ]

            [PSCustomObject]@{
                Conta = $AdminUPN
                PrincipalId = $AdminUser.id
                Funcao = if ($Definition) {
                    $Definition.displayName
                }
                else {
                    'Definição não localizada'
                }
                RoleDefinitionId = $Assignment.roleDefinitionId
                RoleAssignmentId = $Assignment.id
                DirectoryScopeId = $Assignment.directoryScopeId
            }
        }
    )

    $LicenseRecords = @(
        foreach ($Sku in $Skus) {
            [PSCustomObject]@{
                SkuPartNumber = $Sku.skuPartNumber
                SkuId = $Sku.skuId
                Capacidade = $Sku.capabilityStatus
                UnidadesAtivas = $Sku.prepaidUnits.enabled
                UnidadesUsadas = $Sku.consumedUnits
                Planos = (
                    @($Sku.servicePlans.servicePlanName) -join '; '
                )
            }
        }
    )

    Export-Utf8Csv -Path $Paths.Roles -InputObject $Roles
    Export-Utf8Csv -Path $Paths.Licenses -InputObject $LicenseRecords

    $PurviewCommands = @(
        'Get-DlpCompliancePolicy',
        'New-DlpCompliancePolicy',
        'Set-DlpCompliancePolicy',
        'Remove-DlpCompliancePolicy',
        'Get-Label',
        'New-Label',
        'Set-Label',
        'Remove-Label',
        'Get-LabelPolicy',
        'New-LabelPolicy',
        'Set-LabelPolicy',
        'Remove-LabelPolicy'
    )

    Write-Host '3. Tentando conectar ao Microsoft Purview...' `
        -ForegroundColor Cyan

    try {
        if ($null -eq $PurviewModule) {
            throw (
                'O módulo ExchangeOnlineManagement não está instalado. ' +
                'O restante da AUTO-20 continuará sem o workload Purview.'
            )
        }

        Import-Module `
            -Name $PurviewModuleName `
            -RequiredVersion $PurviewModule.Version `
            -ErrorAction Stop

        $ConnectPurviewCommand = Get-Command `
            -Name 'Connect-IPPSSession' `
            -ErrorAction SilentlyContinue

        if ($null -eq $ConnectPurviewCommand) {
            throw (
                'Connect-IPPSSession não está disponível no módulo ' +
                'ExchangeOnlineManagement instalado.'
            )
        }

        Connect-IPPSSession `
            -UserPrincipalName $AdminUPN `
            -ShowBanner:$false `
            -DisableWAM `
            -ErrorAction Stop

        $PurviewConnected = $true
        $PurviewConnection = @(
            Get-ConnectionInformation |
                Where-Object {
                    $_.State -eq 'Connected' -and $_.IsEopSession -eq $true
                }
        ) |
            Select-Object -Last 1

        if ($null -eq $PurviewConnection) {
            throw 'Nenhuma sessão Security & Compliance foi identificada.'
        }

        if (-not (Test-TextEquals $PurviewConnection.TenantID $TenantId)) {
            throw "Tenant Purview incorreto: $($PurviewConnection.TenantID)"
        }

        if (
            -not (
                Test-TextEquals `
                    $PurviewConnection.UserPrincipalName `
                    $AdminUPN
            )
        ) {
            throw (
                'Conta Purview incorreta: ' +
                $PurviewConnection.UserPrincipalName
            )
        }

        foreach ($CommandName in $PurviewCommands) {
            $Command = Get-Command `
                -Name $CommandName `
                -ErrorAction SilentlyContinue

            [void]$Capabilities.Add(
                [PSCustomObject]@{
                    Tipo = 'Comando pós-conexão'
                    Nome = $CommandName
                    Disponivel = ($null -ne $Command)
                    Origem = if ($Command) { $Command.Source } else { '' }
                    Versao = if ($Command) {
                        [string]$Command.Version
                    }
                    else {
                        ''
                    }
                }
            )
        }

        $MissingPurviewCommands = @(
            $Capabilities |
                Where-Object {
                    $_.Tipo -eq 'Comando pós-conexão' -and
                    -not $_.Disponivel
                }
        )

        if ($MissingPurviewCommands.Count -gt 0) {
            throw (
                'Comandos Purview indisponíveis para a conta: ' +
                (
                    $MissingPurviewCommands |
                        Select-Object -ExpandProperty Nome
                ) -join ', '
            )
        }

        $PurviewAvailable = $true
    }
    catch {
        $PurviewBlockReason = (
            'Microsoft Purview não validado por ausência de acesso, ' +
            'permissão ou licença funcional. Detalhe técnico: ' +
            $_.Exception.Message
        )

        Write-Warning $PurviewBlockReason

        foreach ($CommandName in $PurviewCommands) {
            [void]$Capabilities.Add(
                [PSCustomObject]@{
                    Tipo = 'Comando pós-conexão'
                    Nome = $CommandName
                    Disponivel = $false
                    Origem = ''
                    Versao = ''
                }
            )
        }

        foreach ($Component in @(
            'Microsoft Purview DLP',
            'Rótulo de sensibilidade',
            'Política de rótulos'
        )) {
            Add-ActionRecord `
                -List $Actions `
                -Componente $Component `
                -Operacao 'Validar acesso' `
                -Status 'Bloqueado' `
                -Detalhe $PurviewBlockReason
        }
    }

    Export-Utf8Csv -Path $Paths.Modules -InputObject @($Capabilities)

    function Read-AllAuto20Configuration {
        $PowerPlatformResponses = @(
            Microsoft.PowerApps.Administration.PowerShell\Get-DlpPolicy `
                -ErrorAction Stop
        )
        $PowerPlatformPolicies = @(
            foreach ($Response in $PowerPlatformResponses) {
                $Value = Get-SafeProperty $Response 'value'
                if ($null -ne $Value) {
                    @($Value)
                }
                else {
                    $Response
                }
            }
        )
        $ConditionalAccessPolicies = @(
            Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
        )
        $PurviewDlpPolicies = @()
        $Labels = @()
        $LabelPolicies = @()

        if ($PurviewAvailable) {
            $PurviewDlpPolicies = @(
                Get-DlpCompliancePolicy -ErrorAction Stop
            )
            $Labels = @(Get-Label -ErrorAction Stop)
            $LabelPolicies = @(Get-LabelPolicy -ErrorAction Stop)
        }

        return [ordered]@{
            PowerPlatformPolicies = $PowerPlatformPolicies
            ConditionalAccessPolicies = $ConditionalAccessPolicies
            PurviewDlpPolicies = $PurviewDlpPolicies
            Labels = $Labels
            LabelPolicies = $LabelPolicies
            Model = Get-Auto20State `
                -PowerPlatformPolicies $PowerPlatformPolicies `
                -ConditionalAccessPolicies $ConditionalAccessPolicies `
                -PurviewDlpPolicies $PurviewDlpPolicies `
                -Labels $Labels `
                -LabelPolicies $LabelPolicies
        }
    }

    Write-Host '4. Registrando configuração anterior...' -ForegroundColor Cyan
    $BeforeState = Read-AllAuto20Configuration
    ConvertTo-SafeJson -Value $BeforeState -Depth 40 |
        Set-Content -LiteralPath $Paths.Before -Encoding UTF8

    if ($Acao -eq 'Consultar') {
        Add-ActionRecord `
            -List $Actions `
            -Componente 'Power Platform e Microsoft Graph' `
            -Operacao 'Consultar' `
            -Status 'Sucesso' `
            -Detalhe (
                'Consultas disponíveis concluídas sem alteração ' +
                'administrativa. Componentes do Purview podem permanecer ' +
                'bloqueados.'
            )
    }

    if ($Acao -eq 'CriarModelo') {
        Write-Host '5. Criando objetos de laboratório...' -ForegroundColor Cyan

        if ($null -eq $BeforeState.Model.PowerPlatformDlp) {
            try {
                Microsoft.PowerApps.Administration.PowerShell\New-DlpPolicy `
                    -DisplayName $PowerPlatformDlpName `
                    -EnvironmentType $PowerPlatformEnvironmentType `
                    -DefaultConnectorClassification 'General' `
                    -ErrorAction Stop |
                    Out-Null

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Power Platform DLP' `
                    -Operacao 'Criar' `
                    -Status 'Sucesso' `
                    -Detalhe (
                        'Política criada. EnvironmentType=' +
                        $PowerPlatformEnvironmentType
                    )
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Power Platform DLP' `
                    -Operacao 'Criar' `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }
        else {
            Add-ActionRecord `
                -List $Actions `
                -Componente 'Power Platform DLP' `
                -Operacao 'Criar' `
                -Status 'Ignorado' `
                -Detalhe 'O objeto de laboratório já existe.'
        }

        if ($null -eq $BeforeState.Model.ConditionalAccess) {
            $ConditionalAccessBody = @{
                DisplayName = $ConditionalAccessName
                State = 'enabledForReportingButNotEnforced'
                Conditions = @{
                    Users = @{
                        IncludeUsers = @([string]$AdminUser.id)
                    }
                    Applications = @{
                        IncludeApplications = @('All')
                    }
                    ClientAppTypes = @('all')
                }
                GrantControls = @{
                    Operator = 'OR'
                    BuiltInControls = @('mfa')
                }
            }

            try {
                New-MgIdentityConditionalAccessPolicy `
                    -BodyParameter $ConditionalAccessBody `
                    -ErrorAction Stop |
                    Out-Null

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Acesso Condicional' `
                    -Operacao 'Criar report-only' `
                    -Status 'Sucesso' `
                    -Detalhe "Escopo restrito à conta $AdminUPN."
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Acesso Condicional' `
                    -Operacao 'Criar report-only' `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }
        else {
            Add-ActionRecord `
                -List $Actions `
                -Componente 'Acesso Condicional' `
                -Operacao 'Criar' `
                -Status 'Ignorado' `
                -Detalhe 'O objeto de laboratório já existe.'
        }

        if ($PurviewAvailable) {
        if ($null -eq $BeforeState.Model.PurviewDlp) {
            try {
                New-DlpCompliancePolicy `
                    -Name $PurviewDlpName `
                    -Comment $Justificativa `
                    -ExchangeLocation All `
                    -Mode TestWithoutNotifications `
                    -ErrorAction Stop |
                    Out-Null

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Microsoft Purview DLP' `
                    -Operacao 'Criar em teste' `
                    -Status 'Sucesso' `
                    -Detalhe (
                        'Política criada para ExchangeLocation=All, sem regras ' +
                        'e em TestWithoutNotifications.'
                    )
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Microsoft Purview DLP' `
                    -Operacao 'Criar em teste' `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }
        else {
            Add-ActionRecord `
                -List $Actions `
                -Componente 'Microsoft Purview DLP' `
                -Operacao 'Criar' `
                -Status 'Ignorado' `
                -Detalhe 'O objeto de laboratório já existe.'
        }

        if ($null -eq $BeforeState.Model.SensitivityLabel) {
            try {
                New-Label `
                    -Name $SensitivityLabelName `
                    -DisplayName 'LAB AUTO-20 - Confidencial' `
                    -Tooltip 'Uso interno - prova controlada AUTO-20' `
                    -Comment $Justificativa `
                    -ErrorAction Stop |
                    Out-Null

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Rótulo de sensibilidade' `
                    -Operacao 'Criar' `
                    -Status 'Sucesso' `
                    -Detalhe 'Rótulo sem criptografia criado para a prova.'
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Rótulo de sensibilidade' `
                    -Operacao 'Criar' `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }
        else {
            Add-ActionRecord `
                -List $Actions `
                -Componente 'Rótulo de sensibilidade' `
                -Operacao 'Criar' `
                -Status 'Ignorado' `
                -Detalhe 'O objeto de laboratório já existe.'
        }

        $CurrentLabels = @(Get-Label -ErrorAction Stop)
        $CurrentLabel = Find-ByName `
            -Items $CurrentLabels `
            -ExpectedName $SensitivityLabelName `
            -Properties @('Name', 'DisplayName')

        $CurrentLabelPolicies = @(Get-LabelPolicy -ErrorAction Stop)
        $CurrentLabelPolicy = Find-ByName `
            -Items $CurrentLabelPolicies `
            -ExpectedName $LabelPolicyName `
            -Properties @('Name')

        if ($null -eq $CurrentLabelPolicy -and $null -ne $CurrentLabel) {
            try {
                New-LabelPolicy `
                    -Name $LabelPolicyName `
                    -Labels $CurrentLabel.Name `
                    -ExchangeLocation $AdminUPN `
                    -Comment $Justificativa `
                    -ErrorAction Stop |
                    Out-Null

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Política de rótulos' `
                    -Operacao 'Criar e publicar' `
                    -Status 'Sucesso' `
                    -Detalhe "Publicação restrita à conta $AdminUPN."
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Política de rótulos' `
                    -Operacao 'Criar e publicar' `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }
        elseif ($null -ne $CurrentLabelPolicy) {
            Add-ActionRecord `
                -List $Actions `
                -Componente 'Política de rótulos' `
                -Operacao 'Criar' `
                -Status 'Ignorado' `
                -Detalhe 'O objeto de laboratório já existe.'
        }
        else {
            Add-ActionRecord `
                -List $Actions `
                -Componente 'Política de rótulos' `
                -Operacao 'Criar' `
                -Status 'Falha' `
                -Detalhe 'O rótulo de laboratório não ficou disponível.'
        }
        }
        else {
            foreach ($Component in @(
                'Microsoft Purview DLP',
                'Rótulo de sensibilidade',
                'Política de rótulos'
            )) {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente $Component `
                    -Operacao 'CriarModelo' `
                    -Status 'Bloqueado' `
                    -Detalhe $PurviewBlockReason
            }
        }
    }

    if ($Acao -in @('HabilitarModelo', 'DesabilitarModelo')) {
        $Current = Read-AllAuto20Configuration
        $Enable = $Acao -eq 'HabilitarModelo'

        if ($null -ne $Current.Model.ConditionalAccess) {
            $TargetState = if ($Enable) { 'enabled' } else { 'disabled' }
            try {
                Update-MgIdentityConditionalAccessPolicy `
                    -ConditionalAccessPolicyId (
                        [string]$Current.Model.ConditionalAccess.Id
                    ) `
                    -BodyParameter @{ State = $TargetState } `
                    -ErrorAction Stop

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Acesso Condicional' `
                    -Operacao $Acao `
                    -Status 'Sucesso' `
                    -Detalhe "State=$TargetState"
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Acesso Condicional' `
                    -Operacao $Acao `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }
        else {
            Add-ActionRecord `
                -List $Actions `
                -Componente 'Acesso Condicional' `
                -Operacao $Acao `
                -Status 'Ignorado' `
                -Detalhe 'Crie o modelo antes de habilitar ou desabilitar.'
        }

        if ($PurviewAvailable) {
        if ($null -ne $Current.Model.PurviewDlp) {
            $TargetMode = if ($Enable) { 'Enable' } else { 'Disable' }
            try {
                Set-DlpCompliancePolicy `
                    -Identity $Current.Model.PurviewDlp.Name `
                    -Mode $TargetMode `
                    -Comment $Justificativa `
                    -ErrorAction Stop

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Microsoft Purview DLP' `
                    -Operacao $Acao `
                    -Status 'Sucesso' `
                    -Detalhe "Mode=$TargetMode"
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Microsoft Purview DLP' `
                    -Operacao $Acao `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }
        else {
            Add-ActionRecord `
                -List $Actions `
                -Componente 'Microsoft Purview DLP' `
                -Operacao $Acao `
                -Status 'Ignorado' `
                -Detalhe 'Crie o modelo antes de habilitar ou desabilitar.'
        }

        if (
            $null -ne $Current.Model.LabelPolicy -and
            $null -ne $Current.Model.SensitivityLabel
        ) {
            try {
                if ($Enable) {
                    Set-LabelPolicy `
                        -Identity $Current.Model.LabelPolicy.Name `
                        -AddLabels $Current.Model.SensitivityLabel.Name `
                        -ErrorAction Stop
                }
                else {
                    Set-LabelPolicy `
                        -Identity $Current.Model.LabelPolicy.Name `
                        -RemoveLabels $Current.Model.SensitivityLabel.Name `
                        -ErrorAction Stop
                }

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Política de rótulos' `
                    -Operacao $Acao `
                    -Status 'Sucesso' `
                    -Detalhe $(
                        if ($Enable) {
                            'Rótulo adicionado à política.'
                        }
                        else {
                            'Rótulo removido da política.'
                        }
                    )
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Política de rótulos' `
                    -Operacao $Acao `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }
        else {
            Add-ActionRecord `
                -List $Actions `
                -Componente 'Política de rótulos' `
                -Operacao $Acao `
                -Status 'Ignorado' `
                -Detalhe 'Rótulo ou política de laboratório não localizado.'
        }
        }
        else {
            foreach ($Component in @(
                'Microsoft Purview DLP',
                'Política de rótulos'
            )) {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente $Component `
                    -Operacao $Acao `
                    -Status 'Bloqueado' `
                    -Detalhe $PurviewBlockReason
            }
        }

        Add-ActionRecord `
            -List $Actions `
            -Componente 'Power Platform DLP' `
            -Operacao $Acao `
            -Status 'Não aplicável' `
            -Detalhe (
                'A política DLP da Power Platform não possui estado ' +
                'habilitado/desabilitado equivalente. Use CriarModelo ou ' +
                'ReverterModelo.'
            )
    }

    if ($Acao -eq 'ReverterModelo') {
        Write-Host '5. Removendo objetos de laboratório...' -ForegroundColor Cyan
        $Current = Read-AllAuto20Configuration

        if ($PurviewAvailable) {
        if ($null -ne $Current.Model.LabelPolicy) {
            try {
                Remove-LabelPolicy `
                    -Identity $Current.Model.LabelPolicy.Name `
                    -Confirm:$false `
                    -ErrorAction Stop

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Política de rótulos' `
                    -Operacao 'Remover' `
                    -Status 'Sucesso' `
                    -Detalhe 'Política de laboratório removida.'
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Política de rótulos' `
                    -Operacao 'Remover' `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }

        Start-Sleep -Seconds 5
        $CurrentLabels = @(Get-Label -ErrorAction Stop)
        $CurrentLabel = Find-ByName `
            -Items $CurrentLabels `
            -ExpectedName $SensitivityLabelName `
            -Properties @('Name', 'DisplayName')

        if ($null -ne $CurrentLabel) {
            try {
                Remove-Label `
                    -Identity $CurrentLabel.Name `
                    -Confirm:$false `
                    -ErrorAction Stop

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Rótulo de sensibilidade' `
                    -Operacao 'Remover' `
                    -Status 'Sucesso' `
                    -Detalhe 'Rótulo de laboratório removido.'
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Rótulo de sensibilidade' `
                    -Operacao 'Remover' `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }

        if ($null -ne $Current.Model.PurviewDlp) {
            try {
                Remove-DlpCompliancePolicy `
                    -Identity $Current.Model.PurviewDlp.Name `
                    -Confirm:$false `
                    -ErrorAction Stop

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Microsoft Purview DLP' `
                    -Operacao 'Remover' `
                    -Status 'Sucesso' `
                    -Detalhe 'Política de laboratório removida.'
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Microsoft Purview DLP' `
                    -Operacao 'Remover' `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }
        }
        else {
            foreach ($Component in @(
                    'Política de rótulos',
                    'Rótulo de sensibilidade',
                    'Microsoft Purview DLP'
            )) {
                    Add-ActionRecord `
                        -List $Actions `
                        -Componente $Component `
                        -Operacao 'ReverterModelo' `
                        -Status 'Bloqueado' `
                        -Detalhe $PurviewBlockReason
            }
        }

        if ($null -ne $Current.Model.ConditionalAccess) {
            try {
                Remove-MgIdentityConditionalAccessPolicy `
                    -ConditionalAccessPolicyId (
                        [string]$Current.Model.ConditionalAccess.Id
                    ) `
                    -ErrorAction Stop

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Acesso Condicional' `
                    -Operacao 'Remover' `
                    -Status 'Sucesso' `
                    -Detalhe 'Política de laboratório removida.'
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Acesso Condicional' `
                    -Operacao 'Remover' `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }

        if ($null -ne $Current.Model.PowerPlatformDlp) {
            try {
                $PolicyIdentifier = Get-SafeProperty `
                    $Current.Model.PowerPlatformDlp `
                    'PolicyName'

                if ([string]::IsNullOrWhiteSpace([string]$PolicyIdentifier)) {
                    $PolicyIdentifier = Get-SafeProperty `
                        $Current.Model.PowerPlatformDlp `
                        'Name'
                }

                if ([string]::IsNullOrWhiteSpace([string]$PolicyIdentifier)) {
                    throw 'O identificador da política não foi retornado.'
                }

                Microsoft.PowerApps.Administration.PowerShell\Remove-DlpPolicy `
                    -PolicyName $PolicyIdentifier `
                    -ErrorAction Stop

                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Power Platform DLP' `
                    -Operacao 'Remover' `
                    -Status 'Sucesso' `
                    -Detalhe 'Política de laboratório removida.'
            }
            catch {
                Add-ActionRecord `
                    -List $Actions `
                    -Componente 'Power Platform DLP' `
                    -Operacao 'Remover' `
                    -Status 'Falha' `
                    -Detalhe $_.Exception.Message
            }
        }
    }

    Write-Host '6. Registrando configuração posterior...' -ForegroundColor Cyan
    Start-Sleep -Seconds 5
    $AfterState = Read-AllAuto20Configuration
    ConvertTo-SafeJson -Value $AfterState -Depth 40 |
        Set-Content -LiteralPath $Paths.After -Encoding UTF8

    Export-Utf8Csv -Path $Paths.Actions -InputObject @($Actions)

    $ContextRecord = [PSCustomObject]@{
        DataInicio = $StartedAt
        DataFim = Get-Date
        TenantIdEsperado = $TenantId
        TenantIdGraph = $GraphContext.TenantId
        ContaEsperada = $AdminUPN
        ContaGraph = $GraphContext.Account
        ContaHabilitada = $AdminUser.accountEnabled
        EscoposGraph = @($GraphContext.Scopes) -join '; '
        FuncoesAtivas = @($Roles.Funcao) -join '; '
        PowerShellVersion = [string]$PSVersionTable.PSVersion
        PowerShellEdition = [string]$PSVersionTable.PSEdition
        PowerPlatformConectado = $PowerPlatformConnected
        PurviewDisponivel = $PurviewAvailable
        PurviewTenant = if ($null -ne $PurviewConnection) {
            $PurviewConnection.TenantID
        }
        else {
            ''
        }
        PurviewConta = if ($null -ne $PurviewConnection) {
            $PurviewConnection.UserPrincipalName
        }
        else {
            ''
        }
        PurviewBloqueio = $PurviewBlockReason
        Acao = $Acao
        ConfirmarAlteracao = [bool]$ConfirmarAlteracao
        Justificativa = $Justificativa
        PastaEvidencias = $EvidenceDirectory
    }

    Export-Utf8Csv -Path $Paths.Context -InputObject @($ContextRecord)

    $ActionFailures = @(
        $Actions | Where-Object { $_.Status -eq 'Falha' }
    )
    $BlockedActions = @(
        $Actions | Where-Object { $_.Status -eq 'Bloqueado' }
    )

    $ExpectedState = switch ($Acao) {
        'Consultar' {
            'Consulta concluída; configuração antes e depois equivalente.'
        }
        'CriarModelo' {
            if ($PurviewAvailable) {
                'Objetos LAB-AUTO20 existentes; CA em report-only; DLP Purview em teste.'
            }
            else {
                'Power Platform e CA testados; componentes Purview bloqueados e preservados no código.'
            }
        }
        'HabilitarModelo' {
            if ($PurviewAvailable) {
                'CA enabled; DLP Purview Enable; rótulo publicado para a conta de teste.'
            }
            else {
                'CA habilitado; componentes Purview não executados por dependência externa.'
            }
        }
        'DesabilitarModelo' {
            if ($PurviewAvailable) {
                'CA disabled; DLP Purview Disable; rótulo removido da política de teste.'
            }
            else {
                'CA desabilitado; componentes Purview não executados por dependência externa.'
            }
        }
        'ReverterModelo' {
            if ($PurviewAvailable) {
                'Nenhum objeto LAB-AUTO20 localizado após a reversão.'
            }
            else {
                'Objetos disponíveis revertidos; componentes Purview não verificados.'
            }
        }
    }

    $Summary = [ordered]@{
        AutomationId = 'AUTO-20'
        AutomationName = (
            'DLP, acesso condicional e rótulo de sensibilidade como modelo'
        )
        DataInicio = $StartedAt
        DataFim = Get-Date
        Tenant = $TenantId
        Conta = $AdminUPN
        Acao = $Acao
        Justificativa = $Justificativa
        PurviewDisponivel = $PurviewAvailable
        PurviewBloqueio = $PurviewBlockReason
        ResultadoEsperado = $ExpectedState
        QualityGate = if ($ActionFailures.Count -gt 0) {
            'Parcial - falha técnica'
        }
        elseif ($BlockedActions.Count -gt 0) {
            'Parcial - dependência de licença ou acesso'
        }
        else {
            'Aprovado'
        }
        Falhas = @($ActionFailures)
        DependenciasBloqueadas = @($BlockedActions)
        Acoes = @($Actions)
        Evidencias = $Paths
        Observacoes = @(
            'New-DlpPolicy pertence à Power Platform.',
            'New-DlpCompliancePolicy pertence ao Microsoft Purview.',
            (
                'AllEnvironments veio da hipótese do item; confirme o valor ' +
                'aceito pela versão instalada do módulo se a criação falhar.'
            ),
            (
                'A política de Acesso Condicional nasce em report-only e ' +
                'é restrita à conta administrativa informada.'
            ),
            (
                'A política DLP do Purview é criada sem regra; a prova cobre ' +
                'o ciclo administrativo da política, não detecção de conteúdo.'
            ),
            (
                'A distribuição de DLP e rótulos é assíncrona e pode não ser ' +
                'imediata nos aplicativos.'
            ),
            (
                'A ausência de acesso ao Purview não interrompe os testes de ' +
                'Power Platform e Acesso Condicional; os componentes ' +
                'dependentes permanecem marcados como Bloqueado.'
            )
        )
    }

    ConvertTo-SafeJson -Value $Summary -Depth 40 |
        Set-Content -LiteralPath $Paths.Summary -Encoding UTF8

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' AUTO-20 - RESULTADO'
    Write-Host " Quality Gate: $($Summary.QualityGate)"
    Write-Host " Evidências: $EvidenceDirectory"
    Write-Host '============================================================'

    @($Actions) |
        Format-Table Componente, Operacao, Status, Detalhe -AutoSize
}
catch {
    $FatalError = $_.Exception.Message
    Write-Host ''
    Write-Host 'A AUTO-20 foi interrompida.' -ForegroundColor Red
    Write-Host "Resumo: $FatalError" -ForegroundColor Red

    try {
        Export-Utf8Csv -Path $Paths.Actions -InputObject @($Actions)

        [ordered]@{
            AutomationId = 'AUTO-20'
            DataInicio = $StartedAt
            DataFim = Get-Date
            Tenant = $TenantId
            Conta = $AdminUPN
            Acao = $Acao
            QualityGate = 'Reprovado'
            ErroFatal = $FatalError
            Acoes = @($Actions)
            Evidencias = $Paths
        } |
            ConvertTo-Json -Depth 40 |
            Set-Content -LiteralPath $Paths.Summary -Encoding UTF8
    }
    catch {
        Write-Warning 'Não foi possível concluir o resumo de falha.'
    }

    throw
}
finally {
    if ($GraphConnected) {
        try {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Write-Warning 'Não foi possível encerrar a sessão Graph.'
        }
    }

    if ($PurviewConnected) {
        try {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warning 'Não foi possível encerrar a sessão Purview.'
        }
    }

    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }
}
