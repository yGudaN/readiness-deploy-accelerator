# Funcoes do AUTO-34 (SharePoint: excesso de compartilhamento / SharePoint Advanced Management),
# trazidas do script validado no laboratorio (testes-manuais/originais/34-sharepoint-oversharing.ps1).
# Diferencas:
#   - o Graph usa o token do login do instalador; o SharePoint (Connect-SPOService) nao aceita
#     token, entao faz o proprio login no navegador padrao (UseSystemBrowser), como no original;
#   - o prefixo do SharePoint e descoberto pelo Graph (site raiz), sem campo para digitar;
#   - quando o tenant nao tem o SharePoint Advanced Management, o SharePoint responde
#     "experimental feature that is not supported": isso vira o status "Bloqueado" com
#     explicacao, em vez de erro generico (teste no tenant de demo, 09/11/2026).

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappGraph.psm1')

$script:ITEM = 'SharePoint-Compartilhamento'
$script:VERSAO_MINIMA_SPO = [version]'16.0.25409.0'
$script:MODULOS_GRAPH = @('Microsoft.Graph.Users', 'Microsoft.Graph.Identity.DirectoryManagement', 'Microsoft.Graph.Identity.Governance')
$script:ESCOPOS = @('User.Read.All', 'Organization.Read.All', 'RoleManagement.Read.Directory', 'Sites.Read.All')
$script:MENSAGEM_SEM_SAM = 'Bloqueado: o tenant não tem o SharePoint Advanced Management (incluído no Microsoft 365 Copilot ou vendido à parte). Sem ele o SharePoint não oferece este recurso. Nada foi alterado.'

function Get-SafeProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-FirstPropertyValue {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string[]]$Names)
    foreach ($n in $Names) {
        $v = Get-SafeProperty -Object $Object -Name $n
        if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { return $v }
    }
    return $null
}

function Get-TextoCompartilhamento {
    <# SharingCapability em linguagem do usuario. #>
    param([AllowNull()][object]$Valor)
    switch ([string]$Valor) {
        'ExternalUserAndGuestSharing' { 'Qualquer pessoa (links sem login e novos convidados)' }
        'ExternalUserSharingOnly' { 'Novos e existentes convidados' }
        'ExistingExternalUserSharingOnly' { 'Somente convidados existentes' }
        'Disabled' { 'Somente pessoas da organização' }
        default { if ($Valor) { [string]$Valor } else { 'Não informado' } }
    }
}

function Get-SharingClassification {
    param([AllowNull()][object]$Value)
    switch ([string]$Value) {
        'ExternalUserAndGuestSharing' { 'Alto potencial: links Anyone e novos convidados podem ser permitidos.' }
        'ExternalUserSharingOnly' { 'Moderado-alto: novos convidados podem ser permitidos.' }
        'ExistingExternalUserSharingOnly' { 'Moderado: somente convidados existentes.' }
        'Disabled' { 'Exposição externa reduzida: compartilhamento externo desabilitado.' }
        default { 'Não classificado; revisar o valor retornado.' }
    }
}

function Test-ErroSemSam {
    <# O SharePoint responde assim quando o tenant nao tem o SharePoint Advanced Management. #>
    param([Parameter(Mandatory)][object]$Erro)
    return ([string]$Erro.Exception.Message) -match 'experimental feature|not supported in the current environment'
}

