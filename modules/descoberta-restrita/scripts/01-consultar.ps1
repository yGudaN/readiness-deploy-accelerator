#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-16 · Consultar (somente leitura): conta, funcao e licencas, e a lista de todos os sites
    (sem OneDrive) com o estado da descoberta restrita (comando do roteiro em Word).
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DescobertaRestrita.psm1') -Force
$entrada = Read-BizappEntrada

# Primeira etapa: ainda nao ha conta confirmada, entao vale a do login
$id = Get-BizappIdentidade -Token (Get-BizappToken -Entrada $entrada -Nome Graph)
$entrada.TenantId = $id.TenantId
$entrada.Conta = $id.Conta

try {
    $ctx = Connect-DescobertaRestrita -Entrada $entrada
    $pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
    Write-ContextoRcd -Pasta $pasta -Ctx $ctx -Acao 'Consultar'

    Write-BizappLog 'Lendo os sites...'
    $sites = Get-SitesRcd
    Export-BizappEvidencia -Pasta $pasta -Nome 'sites-rcd.csv' -Dados $(if ($sites.Count) { $sites } else { [pscustomobject]@{ Resultado = 'Nenhum site encontrado.' } })
    $ligados = @($sites | Where-Object { $_.RestrictContentOrgWideSearch -eq $true })
    foreach ($s in $sites) { Write-BizappLog "$(if ($s.RestrictContentOrgWideSearch -eq $true) { '● restrito' } else { '○ normal  ' })  $($s.Title) · $($s.Url)" -Nivel discreto }

    $raiz = Get-RcdSiteState -Identity $ctx.RaizUrl
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-antes.csv' -Dados $raiz
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-depois.csv' -Dados $raiz
    Write-BizappLog "$($sites.Count) sites; com descoberta restrita: $($ligados.Count)." -Nivel sucesso
    if (-not $ctx.LicencaCandidata) {
        Write-BizappLog 'Não foi encontrada licença do Microsoft 365 Copilot nem do SharePoint Advanced Management. A consulta funciona, mas o SharePoint pode recusar ligar o recurso.' -Nivel aviso
    }

    Set-BizappSaida -Nome 'Conta' -Valor $ctx.Identidade.Conta
    Set-BizappSaida -Nome 'TenantId' -Valor $ctx.Identidade.TenantId
    Set-BizappSaida -Nome 'EnderecoSharePoint' -Valor $ctx.RaizUrl
    Set-BizappSaida -Nome 'SitesRcd' -Valor "$($sites.Count) sites · $($ligados.Count) com descoberta restrita"
    Set-BizappSaida -Nome 'SitesRestritos' -Valor $(if ($ligados) { ($ligados | ForEach-Object { $_.Title }) -join '; ' } else { 'Nenhum' })
    Set-BizappSaida -Nome 'LicencaSam' -Valor $(if ($ctx.LicencaCandidata) { 'Encontrada' } else { 'Não encontrada' })

    Write-ResumoRcd -Pasta $pasta -Site $ctx.RaizUrl -Acao 'Consultar' -Antes $raiz -Depois $raiz -Alterou $false -Aprovada $true
} finally {
    Disconnect-DescobertaRestrita
}
