<#
# VERSÃO: 8.0
# OBJETIVO:
# Validar e operar, de forma controlada, uma política do Microsoft Edge no
# Microsoft Intune para direcionar HomepageLocation e NewTabPageLocation ao
# Microsoft Copilot.
#
# FERRAMENTA:
# PowerShell 7, Microsoft.Graph.Authentication e Microsoft Graph beta.
#
# PERMISSÃO:
# Consulta: DeviceManagementConfiguration.Read.All, Organization.Read.All,
# User.Read.All, LicenseAssignment.Read.All, RoleManagement.Read.Directory e
# Group.Read.All.
# Alteração: DeviceManagementConfiguration.ReadWrite.All.
#
# LICENÇA:
# O script inventaria os planos do tenant e da conta e valida funcionalmente
# o endpoint deviceManagement/configurationPolicies.
#
# EFEITO:
# Consultar e Previsualizar não alteram o ambiente.
# CriarPiloto cria a política sem atribuição e é idempotente.
# AtribuirPiloto atribui somente ao grupo piloto informado.
# Desabilitar remove todas as atribuições, preservando a política.
# Reverter exclui somente a política LAB-AUTO26 controlada.
#
# RECURSO-ALVO:
# Settings Catalog, Windows 10/11, Microsoft Edge, HomepageLocation e
# NewTabPageLocation.
#
# PARÂMETROS EDITÁVEIS:
# Acao, TenantIdEsperado, ContaEsperada, CopilotUrl, GrupoPilotoId,
# PolicyIdConhecido, NomePolitica, Justificativa e EvidenceRoot.
#
# EVIDÊNCIAS:
# execucao.log, contexto.csv, modulos-comandos.csv,
# funcoes-administrativas.csv, licencas-tenant.csv, licencas-conta.csv,
# definicoes-configuracao.csv, configuracao-antes/depois.json e .csv,
# atribuicoes-antes/depois.json, corpo-proposto.json, acoes.csv, resumo.csv,
# erros.csv quando aplicável e referencia-politica.json.
#
# RISCOS:
# A atribuição altera a experiência do Edge no grupo piloto. Reverter exclui a
# política. O script nunca exclui grupos, usuários ou dispositivos.
#
# ATENÇÃO:
# Execute Consultar e Previsualizar antes de atribuir. Use grupo e dispositivos
# dedicados ao laboratório. HomepageLocation e NewTabPageLocation não controlam
# isoladamente a página aberta na inicialização do Edge.
#>

[CmdletBinding()]
param(
    [ValidateSet('Consultar','Previsualizar','CriarPiloto','AtribuirPiloto','Desabilitar','Reverter')]
    [string]$Acao = 'Consultar',
    [string]$TenantIdEsperado = 'd7935522-6fc7-408d-8633-e4109183c63f',
    [string]$ContaEsperada = 'admin@m365mcp79922602.onmicrosoft.com',
    [string]$CopilotUrl = '',
    [string]$GrupoPilotoId = '',
    [string]$PolicyIdConhecido = '',
    [string]$NomePolitica = 'LAB-AUTO26-Edge-M365-Copilot',
    [switch]$ConfirmarAlteracao,
    [string]$ConfirmacaoRisco = '',
    [string]$Justificativa = '',
    [string]$EvidenceRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$AutomationId = 'AUTO-26'
$AutomationName = 'Navegadores abrindo no M365 Copilot'
$PolicyEndpoint = '/beta/deviceManagement/configurationPolicies'
$DefinitionsEndpoint = '/beta/deviceManagement/configurationSettings'
$ChangeActions = @('CriarPiloto','AtribuirPiloto','Desabilitar','Reverter')
$ReadScopes = @('DeviceManagementConfiguration.Read.All','Organization.Read.All','User.Read.All','LicenseAssignment.Read.All','RoleManagement.Read.Directory','Group.Read.All')
$WriteScopes = @('DeviceManagementConfiguration.ReadWrite.All','Organization.Read.All','User.Read.All','LicenseAssignment.Read.All','RoleManagement.Read.Directory','Group.Read.All')
$AcceptedRoles = @('Global Administrator','Intune Administrator')
$EdgeDefinitionIds = [ordered]@{
    HomepageParent = 'device_vendor_msft_policy_config_microsoft_edge~policy~microsoft_edge~startup_homepagelocation'
    HomepageChild  = 'device_vendor_msft_policy_config_microsoft_edge~policy~microsoft_edge~startup_homepagelocation_homepagelocation'
    NewTabParent   = 'device_vendor_msft_policy_config_microsoft_edge~policy~microsoft_edge~startup_newtabpagelocation'
    NewTabChild    = 'device_vendor_msft_policy_config_microsoft_edge~policy~microsoft_edge~startup_newtabpagelocation_newtabpagelocation'
}

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { throw 'Salve e execute como arquivo .ps1.' }
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = Join-Path $PSScriptRoot 'evidencias' }
$AutomationEvidenceRoot = Join-Path $EvidenceRoot 'AUTO-26-Navegadores-M365-Copilot'
$PolicyReferencePath = Join-Path $AutomationEvidenceRoot 'referencia-politica.json'

