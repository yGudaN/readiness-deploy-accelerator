#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-34 · Consultar (somente leitura): compartilhamento do tenant e de cada site (sem
    OneDrive), funcoes, licencas, relatorios de governanca de acesso existentes e se o
    SharePoint Advanced Management esta disponivel. Nao altera nada.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SharePointCompartilhamento.psm1') -Force
$entrada = Read-BizappEntrada
$inicio = Get-Date

$ctx = Connect-SharePointCompartilhamento -Entrada $entrada
$id = $ctx.Identidade
Write-BizappLog "Conta: $($id.Conta) · funções: $($ctx.NomesFuncoes -join ', ')" -Nivel sucesso
Set-BizappSaida -Nome 'Conta' -Valor $id.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $id.TenantId
Set-BizappSaida -Nome 'EnderecoSharePoint' -Valor $ctx.RaizUrl

$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
Write-ContextoEvidencias -Pasta $pasta -Ctx $ctx -Acao 'Consultar'

# Tenant
$t = Get-SPOTenant -ErrorAction Stop
Export-BizappEvidencia -Pasta $pasta -Nome 'tenant-sharing.csv' -Dados ([pscustomobject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime()
        SharingCapability = [string](Get-SafeProperty $t 'SharingCapability')
        DefaultSharingLinkType = [string](Get-SafeProperty $t 'DefaultSharingLinkType')
        DefaultLinkPermission = [string](Get-SafeProperty $t 'DefaultLinkPermission')
        ShowEveryoneClaim = [string](Get-SafeProperty $t 'ShowEveryoneClaim')
        ShowEveryoneExceptExternalUsersClaim = [string](Get-SafeProperty $t 'ShowEveryoneExceptExternalUsersClaim')
        SharingDomainRestrictionMode = [string](Get-SafeProperty $t 'SharingDomainRestrictionMode')
        ExternalUserExpirationRequired = [string](Get-SafeProperty $t 'ExternalUserExpirationRequired')
        ExternalUserExpireInDays = [string](Get-SafeProperty $t 'ExternalUserExpireInDays')
        ClassificacaoConfiguracao = Get-SharingClassification (Get-SafeProperty $t 'SharingCapability')
        Observacao = 'Configuração potencial; não comprova oversharing efetivo.' })
$textoTenant = Get-TextoCompartilhamento (Get-SafeProperty $t 'SharingCapability')
Write-BizappLog "Compartilhamento externo do tenant: $textoTenant"
Set-BizappSaida -Nome 'CompartilhamentoTenant' -Valor $textoTenant

# Sites (sem OneDrive)
$indice = @(Get-SPOSite -Limit All -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Url) })
$sites = [System.Collections.Generic.List[object]]::new()
$erros = [System.Collections.Generic.List[object]]::new()
$n = 0
foreach ($item in $indice) {
    $n++
    Write-BizappProgresso -Percentual ([math]::Round($n / [math]::Max($indice.Count, 1) * 100, 0)) -Fase "Lendo sites: $n de $($indice.Count)"
    try {
        $s = Get-SPOSite -Identity $item.Url -ErrorAction Stop
        $nivel = Get-SafeProperty $s 'SharingCapability'
        $sites.Add([pscustomobject]@{
                DataHoraUtc = (Get-Date).ToUniversalTime(); Url = [string](Get-SafeProperty $s 'Url'); Title = [string](Get-SafeProperty $s 'Title')
                Template = [string](Get-SafeProperty $s 'Template'); LockState = [string](Get-SafeProperty $s 'LockState')
                SharingCapability = [string]$nivel; DefaultSharingLinkType = [string](Get-SafeProperty $s 'DefaultSharingLinkType')
                DefaultLinkPermission = [string](Get-SafeProperty $s 'DefaultLinkPermission')
                DisableCompanyWideSharingLinks = [string](Get-SafeProperty $s 'DisableCompanyWideSharingLinks')
                SharingDomainRestrictionMode = [string](Get-SafeProperty $s 'SharingDomainRestrictionMode')
                ExternalUserExpirationInDays = [string](Get-SafeProperty $s 'ExternalUserExpirationInDays')
                AnonymousLinkExpirationInDays = [string](Get-SafeProperty $s 'AnonymousLinkExpirationInDays')
                SensitivityLabel = [string](Get-SafeProperty $s 'SensitivityLabel')
                ConditionalAccessPolicy = [string](Get-SafeProperty $s 'ConditionalAccessPolicy')
                ClassificacaoConfiguracao = Get-SharingClassification $nivel
                Observacao = 'Configuração potencial; não comprova oversharing.' })
    } catch {
        $erros.Add([pscustomobject]@{ DataHoraUtc = (Get-Date).ToUniversalTime(); Url = [string]$item.Url; Etapa = 'Get-SPOSite -Identity'; Erro = $_.Exception.Message })
    }
}
Export-BizappEvidencia -Pasta $pasta -Nome 'sites-sharing.csv' -Dados @($sites)
Export-BizappEvidencia -Pasta $pasta -Nome 'sites-erros.csv' -Dados @($erros)
$abertos = @($sites | Where-Object SharingCapability -eq 'ExternalUserAndGuestSharing').Count
Write-BizappLog "Sites lidos: $($sites.Count) · com links para qualquer pessoa liberados: $abertos · com erro na leitura: $($erros.Count)" -Nivel $(if ($erros.Count) { 'aviso' } else { 'info' })
Set-BizappSaida -Nome 'SitesLidos' -Valor "$($sites.Count) sites · $abertos com links para qualquer pessoa liberados"