function Convert-DagReportToEvidence {
    param([Parameter(Mandatory)][object]$Report, [Parameter(Mandatory)][string]$Consulta)
    [pscustomobject]@{
        DataHoraUtc     = (Get-Date).ToUniversalTime()
        Consulta        = $Consulta
        ReportId        = [string](Get-FirstPropertyValue $Report @('ReportID', 'ReportId', 'Id'))
        Name            = [string](Get-FirstPropertyValue $Report @('Name', 'ReportName'))
        ReportEntity    = [string](Get-FirstPropertyValue $Report @('ReportEntity', 'Entity'))
        ReportType      = [string](Get-FirstPropertyValue $Report @('ReportType', 'Type'))
        Workload        = [string](Get-FirstPropertyValue $Report @('Workload'))
        Status          = [string](Get-FirstPropertyValue $Report @('Status', 'ReportStatus'))
        SiteCount       = [string](Get-FirstPropertyValue $Report @('SiteCount', 'NumberOfSites', 'SitesCount'))
        CreatedDateTime = [string](Get-FirstPropertyValue $Report @('CreatedDateTime', 'CreatedTime', 'CreatedDate'))
        ReportStartTime = [string](Get-FirstPropertyValue $Report @('ReportStartTime', 'StartTime'))
        ReportEndTime   = [string](Get-FirstPropertyValue $Report @('ReportEndTime', 'EndTime'))
    }
}

function Get-ActivityEntities {
    param([Parameter(Mandatory)][ValidateSet('Sites', 'Itens', 'Ambos')][string]$Scope)
    switch ($Scope) {
        'Sites' { @('EveryoneExceptExternalUsersAtSite') }
        'Itens' { @('EveryoneExceptExternalUsersForItems') }
        'Ambos' { @('EveryoneExceptExternalUsersAtSite', 'EveryoneExceptExternalUsersForItems') }
    }
}

function Get-CollectionStatusValue {
    param([AllowNull()][object]$Result)
    if ($null -eq $Result) { return '' }
    $s = Get-FirstPropertyValue -Object $Result -Names @('Status', 'DataCollectionStatus', 'State')
    if ($null -ne $s) { return [string]$s }
    return [string]$Result
}

