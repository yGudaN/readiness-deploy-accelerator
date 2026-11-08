# Funcoes do AUTO-22 (grupos Copilot-Premium e Copilot-Geral), trazidas do script validado no
# laboratorio (testes-manuais/originais/22-grupos-copilot.ps1) sem mudar a logica. A diferenca
# e so a conexao: o Graph usa o token do login do instalador (ver BizappGraph.psm1).

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappGraph.psm1')

$script:ITEM = 'Grupos-Copilot'

# Mesmos modulos e escopos do script validado. O login do item pede todos de uma vez
# (um login so para as tres etapas); cada etapa confere os escopos que usa.
$script:MODULOS_GRAPH = @('Microsoft.Graph.Users', 'Microsoft.Graph.Groups', 'Microsoft.Graph.Identity.DirectoryManagement', 'Microsoft.Graph.Identity.Governance')
$script:ESCOPOS_CONSULTA = @('Group.Read.All', 'User.Read.All', 'Organization.Read.All', 'RoleManagement.Read.Directory')

$script:DEFINICOES = @(
    [pscustomobject]@{ DisplayName = 'Copilot-Premium'; MailNickname = 'copilotpremium'; Description = 'Grupo de segurança para usuários do escopo Copilot Premium.' },
    [pscustomobject]@{ DisplayName = 'Copilot-Geral'; MailNickname = 'copilotgeral'; Description = 'Grupo de segurança para usuários do escopo geral do Copilot.' }
)

function Get-DefinicoesGrupos {
    param([ValidateSet('Ambos', 'Copilot-Premium', 'Copilot-Geral')][string]$GrupoAlvo = 'Ambos')
    if ($GrupoAlvo -eq 'Ambos') { return $script:DEFINICOES }
    return @($script:DEFINICOES | Where-Object DisplayName -eq $GrupoAlvo)
}