$Parsed = [Guid]::Empty
if (-not [Guid]::TryParse($TenantIdEsperado,[ref]$Parsed)) { throw 'TenantIdEsperado inválido.' }
if ($ContaEsperada -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'ContaEsperada inválida.' }
if ($NomePolitica -notlike 'LAB-AUTO26-*') { throw 'NomePolitica deve começar com LAB-AUTO26-.' }
foreach ($Item in @(@{N='GrupoPilotoId';V=$GrupoPilotoId},@{N='PolicyIdConhecido';V=$PolicyIdConhecido})) {
    if (-not [string]::IsNullOrWhiteSpace($Item.V)) {
        $G = [Guid]::Empty
        if (-not [Guid]::TryParse($Item.V,[ref]$G)) { throw "$($Item.N) inválido." }
    }
}
if ($Acao -ne 'Consultar') {
    $UriValue = $null
    if ([string]::IsNullOrWhiteSpace($CopilotUrl) -or -not [Uri]::TryCreate($CopilotUrl,[UriKind]::Absolute,[ref]$UriValue) -or $UriValue.Scheme -ne 'https') {
        throw 'Informe CopilotUrl como URL HTTPS absoluta.'
    }
}
if ($Acao -in $ChangeActions) {
    if (-not $ConfirmarAlteracao) { throw "A ação '$Acao' exige -ConfirmarAlteracao." }
    if ([string]::IsNullOrWhiteSpace($Justificativa)) { throw "A ação '$Acao' exige -Justificativa." }
}
if ($Acao -eq 'AtribuirPiloto') {
    if ([string]::IsNullOrWhiteSpace($GrupoPilotoId)) { throw 'AtribuirPiloto exige GrupoPilotoId.' }
    if ($ConfirmacaoRisco -cne 'ATRIBUIR-AUTO26-GRUPO-PILOTO') { throw "Use -ConfirmacaoRisco 'ATRIBUIR-AUTO26-GRUPO-PILOTO'." }
}
if ($Acao -eq 'Reverter' -and $ConfirmacaoRisco -cne 'REMOVER-POLITICA-AUTO26') { throw "Use -ConfirmacaoRisco 'REMOVER-POLITICA-AUTO26'." }