function Connect-SharePointCompartilhamento {
    <#
    Graph com o token do instalador (conta, funcoes, licencas e prefixo do SharePoint) e, em
    seguida, o modulo do SharePoint com login proprio. Devolve o contexto da execucao.
    #>
    param([Parameter(Mandatory)][hashtable]$Entrada)
    Import-BizappModulosGraph -Modulos $script:MODULOS_GRAPH
    $id = Connect-BizappGraph -Token (Get-BizappToken -Entrada $Entrada -Nome Graph) -EscoposNecessarios $script:ESCOPOS `
        -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta

    $usuario = Get-MgUser -UserId $id.Conta -Property Id, DisplayName, UserPrincipalName, AccountEnabled -ErrorAction Stop
    if (-not $usuario.AccountEnabled) { throw 'A conta administrativa está desabilitada no Microsoft Entra ID.' }
    $funcoes = @(foreach ($a in @(Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($usuario.Id)'" -All -ErrorAction Stop)) {
            $d = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $a.RoleDefinitionId -ErrorAction Stop
            [pscustomobject]@{ Conta = $id.Conta; PrincipalId = $usuario.Id; Funcao = $d.DisplayName; RoleDefinitionId = $a.RoleDefinitionId
                RoleAssignmentId = $a.Id; DirectoryScopeId = $a.DirectoryScopeId }
        })
    $nomes = @($funcoes.Funcao)
    $adminGlobal = $nomes -contains 'Global Administrator' -or $nomes -contains 'Company Administrator'
    $adminSp = $adminGlobal -or $nomes -contains 'SharePoint Administrator'
    $adminSam = $nomes -contains 'SharePoint Advanced Management Administrator'
    if (-not $adminSp) { throw "A conta $($id.Conta) não é Administrador Global nem Administrador do SharePoint." }

    # Licencas: mesma heuristica do original (pelo nome do SKU)
    $skus = @(Get-MgSubscribedSku -All -ErrorAction Stop)
    $licencas = @(foreach ($s in $skus) {
            [pscustomobject]@{ SkuPartNumber = [string]$s.SkuPartNumber; SkuId = [string]$s.SkuId; Capacidade = [string]$s.CapabilityStatus
                UnidadesAtivas = [int]$(if ($s.PrepaidUnits) { $s.PrepaidUnits.Enabled } else { 0 }); UnidadesUsadas = [int]$s.ConsumedUnits }
        })
    $ativas = @($licencas | Where-Object { $_.Capacidade -eq 'Enabled' -and $_.UnidadesAtivas -gt 0 })
    $temSam = @($ativas | Where-Object { $_.SkuPartNumber -match 'COPILOT|SHAREPOINT.*ADVANCED|ADVANCED.*SHAREPOINT|M365.*E7|Microsoft_365_E7|SPE_E7' }).Count -gt 0
    $temE5 = @($ativas | Where-Object { $_.SkuPartNumber -match 'E5|ENTERPRISEPREMIUM' }).Count -gt 0

    # Prefixo do SharePoint pelo site raiz (ex.: https://contoso.sharepoint.com -> contoso)
    $raiz = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/sites/root?$select=webUrl' -ErrorAction Stop
    $prefixo = ([uri]$raiz.webUrl).Host -replace '\.sharepoint\.com$', ''
    if ($prefixo -notmatch '^[a-zA-Z0-9-]+$') { throw "Não foi possível identificar o endereço do SharePoint ($($raiz.webUrl))." }

    $modulo = Import-SharePointModulo
    $adminUrl = "https://$prefixo-admin.sharepoint.com"
    Write-BizappLog "Conectando ao SharePoint ($adminUrl)..."
    Write-BizappLog "O SharePoint pede um login próprio no navegador padrão do Windows. Entre com $($id.Conta)." -Nivel aviso
    $parametros = @{ Url = $adminUrl; ErrorAction = 'Stop' }
    if ((Get-Command Connect-SPOService).Parameters.ContainsKey('UseSystemBrowser')) { $parametros.UseSystemBrowser = $true }
    Connect-SPOService @parametros
    $null = Get-SPOTenant -ErrorAction Stop
    Write-BizappLog 'SharePoint conectado.' -Nivel sucesso

    return [pscustomobject]@{
        Identidade = $id; Funcoes = $funcoes; NomesFuncoes = $nomes; AdminSam = $adminSam
        Licencas = $licencas; TemSamPorLicenca = $temSam; TemE5 = $temE5
        Prefixo = $prefixo; AdminUrl = $adminUrl; RaizUrl = "https://$prefixo.sharepoint.com"; VersaoModulo = [string]$modulo.Version
    }
}

function Import-SharePointModulo {
    <# Importa o modulo do SharePoint pelo caminho (como no original) e confere a versao minima. #>
    $m = Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $m) { throw 'O módulo Microsoft.Online.SharePoint.PowerShell não está instalado. Instale-o pela tela de pré-requisitos.' }
    if ($m.Version -lt $script:VERSAO_MINIMA_SPO) {
        throw "O módulo do SharePoint está na versão $($m.Version); é preciso $($script:VERSAO_MINIMA_SPO) ou superior. Atualize pela tela de pré-requisitos."
    }
    # -Global: importado dentro deste .psm1, sem -Global os comandos ficariam invisiveis para o script da etapa
    Import-Module -Name $m.Path -Force -Global -ErrorAction Stop -WarningAction SilentlyContinue 3>$null | Out-Null
    Write-BizappLog "SharePoint Online Management Shell $($m.Version)" -Nivel discreto
    return $m
}

function Get-EstadoSam {
    <#
    Detecta na pratica se o recurso existe: a leitura do estado da coleta de atividade e
    somente leitura e falha com "experimental feature" quando nao ha SharePoint Advanced Management.
    #>
    try {
        $s = Get-SPOAuditDataCollectionStatusForActivityInsights -ReportEntity EveryoneExceptExternalUsersAtSite -ErrorAction Stop
        return [pscustomobject]@{ Disponivel = $true; Coleta = (Get-CollectionStatusValue $s); Detalhe = '' }
    } catch {
        if (Test-ErroSemSam $_) { return [pscustomobject]@{ Disponivel = $false; Coleta = ''; Detalhe = $_.Exception.Message } }
        return [pscustomobject]@{ Disponivel = $null; Coleta = ''; Detalhe = $_.Exception.Message }
    }
}

function Get-TextoColeta {
    param([AllowNull()][AllowEmptyString()][string]$Status)
    switch ($Status) {
        'InProgress' { 'Ligada (coletando)' }
        'Paused' { 'Desligada' }
        'NotStarted' { 'Desligada' }
        '' { 'Não disponível' }
        default { $Status }
    }
}

function Write-ContextoEvidencias {
    param([Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)][object]$Ctx, [string]$Acao, [string]$Justificativa = '')
    Export-BizappEvidencia -Pasta $Pasta -Nome 'funcoes-administrativas.csv' -Dados @($Ctx.Funcoes)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'licencas-tenant.csv' -Dados @($Ctx.Licencas)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'contexto.csv' -Dados ([pscustomobject]@{
            DataHoraUtc = (Get-Date).ToUniversalTime(); Acao = $Acao; TenantId = $Ctx.Identidade.TenantId; Conta = $Ctx.Identidade.Conta
            EscoposGraph = ($Ctx.Identidade.Escopos -join '; '); FuncoesAtivas = ($Ctx.NomesFuncoes -join '; ')
            SharePointAdminUrl = $Ctx.AdminUrl; SharePointRootUrl = $Ctx.RaizUrl; VersaoModuloSharePoint = $Ctx.VersaoModulo
            PowerShellVersion = [string]$PSVersionTable.PSVersion; PossuiFuncaoSamAdmin = $Ctx.AdminSam
            PossuiSamOuCopilotCandidata = $Ctx.TemSamPorLicenca; PossuiE5Candidata = $Ctx.TemE5; Justificativa = $Justificativa })
}

function Write-ResumoSharePoint {
    <# resumo.csv / resumo.json no formato do original; interrompe se o quality gate falhou. #>
    param([string]$Pasta, [string]$Acao, [object]$Ctx, [string]$QualityGate, [hashtable]$Extras = @{}, [datetime]$Inicio)
    $resumo = [ordered]@{
        Automacao = 'AUTO-34'; Nome = 'SharePoint SAM / oversharing'; Acao = $Acao; Inicio = $Inicio; Fim = Get-Date
        TenantId = $Ctx.Identidade.TenantId; Conta = $Ctx.Identidade.Conta; SharePointAdminUrl = $Ctx.AdminUrl
        VersaoModuloSharePoint = $Ctx.VersaoModulo; FuncoesAtivas = ($Ctx.NomesFuncoes -join '; ')
    }
    foreach ($k in $Extras.Keys) { $resumo[$k] = $Extras[$k] }
    $resumo.QualityGate = $QualityGate
    $resumo.PastaEvidencias = $Pasta
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject]$resumo)
    [pscustomobject]$resumo | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Pasta 'resumo.json') -Encoding utf8
    if ($QualityGate -like 'Falha*') { throw "A validação final não foi aprovada: $QualityGate" }
    Write-BizappLog "Validação: $QualityGate" -Nivel $(if ($QualityGate -like 'Aprovado*') { 'sucesso' } else { 'aviso' })
}

Export-ModuleMember -Variable ITEM, MENSAGEM_SEM_SAM -Function Get-SafeProperty, Get-FirstPropertyValue, Get-TextoCompartilhamento, `
    Get-SharingClassification, Test-ErroSemSam, Convert-DagReportToEvidence, Get-ActivityEntities, Get-CollectionStatusValue, `
    Connect-SharePointCompartilhamento, Get-EstadoSam, Get-TextoColeta, Write-ContextoEvidencias, Write-ResumoSharePoint