function Connect-GruposCopilot {
    <# Prepara modulos, conecta o Graph com o token e valida conta, funcao e contexto. #>
    param([Parameter(Mandatory)][hashtable]$Entrada, [string[]]$EscoposExtras = @())
    Import-BizappModulosGraph -Modulos $script:MODULOS_GRAPH
    $id = Connect-BizappGraph -Token (Get-BizappToken -Entrada $Entrada -Nome Graph) `
        -EscoposNecessarios ($script:ESCOPOS_CONSULTA + $EscoposExtras) `
        -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta

    $admin = Get-MgUser -UserId $id.Conta -Property @('Id', 'DisplayName', 'UserPrincipalName', 'AccountEnabled') -ErrorAction Stop
    if ($admin.AccountEnabled -ne $true) { throw 'A conta administrativa não está habilitada.' }

    $atribuicoes = @(Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($admin.Id)'" -All -ErrorAction Stop)
    $funcoes = foreach ($a in $atribuicoes) {
        $d = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $a.RoleDefinitionId -ErrorAction Stop
        [pscustomobject]@{ Conta = $id.Conta; PrincipalId = $admin.Id; Funcao = $d.DisplayName; RoleDefinitionId = $a.RoleDefinitionId; RoleAssignmentId = $a.Id; DirectoryScopeId = $a.DirectoryScopeId }
    }
    $aceitas = @('Global Administrator', 'Groups Administrator', 'User Administrator', 'Directory Writers')
    if (-not @($funcoes | Where-Object Funcao -in $aceitas).Count) {
        throw "A conta $($id.Conta) não tem uma função aceita ($($aceitas -join ', '))."
    }
    return [pscustomobject]@{ Identidade = $id; Admin = $admin; Funcoes = @($funcoes) }
}

function Get-InventarioLicencas {
    $skus = @(Get-MgSubscribedSku -All -ErrorAction Stop)
    $linhas = foreach ($s in $skus) {
        $ativas = [int]$s.PrepaidUnits.Enabled; $usadas = [int]$s.ConsumedUnits
        [pscustomobject]@{
            SkuPartNumber = $s.SkuPartNumber; SkuId = $s.SkuId; Capacidade = $s.CapabilityStatus
            UnidadesAtivas = $ativas; UnidadesUsadas = $usadas; UnidadesDisponiveis = ($ativas - $usadas)
            CandidataCopilot = ([string]$s.SkuPartNumber -match 'COPILOT'); AplicaSeA = $s.AppliesTo
            ServicePlans = (@($s.ServicePlans.ServicePlanName) -join ';')
        }
    }
    return [pscustomobject]@{ Skus = $skus; Evidencia = @($linhas) }
}

function ConvertTo-ODataStringLiteral {
    param([Parameter(Mandatory)][string]$Value)
    $Value.Replace("'", "''")
}

function Get-ExactGroups {
    param([Parameter(Mandatory)][string]$DisplayName)
    $EscapedName = ConvertTo-ODataStringLiteral -Value $DisplayName
    # HasMembersWithLicenseErrors nao pode ser usado em -Property (so como filtro).
    @(
        Get-MgGroup -Filter "displayName eq '$EscapedName'" -Property @(
            'Id', 'DisplayName', 'Description', 'Mail', 'MailNickname', 'MailEnabled', 'SecurityEnabled',
            'GroupTypes', 'MembershipRule', 'MembershipRuleProcessingState', 'Visibility', 'CreatedDateTime',
            'OnPremisesSyncEnabled', 'IsAssignableToRole', 'AssignedLicenses', 'LicenseProcessingState'
        ) -All -ErrorAction Stop
    )
}

function Get-OwnerEvidence {
    param([Parameter(Mandatory)][string]$GroupId)
    $Owners = @(Get-MgGroupOwner -GroupId $GroupId -All -ErrorAction Stop)
    $Labels = foreach ($Owner in $Owners) {
        $Upn = $null; $Name = $null
        if ($null -ne $Owner.AdditionalProperties) {
            $Upn = [string]$Owner.AdditionalProperties['userPrincipalName']
            $Name = [string]$Owner.AdditionalProperties['displayName']
        }
        if (-not [string]::IsNullOrWhiteSpace($Upn)) { $Upn }
        elseif (-not [string]::IsNullOrWhiteSpace($Name)) { "$Name [$($Owner.Id)]" }
        else { [string]$Owner.Id }
    }
    [pscustomobject]@{ QuantidadeOwners = $Owners.Count; OwnerIds = (@($Owners.Id) -join ';'); Owners = ($Labels -join '; ') }
}

function Get-GroupSnapshot {
    param([Parameter(Mandatory)][object[]]$GroupDefinitions, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SubscribedSkus)
    $Rows = [System.Collections.Generic.List[object]]::new()
    foreach ($Definition in $GroupDefinitions) {
        $Matches = @(Get-ExactGroups -DisplayName $Definition.DisplayName)
        if ($Matches.Count -eq 0) {
            $Rows.Add([pscustomobject]@{
                NomeConsultado = $Definition.DisplayName; StatusConsulta = 'Não encontrado'; QuantidadeCorrespondencias = 0
                Id = $null; DisplayName = $null; Description = $null; MailNickname = $null; MailEnabled = $null; SecurityEnabled = $null
                GroupTypes = $null; TipoMembro = $null; MembershipRule = $null; MembershipRuleProcessingState = $null
                CreatedDateTime = $null; OnPremisesSyncEnabled = $null; IsAssignableToRole = $null
                QuantidadeOwners = 0; OwnerIds = $null; Owners = $null; QuantidadeLicencas = 0
                SkuIdsAtribuidos = $null; SkuPartNumbersAtribuidos = $null; EstadoProcessamentoLicenca = $null
            })
            continue
        }
        foreach ($Group in $Matches) {
            $OwnerEvidence = Get-OwnerEvidence -GroupId $Group.Id
            $AssignedSkuIds = @($Group.AssignedLicenses | ForEach-Object { [string]$_.SkuId })
            $AssignedSkuNames = foreach ($SkuId in $AssignedSkuIds) {
                $Sku = $SubscribedSkus | Where-Object { [string]$_.SkuId -eq $SkuId } | Select-Object -First 1
                if ($null -ne $Sku) { [string]$Sku.SkuPartNumber } else { "SKU não localizada [$SkuId]" }
            }
            $LicenseState = if ($null -ne $Group.LicenseProcessingState) { $Group.LicenseProcessingState.State } else { $null }
            $Rows.Add([pscustomobject]@{
                NomeConsultado = $Definition.DisplayName
                StatusConsulta = if ($Matches.Count -eq 1) { 'Encontrado único' } else { 'Duplicidade de DisplayName' }
                QuantidadeCorrespondencias = $Matches.Count
                Id = $Group.Id; DisplayName = $Group.DisplayName; Description = $Group.Description; MailNickname = $Group.MailNickname
                MailEnabled = $Group.MailEnabled; SecurityEnabled = $Group.SecurityEnabled; GroupTypes = (@($Group.GroupTypes) -join ';')
                TipoMembro = if (@($Group.GroupTypes) -contains 'DynamicMembership') { 'Dinâmico' } else { 'Atribuído' }
                MembershipRule = $Group.MembershipRule; MembershipRuleProcessingState = $Group.MembershipRuleProcessingState
                CreatedDateTime = $Group.CreatedDateTime; OnPremisesSyncEnabled = $Group.OnPremisesSyncEnabled; IsAssignableToRole = $Group.IsAssignableToRole
                QuantidadeOwners = $OwnerEvidence.QuantidadeOwners; OwnerIds = $OwnerEvidence.OwnerIds; Owners = $OwnerEvidence.Owners
                QuantidadeLicencas = $AssignedSkuIds.Count; SkuIdsAtribuidos = ($AssignedSkuIds -join ';')
                SkuPartNumbersAtribuidos = ($AssignedSkuNames -join ';'); EstadoProcessamentoLicenca = $LicenseState
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
                GrupoDisplayName = $Definition.DisplayName; GroupId = $null
                ConsultaMembros = if ($Matches.Count -eq 0) { 'Não aplicável: grupo ausente' } else { 'Não executada: grupo duplicado' }
                MemberId = $null; TipoObjeto = $null
            })
            continue
        }
        $Group = $Matches[0]
        $Members = @(Get-MgGroupMember -GroupId $Group.Id -All -ErrorAction Stop)
        if ($Members.Count -eq 0) {
            $Rows.Add([pscustomobject]@{ GrupoDisplayName = $Group.DisplayName; GroupId = $Group.Id; ConsultaMembros = 'Concluída: sem membros'; MemberId = $null; TipoObjeto = $null })
            continue
        }
        foreach ($Member in $Members) {
            $MemberType = if ($null -ne $Member.AdditionalProperties) { $Member.AdditionalProperties['@odata.type'] } else { $null }
            $Rows.Add([pscustomobject]@{ GrupoDisplayName = $Group.DisplayName; GroupId = $Group.Id; ConsultaMembros = 'Concluída'; MemberId = $Member.Id; TipoObjeto = $MemberType })
        }
    }
    @($Rows)
}

function Wait-ForGroupReplication {
    param([Parameter(Mandatory)][string]$GroupId)
    for ($Attempt = 1; $Attempt -le 10; $Attempt++) {
        try { $null = Get-MgGroup -GroupId $GroupId -Property @('Id', 'DisplayName') -ErrorAction Stop; return }
        catch { if ($Attempt -eq 10) { throw }; Start-Sleep -Seconds 5 }
    }
}

function Test-MembershipState {
    param([Parameter(Mandatory)][string]$GroupId, [Parameter(Mandatory)][string]$DirectoryObjectId, [Parameter(Mandatory)][bool]$ShouldExist)
    for ($Attempt = 1; $Attempt -le 12; $Attempt++) {
        $Ids = @(Get-MgGroupMember -GroupId $GroupId -All -ErrorAction Stop | ForEach-Object { [string]$_.Id })
        if (($DirectoryObjectId -in $Ids) -eq $ShouldExist) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Write-ResumoGrupos {
    <# Mostra no log o estado de cada grupo e devolve um texto curto por grupo para as saidas. #>
    param([Parameter(Mandatory)][object[]]$Snapshot, [object[]]$Membros = @())
    foreach ($linha in $Snapshot) {
        $nMembros = @($Membros | Where-Object { $_.GroupId -and $_.GroupId -eq $linha.Id -and $_.MemberId }).Count
        $texto = switch ($linha.StatusConsulta) {
            'Não encontrado' { 'Não existe' }
            'Encontrado único' { "Existe ($nMembros membro(s), $($linha.QuantidadeOwners) owner(s))" }
            default { "Duplicado: $($linha.QuantidadeCorrespondencias) grupos com esse nome" }
        }
        $nivel = if ($linha.StatusConsulta -like 'Duplicidade*') { 'aviso' } else { 'info' }
        Write-BizappLog "$($linha.NomeConsultado): $texto" -Nivel $nivel
        if ($linha.NomeConsultado -eq 'Copilot-Premium') { Set-BizappSaida -Nome 'EstadoCopilotPremium' -Valor $texto }
        else { Set-BizappSaida -Nome 'EstadoCopilotGeral' -Valor $texto }
    }
}

function Write-ResumoExecucao {
    <# Grava resumo.csv no mesmo formato do script validado e interrompe se a validacao falhou. #>
    param([string]$Pasta, [string]$Acao, [object]$Identidade, [bool]$Alterou, [bool]$Aprovada, [string[]]$Notas, [datetime]$Inicio, [string]$Extra = '')
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject]@{
        DataHoraInicio = $Inicio.ToString('o'); DataHoraFim = (Get-Date).ToString('o'); Item = 'AUTO-22'; Controle = 'Grupos Premium e geral'
        AcaoSolicitada = $Acao; Detalhe = $Extra; Tenant = $Identidade.TenantId; Conta = $Identidade.Conta
        AlteracaoExecutada = $Alterou; ExecucaoConcluida = $true; ValidacaoAprovada = $Aprovada
        ObservacaoValidacao = $(if ($Notas) { $Notas -join ' ' } else { 'Todas as validações objetivas da ação foram aprovadas.' })
        LicencaAtribuida = $false; LicencaRemovida = $false; GrupoExcluido = $false; PastaEvidencias = $Pasta
    })
    if (-not $Aprovada) { throw "A validação final não foi aprovada: $($Notas -join ' ')" }
    Write-BizappLog 'Validação aprovada.' -Nivel sucesso
}

Export-ModuleMember -Variable ITEM -Function Get-DefinicoesGrupos, Connect-GruposCopilot, Get-InventarioLicencas, Get-ExactGroups, Get-GroupSnapshot, `
    Get-MemberSnapshot, Wait-ForGroupReplication, Test-MembershipState, Write-ResumoGrupos, Write-ResumoExecucao, ConvertTo-ODataStringLiteral