$StartedAt = Get-Date
$EvidenceDirectory = Join-Path $AutomationEvidenceRoot ($StartedAt.ToString('yyyyMMdd-HHmmss') + '-' + $Acao)
New-Item -Path $EvidenceDirectory -ItemType Directory -Force | Out-Null
$Paths = [ordered]@{
    Log=Join-Path $EvidenceDirectory 'execucao.log'; Context=Join-Path $EvidenceDirectory 'contexto.csv'
    Commands=Join-Path $EvidenceDirectory 'modulos-comandos.csv'; Roles=Join-Path $EvidenceDirectory 'funcoes-administrativas.csv'
    TenantLicenses=Join-Path $EvidenceDirectory 'licencas-tenant.csv'; AccountLicenses=Join-Path $EvidenceDirectory 'licencas-conta.csv'
    Definitions=Join-Path $EvidenceDirectory 'definicoes-configuracao.csv'; BeforeJson=Join-Path $EvidenceDirectory 'configuracao-antes.json'
    BeforeCsv=Join-Path $EvidenceDirectory 'configuracao-antes.csv'; AssignmentsBefore=Join-Path $EvidenceDirectory 'atribuicoes-antes.json'
    Proposed=Join-Path $EvidenceDirectory 'corpo-proposto.json'; Actions=Join-Path $EvidenceDirectory 'acoes.csv'
    AfterJson=Join-Path $EvidenceDirectory 'configuracao-depois.json'; AfterCsv=Join-Path $EvidenceDirectory 'configuracao-depois.csv'
    AssignmentsAfter=Join-Path $EvidenceDirectory 'atribuicoes-depois.json'; Summary=Join-Path $EvidenceDirectory 'resumo.csv'
    Errors=Join-Path $EvidenceDirectory 'erros.csv'; Checklist=Join-Path $EvidenceDirectory 'checklist-validacao-cliente.txt'
}
Start-Transcript -Path $Paths.Log -Force | Out-Null
$Connected = $false; $Completed = $false
$Actions = [System.Collections.Generic.List[object]]::new(); $Errors = [System.Collections.Generic.List[object]]::new()

