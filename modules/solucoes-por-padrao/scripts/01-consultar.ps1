#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-13 · Consultar (somente leitura): ambiente, papel da conta e o estado das chaves de
    canvas apps e cloud flows em solucoes por padrao.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SolucoesPorPadrao.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl'

$ctx = Connect-SolucoesPorPadrao -Entrada $entrada -PrimeiraEtapa
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
Write-ContextoSolucoes -Pasta $pasta -Ctx $ctx -Acao 'Consultar'
Write-BizappLog "Ambiente: $($ctx.Nome) · Environment ID $($ctx.EnvironmentId)" -Nivel sucesso
Write-AvisoAdmin -Ctx $ctx

$chaves = Get-Chaves
Export-BizappEvidencia -Pasta $pasta -Nome 'chaves-antes.csv' -Dados $chaves
Write-BizappLog "Apps de tela em soluções por padrão: $(Get-TextoChave $chaves.CanvasApps)"
Write-BizappLog "Fluxos da nuvem em soluções por padrão: $(Get-TextoChave $chaves.CloudFlows)"

Set-BizappSaida -Nome 'Conta' -Valor $ctx.Identidade.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $ctx.Identidade.TenantId
Set-BizappSaida -Nome 'NomeAmbiente' -Valor $ctx.Nome
Set-BizappSaida -Nome 'EnvironmentId' -Valor $ctx.EnvironmentId
Set-BizappSaida -Nome 'PapelAdmin' -Valor $(if ($ctx.AdminSistema) { 'Administrador do sistema' } else { 'Sem o papel Administrador do sistema' })
Set-BizappSaida -Nome 'EstadoCanvas' -Valor (Get-TextoChave $chaves.CanvasApps)
Set-BizappSaida -Nome 'EstadoFluxos' -Valor (Get-TextoChave $chaves.CloudFlows)

Write-ResumoSolucoes -Pasta $pasta -Acao 'Consultar' -Ctx $ctx -Aprovada $true -Alterou $false -Detalhe 'Consulta concluída.' `
    -Extras ([ordered]@{ CanvasApps = $chaves.CanvasApps; CloudFlows = $chaves.CloudFlows })