# Relatorios de governanca de acesso ja existentes (falha por consulta nao interrompe)
$consultas = @(
    @{ Nome = 'Atividade EEEU no nível do site'; P = @{ ReportEntity = 'EveryoneExceptExternalUsersAtSite'; Workload = 'SharePoint'; ReportType = 'RecentActivity' } },
    @{ Nome = 'Atividade EEEU no nível de itens'; P = @{ ReportEntity = 'EveryoneExceptExternalUsersForItems'; Workload = 'SharePoint'; ReportType = 'RecentActivity' } },
    @{ Nome = 'Baseline de permissões do SharePoint'; P = @{ ReportEntity = 'PermissionedUsers'; Workload = 'SharePoint'; ReportType = 'Snapshot' } },
    @{ Nome = 'Snapshot detalhado Everyone/EEEU'; P = @{ ReportEntity = 'EveryoneExceptExternalUsers'; ReportType = 'Snapshot' } }
)
$resultadoConsultas = [System.Collections.Generic.List[object]]::new()
$relatorios = [System.Collections.Generic.List[object]]::new()
foreach ($c in $consultas) {
    $p = $c.P
    try {
        $r = @(Get-SPODataAccessGovernanceInsight @p -ErrorAction Stop)
        $resultadoConsultas.Add([pscustomobject]@{ Consulta = $c.Nome; Status = 'Sucesso'; Quantidade = $r.Count; Detalhe = $(if ($r.Count) { 'Relatórios existentes encontrados.' } else { 'Consulta concluída sem relatórios existentes.' }) })
        foreach ($x in $r) { $relatorios.Add((Convert-DagReportToEvidence $x $c.Nome)) }
    } catch {
        $resultadoConsultas.Add([pscustomobject]@{ Consulta = $c.Nome; Status = 'Falha'; Quantidade = 0; Detalhe = $_.Exception.Message })
    }
}
Export-BizappEvidencia -Pasta $pasta -Nome 'dag-consultas.csv' -Dados @($resultadoConsultas)
Export-BizappEvidencia -Pasta $pasta -Nome 'dag-reports.csv' -Dados @($relatorios)
Write-BizappLog "Relatórios de governança de acesso já existentes: $($relatorios.Count)"
if ($relatorios.Count) {
    $ultimo = $relatorios | Sort-Object CreatedDateTime | Select-Object -Last 1
    if ($ultimo.ReportId) { Set-BizappSaida -Nome 'ReportId' -Valor $ultimo.ReportId }
}

# SharePoint Advanced Management: licenca (pelo nome do SKU) e recurso (na pratica)
$sam = Get-EstadoSam
if ($sam.Disponivel -eq $true) {
    Write-BizappLog "SharePoint Advanced Management: disponível · coleta de atividade: $(Get-TextoColeta $sam.Coleta)" -Nivel sucesso
    Set-BizappSaida -Nome 'RecursoSam' -Valor 'Disponível'
    Set-BizappSaida -Nome 'ColetaAtividade' -Valor (Get-TextoColeta $sam.Coleta)
} elseif ($sam.Disponivel -eq $false) {
    Write-BizappLog 'SharePoint Advanced Management: não encontrado neste tenant (nem a licença, nem o recurso). Os relatórios de governança e a coleta de atividade ficam indisponíveis; a consulta de compartilhamento funciona normalmente.' -Nivel aviso
    Set-BizappSaida -Nome 'RecursoSam' -Valor $(if ($ctx.TemSamPorLicenca) { 'Licença encontrada, recurso indisponível' } else { 'Não encontrado (licença ou recurso)' })
    Set-BizappSaida -Nome 'ColetaAtividade' -Valor 'Não disponível'
} else {
    Write-BizappLog "Não foi possível confirmar o SharePoint Advanced Management: $($sam.Detalhe)" -Nivel aviso
    Set-BizappSaida -Nome 'RecursoSam' -Valor 'Não confirmado'
}
Set-BizappSaida -Nome 'FuncaoSam' -Valor $(if ($ctx.AdminSam) { 'Sim' } else { 'Não' })

$gate = if ($erros.Count -eq 0) { 'Aprovado - coleta administrativa' } else { 'Parcial - erros na coleta por site' }
Export-BizappEvidencia -Pasta $pasta -Nome 'acoes.csv' -Dados ([pscustomobject]@{ DataHoraUtc = (Get-Date).ToUniversalTime(); Resultado = 'Nenhuma alteração administrativa executada.' })
Write-ResumoSharePoint -Pasta $pasta -Acao 'Consultar' -Ctx $ctx -QualityGate $gate -Inicio $inicio -Extras @{
    SitesEnumerados = $indice.Count; SitesComErro = $erros.Count; SitesLinksQualquerPessoa = $abertos
    RelatoriosEncontrados = $relatorios.Count; RecursoSamDisponivel = $sam.Disponivel
    Conclusao = 'A configuração de compartilhamento indica exposição potencial. Oversharing efetivo depende da análise dos relatórios, do contexto do conteúdo e da validação dos proprietários.'
}