function Get-SafeProperty([object]$InputObject,[string]$Name,[object]$DefaultValue=$null) {
    if ($null -eq $InputObject) { return $DefaultValue }
    $P = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $P) { return $DefaultValue }
    return $P.Value
}
function Test-PropertyExists([object]$InputObject,[string]$Name) {
    return ($null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name])
}
function Invoke-GraphCollection([string]$Uri) {
    $Items = [System.Collections.Generic.List[object]]::new(); $NextUri = $Uri
    while (-not [string]::IsNullOrWhiteSpace($NextUri)) {
        $Response = Invoke-MgGraphRequest -Method GET -Uri $NextUri -OutputType PSObject -ErrorAction Stop
        if (Test-PropertyExists -InputObject $Response -Name 'value') {
            $ValueProperty = $Response.PSObject.Properties['value']
            foreach ($Entry in @($ValueProperty.Value)) { if ($null -ne $Entry) { $Items.Add($Entry) } }
        } elseif ($null -ne $Response) { $Items.Add($Response) }
        $NextUri = [string](Get-SafeProperty -InputObject $Response -Name '@odata.nextLink' -DefaultValue '')
    }
    return @($Items)
}
function Add-Action([string]$Etapa,[string]$Operacao,[string]$Resultado,[string]$Detalhe='') {
    $Actions.Add([PSCustomObject]@{DataHoraUtc=(Get-Date).ToUniversalTime().ToString('o');Etapa=$Etapa;Operacao=$Operacao;Resultado=$Resultado;Detalhe=$Detalhe})
}
function Add-ErrorEvidence([string]$Etapa,[string]$Mensagem) {
    $Errors.Add([PSCustomObject]@{DataHoraUtc=(Get-Date).ToUniversalTime().ToString('o');Etapa=$Etapa;Mensagem=$Mensagem})
}
function Export-EvidenceCsv([string]$Path,[AllowEmptyCollection()][object[]]$InputObject=@()) {
    $Rows=@($InputObject)
    if ($Rows.Count -eq 0) { [PSCustomObject]@{Resultado='Nenhum registro'} | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8 }
    else { $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8 }
}
function Save-Json([string]$Path,[AllowNull()][object]$InputObject) {
    if ($null -eq $InputObject) { 'null' | Set-Content -LiteralPath $Path -Encoding utf8 }
    else { $InputObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8 }
}
function Get-SavedPolicyId {
    if (-not (Test-Path -LiteralPath $PolicyReferencePath)) { return '' }
    try { return [string]((Get-Content -LiteralPath $PolicyReferencePath -Raw | ConvertFrom-Json).PolicyId) } catch { return '' }
}
function Save-PolicyReference([string]$PolicyId) {
    New-Item -Path $AutomationEvidenceRoot -ItemType Directory -Force | Out-Null
    [PSCustomObject]@{AutomationId=$AutomationId;PolicyId=$PolicyId;PolicyName=$NomePolitica;SavedAtUtc=(Get-Date).ToUniversalTime().ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath $PolicyReferencePath -Encoding utf8
}
function Resolve-Policy([string]$PreferredPolicyId='') {
    if (-not [string]::IsNullOrWhiteSpace($PreferredPolicyId)) {
        try { return Invoke-MgGraphRequest -Method GET -Uri "$PolicyEndpoint/$PreferredPolicyId" -OutputType PSObject -ErrorAction Stop }
        catch { if ($_.Exception.Message -notmatch '404|Not Found') { throw } }
    }
    $PolicyMatches=@(Invoke-GraphCollection -Uri "${PolicyEndpoint}?`$top=100" | Where-Object { [string](Get-SafeProperty $_ 'name' '') -eq $NomePolitica })
    if ($PolicyMatches.Count -gt 1) { throw 'Foram encontradas políticas duplicadas.' }
    if ($PolicyMatches.Count -eq 1) { return $PolicyMatches[0] }
    return $null
}
function Get-PolicySnapshot([AllowNull()][object]$Policy) {
    if ($null -eq $Policy) { return [PSCustomObject]@{Policy=$null;Settings=@();Assignments=@()} }
    $Id=[string](Get-SafeProperty $Policy 'id' '')
    return [PSCustomObject]@{Policy=$Policy;Settings=@(Invoke-GraphCollection "$PolicyEndpoint/$Id/settings");Assignments=@(Invoke-GraphCollection "$PolicyEndpoint/$Id/assignments")}
}
function Get-Definition([string]$Id) {
    $Encoded=[Uri]::EscapeDataString($Id)
    return Invoke-MgGraphRequest -Method GET -Uri "$DefinitionsEndpoint/$Encoded" -OutputType PSObject -ErrorAction Stop
}
function New-EdgeTextSetting([string]$ParentId,[string]$ChildId,[string]$Value) {
    return @{'@odata.type'='#microsoft.graph.deviceManagementConfigurationSetting';settingInstance=@{
        '@odata.type'='#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance';settingDefinitionId=$ParentId;choiceSettingValue=@{
            '@odata.type'='#microsoft.graph.deviceManagementConfigurationChoiceSettingValue';value="${ParentId}_1";children=@(@{
                '@odata.type'='#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance';settingDefinitionId=$ChildId;simpleSettingValue=@{
                    '@odata.type'='#microsoft.graph.deviceManagementConfigurationStringSettingValue';value=$Value
                }
            })
        }
    }}
}
function Convert-SettingsToEvidence([object[]]$Settings=@()) {
    $Rows=[System.Collections.Generic.List[object]]::new()
    foreach($Setting in $Settings) {
        $I=Get-SafeProperty $Setting 'settingInstance'; if($null -eq $I){continue}
        $Id=[string](Get-SafeProperty $Setting 'id' ''); $Def=[string](Get-SafeProperty $I 'settingDefinitionId' ''); $Type=[string](Get-SafeProperty $I '@odata.type' '')
        $Choice=Get-SafeProperty $I 'choiceSettingValue'
        if($null -ne $Choice) {
            $Rows.Add([PSCustomObject]@{SettingId=$Id;SettingDefinitionId=$Def;TipoInstancia=$Type;Valor=[string](Get-SafeProperty $Choice 'value' '');Nivel='Escolha'})
            foreach($Child in @(Get-SafeProperty $Choice 'children' @())) {
                $SV=Get-SafeProperty $Child 'simpleSettingValue'
                $Rows.Add([PSCustomObject]@{SettingId=$Id;SettingDefinitionId=[string](Get-SafeProperty $Child 'settingDefinitionId' '');TipoInstancia=[string](Get-SafeProperty $Child '@odata.type' '');Valor=[string](Get-SafeProperty $SV 'value' '');Nivel='Filho'})
            }
        }
    }
    return @($Rows)
}
function Get-AssignedGroupIds([object[]]$Assignments=@()) {
    return @(foreach($A in $Assignments){$T=Get-SafeProperty $A 'target';$G=[string](Get-SafeProperty $T 'groupId' '');if($G){$G}})
}

try {
    if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) { throw 'Execute no PowerShell 7.' }
    $Required=@('Connect-MgGraph','Disconnect-MgGraph','Get-MgContext','Invoke-MgGraphRequest')
    $CommandEvidence = @(
        foreach ($N in $Required) {
            $C = Get-Command $N -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                Comando = $N
                Disponivel = ($null -ne $C)
                Tipo = if ($C) { $C.CommandType } else { 'Não encontrado' }
                Modulo = if ($C) { $C.ModuleName } else { 'Não encontrado' }
                VersaoModulo = if ($C -and $C.Module) { [string]$C.Module.Version } else { '' }
            }
        }
    )
    Export-EvidenceCsv $Paths.Commands $CommandEvidence
    if(@($CommandEvidence|Where-Object Disponivel -eq $false).Count -gt 0){throw 'Comandos Graph ausentes.'}
    if(Get-MgContext -ErrorAction SilentlyContinue){Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null}
    $RequestedScopes = if ($Acao -in $ChangeActions) { $WriteScopes } else { $ReadScopes }
    Connect-MgGraph -TenantId $TenantIdEsperado -Scopes $RequestedScopes -ContextScope Process -UseDeviceCode -NoWelcome -ErrorAction Stop
    $Connected=$true; $Context=Get-MgContext
    if($Context.TenantId-ne$TenantIdEsperado){throw 'Tenant diferente do esperado.'}
    if(-not [string]::Equals([string]$Context.Account,$ContaEsperada,[StringComparison]::OrdinalIgnoreCase)){throw 'Conta diferente da esperada.'}
    $ActiveScopes=@($Context.Scopes);$MissingScopes=@($RequestedScopes|Where-Object{$_-notin$ActiveScopes});if($MissingScopes.Count){throw 'Escopos ausentes: '+($MissingScopes-join', ')}
    $UPN=[Uri]::EscapeDataString($ContaEsperada)
    $Admin=Invoke-MgGraphRequest -Method GET -Uri "/v1.0/users/${UPN}?`$select=id,userPrincipalName,accountEnabled" -OutputType PSObject
    $AdminId=[string](Get-SafeProperty $Admin 'id' '');if(-not [bool](Get-SafeProperty $Admin 'accountEnabled' $false)){throw 'Conta desabilitada.'}
    $RoleAssignments=@(Invoke-GraphCollection "/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$AdminId'&`$expand=roleDefinition")
    $RoleEvidence=@(foreach($A in $RoleAssignments){$R=Get-SafeProperty $A 'roleDefinition';[PSCustomObject]@{Conta=$ContaEsperada;PrincipalId=$AdminId;Funcao=[string](Get-SafeProperty $R 'displayName' '');RoleDefinitionId=[string](Get-SafeProperty $A 'roleDefinitionId' '');RoleAssignmentId=[string](Get-SafeProperty $A 'id' '')}})
    Export-EvidenceCsv $Paths.Roles $RoleEvidence
    $ActiveRoles=@($RoleEvidence.Funcao);$HasRole=@($AcceptedRoles|Where-Object{$_-in$ActiveRoles}).Count-gt0;if(-not$HasRole){throw 'Função administrativa aceita não encontrada.'}
    $Skus=@(Invoke-GraphCollection '/v1.0/subscribedSkus')
    $TenantLic=@(foreach($S in $Skus){foreach($P in @(Get-SafeProperty $S 'servicePlans' @())){[PSCustomObject]@{SkuPartNumber=[string](Get-SafeProperty $S 'skuPartNumber' '');SkuId=[string](Get-SafeProperty $S 'skuId' '');Capacidade=[string](Get-SafeProperty $S 'capabilityStatus' '');ServicePlanName=[string](Get-SafeProperty $P 'servicePlanName' '');ProvisioningStatus=[string](Get-SafeProperty $P 'provisioningStatus' '');IndicadorIntune=([string](Get-SafeProperty $P 'servicePlanName' '')-match'INTUNE')}}})
    Export-EvidenceCsv $Paths.TenantLicenses $TenantLic
    $LicDetails=@(Invoke-GraphCollection "/v1.0/users/$AdminId/licenseDetails")
    $AccountLic=@(foreach($L in $LicDetails){foreach($P in @(Get-SafeProperty $L 'servicePlans' @())){[PSCustomObject]@{Conta=$ContaEsperada;SkuPartNumber=[string](Get-SafeProperty $L 'skuPartNumber' '');ServicePlanName=[string](Get-SafeProperty $P 'servicePlanName' '');ProvisioningStatus=[string](Get-SafeProperty $P 'provisioningStatus' '');IndicadorIntune=([string](Get-SafeProperty $P 'servicePlanName' '')-match'INTUNE')}}})
    Export-EvidenceCsv $Paths.AccountLicenses $AccountLic
    $null=Invoke-MgGraphRequest -Method GET -Uri "${PolicyEndpoint}?`$top=1" -OutputType PSObject
    Add-Action 'PreRequisitos' 'Consultar configurationPolicies' 'Sucesso' 'A superfície do Intune respondeu sem erro.'
    $Definitions=@(Get-Definition $EdgeDefinitionIds.HomepageParent;Get-Definition $EdgeDefinitionIds.HomepageChild;Get-Definition $EdgeDefinitionIds.NewTabParent;Get-Definition $EdgeDefinitionIds.NewTabChild)
    $DefinitionEvidence=@(foreach($D in $Definitions){[PSCustomObject]@{Id=[string](Get-SafeProperty $D 'id' '');Nome=[string](Get-SafeProperty $D 'name' '');DisplayName=[string](Get-SafeProperty $D 'displayName' '');Descricao=[string](Get-SafeProperty $D 'description' '');Tipo=[string](Get-SafeProperty $D '@odata.type' '')}})
    Export-EvidenceCsv $Paths.Definitions $DefinitionEvidence
    $SavedId=Get-SavedPolicyId;$EffectiveId=if($PolicyIdConhecido){$PolicyIdConhecido}elseif($SavedId){$SavedId}else{''}
    $PilotGroup=$null
    if($GrupoPilotoId){$PilotGroup=Invoke-MgGraphRequest -Method GET -Uri "/v1.0/groups/${GrupoPilotoId}?`$select=id,displayName,securityEnabled" -OutputType PSObject;if(-not[bool](Get-SafeProperty $PilotGroup 'securityEnabled' $false)){throw 'Grupo piloto não é grupo de segurança.'}}
    [PSCustomObject]@{AutomationId=$AutomationId;DataInicioUtc=$StartedAt.ToUniversalTime().ToString('o');Acao=$Acao;TenantIdEsperado=$TenantIdEsperado;TenantIdAutenticado=$Context.TenantId;ContaEsperada=$ContaEsperada;ContaAutenticada=$Context.Account;PrincipalId=$AdminId;FuncoesAtivas=($ActiveRoles-join'; ');EscoposSolicitados=($RequestedScopes-join'; ');EscoposAtivos=($ActiveScopes-join'; ');PolicyIdParametro=$PolicyIdConhecido;PolicyIdReferenciaLocal=$SavedId;PolicyIdEfetivo=$EffectiveId;NomePolitica=$NomePolitica;CopilotUrl=$CopilotUrl;GrupoPilotoId=$GrupoPilotoId;HomepageDefinitionId=$EdgeDefinitionIds.HomepageChild;NewTabDefinitionId=$EdgeDefinitionIds.NewTabChild;ConfirmarAlteracao=[bool]$ConfirmarAlteracao;Justificativa=$Justificativa;PastaEvidencias=$EvidenceDirectory}|Export-Csv $Paths.Context -NoTypeInformation -Encoding utf8
    $PolicyBefore=Resolve-Policy $EffectiveId
    if($PolicyBefore){$EffectiveId=[string](Get-SafeProperty $PolicyBefore 'id' '');Save-PolicyReference $EffectiveId}
    $Before=Get-PolicySnapshot $PolicyBefore;Save-Json $Paths.BeforeJson $Before;Export-EvidenceCsv $Paths.BeforeCsv @(Convert-SettingsToEvidence $Before.Settings);Save-Json $Paths.AssignmentsBefore $Before.Assignments
    $Body=$null
    if($Acao-ne'Consultar'){$Body=@{name=$NomePolitica;description='AUTO-26 - política piloto controlada do Microsoft Edge.';platforms='windows10';technologies='mdm';roleScopeTagIds=@('0');settings=@(New-EdgeTextSetting $EdgeDefinitionIds.HomepageParent $EdgeDefinitionIds.HomepageChild $CopilotUrl;New-EdgeTextSetting $EdgeDefinitionIds.NewTabParent $EdgeDefinitionIds.NewTabChild $CopilotUrl)}}
    Save-Json $Paths.Proposed $Body
    switch($Acao){
        'Consultar'{Add-Action 'Acao' 'Consultar' 'Sucesso' 'Nenhuma alteração executada.'}
        'Previsualizar'{Add-Action 'Acao' 'Previsualizar' 'Sucesso' 'Corpo proposto gerado.'}
        'CriarPiloto'{
            if($PolicyBefore){Add-Action 'Acao' 'CriarPiloto' 'Ignorado' "Política já existente: $EffectiveId"}
            else{$Created=Invoke-MgGraphRequest -Method POST -Uri $PolicyEndpoint -Body ($Body|ConvertTo-Json -Depth 30) -ContentType 'application/json' -OutputType PSObject;$EffectiveId=[string](Get-SafeProperty $Created 'id' '');if(-not$EffectiveId){throw 'Criação sem ID.'};Save-PolicyReference $EffectiveId;Add-Action 'Acao' 'CriarPiloto' 'Sucesso' "Política criada: $EffectiveId"}
        }
        'AtribuirPiloto'{$Assign=@{assignments=@(@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationPolicyAssignment';target=@{'@odata.type'='#microsoft.graph.groupAssignmentTarget';groupId=$GrupoPilotoId}})};$null=Invoke-MgGraphRequest -Method POST -Uri "$PolicyEndpoint/$EffectiveId/assign" -Body ($Assign|ConvertTo-Json -Depth 20) -ContentType 'application/json';Add-Action 'Acao' 'AtribuirPiloto' 'Sucesso' "Grupo atribuído: $GrupoPilotoId"}
        'Desabilitar'{$null=Invoke-MgGraphRequest -Method POST -Uri "$PolicyEndpoint/$EffectiveId/assign" -Body (@{assignments=@()}|ConvertTo-Json) -ContentType 'application/json';Add-Action 'Acao' 'Desabilitar' 'Sucesso' 'Atribuições removidas.'}
        'Reverter' {
            if ($PolicyBefore) {
                $null = Invoke-MgGraphRequest -Method DELETE -Uri "$PolicyEndpoint/$EffectiveId"
                if (Test-Path -LiteralPath $PolicyReferencePath) {
                    Remove-Item -LiteralPath $PolicyReferencePath -Force
                }
                Add-Action 'Acao' 'Reverter' 'Sucesso' "Política removida: $EffectiveId"
            } else {
                Add-Action 'Acao' 'Reverter' 'Ignorado' 'Política já ausente.'
            }
        }
    }
    $PolicyAfter=Resolve-Policy $EffectiveId;$After=Get-PolicySnapshot $PolicyAfter;Save-Json $Paths.AfterJson $After;$Rows=@(Convert-SettingsToEvidence $After.Settings);Export-EvidenceCsv $Paths.AfterCsv $Rows;Save-Json $Paths.AssignmentsAfter $After.Assignments
    $Exists = ($null -ne $PolicyAfter)
    $HomepageRows = @($Rows | Where-Object { $_.SettingDefinitionId -eq $EdgeDefinitionIds.HomepageChild })
    $NewTabRows = @($Rows | Where-Object { $_.SettingDefinitionId -eq $EdgeDefinitionIds.NewTabChild })
    $HomepageMatches = (-not [string]::IsNullOrWhiteSpace($CopilotUrl) -and $HomepageRows.Count -eq 1 -and $HomepageRows[0].Valor -eq $CopilotUrl)
    $NewTabMatches = (-not [string]::IsNullOrWhiteSpace($CopilotUrl) -and $NewTabRows.Count -eq 1 -and $NewTabRows[0].Valor -eq $CopilotUrl)
    $GroupIds = @(Get-AssignedGroupIds $After.Assignments)
    $PilotOk = (-not [string]::IsNullOrWhiteSpace($GrupoPilotoId) -and $GrupoPilotoId -in $GroupIds)
    $AssignCount = @($After.Assignments).Count
    switch($Acao){
        'Consultar'{$Gate='Aprovado - consulta concluída';$Detail=if($Exists){"Política localizada; atribuições: $AssignCount."}else{'Política controlada ainda não existe.'}}
        'Previsualizar'{$Gate='Aprovado - previsualização';$Detail='Corpo proposto gerado sem alteração.'}
        'CriarPiloto' {
            if ($Exists -and $HomepageMatches -and $NewTabMatches -and $AssignCount -eq 0) {
                $Gate = 'Aprovado'
                $Detail = 'Política criada ou já existente, com valores corretos e sem atribuição.'
            } else { $Gate = 'Reprovado'; $Detail = 'Estado posterior diferente do esperado.' }
        }
        'AtribuirPiloto' {
            if ($Exists -and $HomepageMatches -and $NewTabMatches -and $PilotOk) {
                $Gate = 'Aprovado tecnicamente - validar cliente'
                $Detail = 'Atribuição confirmada; falta validar o Edge.'
            } else { $Gate = 'Reprovado'; $Detail = 'Atribuição ou valores divergentes.' }
        }
        'Desabilitar' {
            if ($Exists -and $AssignCount -eq 0) {
                $Gate = 'Aprovado'; $Detail = 'Política preservada sem atribuições.'
            } else { $Gate = 'Reprovado'; $Detail = 'Ainda existem atribuições.' }
        }
        'Reverter'{if(-not$Exists){$Gate='Aprovado';$Detail='Política controlada removida.'}else{$Gate='Reprovado';$Detail='A política ainda existe.'}}
    }
    @" 
AUTO-26 - VALIDAÇÃO NO DISPOSITIVO PILOTO
1. Sincronize o dispositivo pelo Intune e pelo Windows.
2. Abra edge://policy e selecione Recarregar políticas.
3. Confirme HomepageLocation e NewTabPageLocation com $CopilotUrl.
4. Abra nova guia e use o botão Página Inicial.
5. Salve capturas nesta pasta de evidências.
"@|Set-Content $Paths.Checklist -Encoding utf8
    Export-EvidenceCsv $Paths.Actions @($Actions)
    [PSCustomObject]@{AutomationId=$AutomationId;AutomationName=$AutomationName;Acao=$Acao;DataInicioUtc=$StartedAt.ToUniversalTime().ToString('o');DataFimUtc=(Get-Date).ToUniversalTime().ToString('o');TenantValidado=($Context.TenantId-eq$TenantIdEsperado);ContaValidada=[string]::Equals([string]$Context.Account,$ContaEsperada,[StringComparison]::OrdinalIgnoreCase);EscoposValidados=($MissingScopes.Count-eq0);FuncaoAdministrativaValidada=$HasRole;ConsultaIntuneValidada=$true;PolicyExistsAfter=$Exists;HomepageLocationMatches=$HomepageMatches;NewTabPageLocationMatches=$NewTabMatches;AssignmentCountAfter=$AssignCount;PilotGroupAssigned=$PilotOk;QualityGate=$Gate;Resultado=$Detail;PastaEvidencias=$EvidenceDirectory}|Export-Csv $Paths.Summary -NoTypeInformation -Encoding utf8
    $Completed = ($Gate -notlike 'Reprovado*')
    Write-Host "QUALITY GATE: $Gate"
    Write-Host "RESULTADO: $Detail"
    Write-Host "EVIDÊNCIAS: $EvidenceDirectory"
}catch{$M=$_.Exception.Message;Add-ErrorEvidence 'Fatal' $M;Add-Action 'Fatal' $Acao 'Falha' $M;Export-EvidenceCsv $Paths.Actions @($Actions);Export-EvidenceCsv $Paths.Errors @($Errors);[PSCustomObject]@{AutomationId=$AutomationId;AutomationName=$AutomationName;Acao=$Acao;DataInicioUtc=$StartedAt.ToUniversalTime().ToString('o');DataFimUtc=(Get-Date).ToUniversalTime().ToString('o');QualityGate='Reprovado - falha técnica';Resultado=$M;PastaEvidencias=$EvidenceDirectory}|Export-Csv $Paths.Summary -NoTypeInformation -Encoding utf8;throw
}finally{if($Connected){Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null};try{Stop-Transcript|Out-Null}catch{};if(-not$Completed){Write-Warning 'Execução sem quality gate aprovado.'}}