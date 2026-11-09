#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-34 · ConfigurarCompartilhamentoSite: muda o compartilhamento externo de UM site e
    confere o valor depois. Site fora do tenant e bloqueado; valor igual ao atual nao altera.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SharePointCompartilhamento.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'SiteUrl', 'NivelCompartilhamento'
$inicio = Get-Date

$nivel = [string]$entrada.NivelCompartilhamento
if ($nivel -notin 'Disabled', 'ExistingExternalUserSharingOnly', 'ExternalUserSharingOnly', 'ExternalUserAndGuestSharing') {
    throw "Nível inválido: $nivel"
}
$site = ([string]$entrada.SiteUrl).Trim().TrimEnd('/')

$ctx = Connect-SharePointCompartilhamento -Entrada $entrada
if (-not $site.ToLowerInvariant().StartsWith($ctx.RaizUrl.ToLowerInvariant() + '/')) {
    throw "O site informado não é deste tenant (esperado um endereço em $($ctx.RaizUrl)). Nada foi alterado."
}
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'ConfigurarCompartilhamentoSite'
$justificativa = 'Executado pelo Readiness Deploy Accelerator'
Write-ContextoEvidencias -Pasta $pasta -Ctx $ctx -Acao 'ConfigurarCompartilhamentoSite' -Justificativa $justificativa

$antes = Get-SPOSite -Identity $site -ErrorAction Stop
Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-antes.csv' -Dados ([pscustomobject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime(); Url = [string]$antes.Url; Title = [string]$antes.Title; SharingCapability = [string]$antes.SharingCapability })
Write-BizappLog "$($antes.Title): hoje · $(Get-TextoCompartilhamento $antes.SharingCapability)"

$alterou = $false
if ([string]$antes.SharingCapability -eq $nivel) {
    Write-BizappLog 'O site já está com este nível: nada foi alterado.' -Nivel sucesso
} else {
    Write-BizappLog "Mudando para: $(Get-TextoCompartilhamento $nivel)..."
    Set-SPOSite -Identity $site -SharingCapability $nivel -ErrorAction Stop
    $alterou = $true
}

$depois = Get-SPOSite -Identity $site -ErrorAction Stop
Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-depois.csv' -Dados ([pscustomobject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime(); Url = [string]$depois.Url; Title = [string]$depois.Title; SharingCapability = [string]$depois.SharingCapability })
Export-BizappEvidencia -Pasta $pasta -Nome 'acoes.csv' -Dados ([pscustomobject]@{
        Acao = 'ConfigurarCompartilhamentoSite'; Recurso = $site; Antes = [string]$antes.SharingCapability; Depois = [string]$depois.SharingCapability
        AlteracaoExecutada = $alterou; Justificativa = $justificativa })
Set-BizappSaida -Nome 'CompartilhamentoSite' -Valor "$($depois.Title) · $(Get-TextoCompartilhamento $depois.SharingCapability)"

$gate = if ([string]$depois.SharingCapability -eq $nivel) { 'Aprovado - configuração alterada e verificada' } else { 'Falha - estado final diferente do solicitado' }
if ([string]$depois.SharingCapability -ne $nivel -and [string]$depois.SharingCapability -eq [string]$antes.SharingCapability) {
    # O nivel do site nao pode ser mais aberto que o do tenant: o SharePoint mantem o anterior
    Write-BizappLog 'O SharePoint manteve o nível anterior. O compartilhamento de um site não pode ser mais aberto que o do tenant.' -Nivel aviso
}
Write-ResumoSharePoint -Pasta $pasta -Acao 'ConfigurarCompartilhamentoSite' -Ctx $ctx -QualityGate $gate -Inicio $inicio -Extras @{
    Site = $site; Antes = [string]$antes.SharingCapability; Depois = [string]$depois.SharingCapability; AlteracaoExecutada = $alterou }
