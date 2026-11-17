#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-13 · Ativar ou desativar (secoes 4 e 5 do roteiro) a criacao de canvas apps e cloud flows
    em solucoes por padrao no ambiente, e conferir relendo (secao 6). Exige digitar SIM, como o
    roteiro. Muda so a criacao futura: nada que ja existe muda de lugar.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SolucoesPorPadrao.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl', 'TenantId', 'Conta', 'CanvasApps', 'CloudFlows'

# A confirmacao vale para uma execucao so
$confirmou = ([string]$entrada.ConfirmacaoSolucoes).Trim() -ceq 'SIM'
Set-BizappSaida -Nome 'ConfirmacaoSolucoes' -Valor ''
if (-not $confirmou) { throw 'Revise os valores e digite SIM no campo de confirmação. Nada foi alterado.' }
$canvas = [string]$entrada.CanvasApps -eq 'sim'
$fluxos = [string]$entrada.CloudFlows -eq 'sim'

$ctx = Connect-SolucoesPorPadrao -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Aplicar'
Write-ContextoSolucoes -Pasta $pasta -Ctx $ctx -Acao 'Aplicar' -Extras ([ordered]@{ CanvasAppsDesejado = $canvas; CloudFlowsDesejado = $fluxos })
Write-AvisoAdmin -Ctx $ctx

$antes = Get-Chaves
Export-BizappEvidencia -Pasta $pasta -Nome 'chaves-antes.csv' -Dados $antes
Write-BizappLog "Ambiente: $($ctx.Nome) · Environment ID $($ctx.EnvironmentId)"
Write-BizappLog "Apps de tela em soluções: $(Get-TextoChave $antes.CanvasApps) → $(Get-TextoChave $canvas)"
Write-BizappLog "Fluxos da nuvem em soluções: $(Get-TextoChave $antes.CloudFlows) → $(Get-TextoChave $fluxos)"
if ($canvas -and -not $antes.CanvasApps) {
    Write-BizappLog 'Apps de tela em soluções por padrão ainda é recurso em versão prévia (Preview) da Microsoft: avalie antes de ligar em produção.' -Nivel aviso
}

$depois = Set-Chaves -Atual $antes -CanvasApps $canvas -CloudFlows $fluxos
$alterou = $null -ne $depois
if (-not $alterou) { $depois = $antes; Write-BizappLog 'Os valores já estavam assim; nada foi alterado.' -Nivel sucesso }
Export-BizappEvidencia -Pasta $pasta -Nome 'chaves-depois.csv' -Dados $depois

$aprovada = $depois.CanvasApps -eq $canvas -and $depois.CloudFlows -eq $fluxos
$detalhe = "Apps de tela $(Get-TextoChave $depois.CanvasApps), fluxos da nuvem $(Get-TextoChave $depois.CloudFlows)."
if ($aprovada -and $alterou) {
    Write-BizappLog "Alterado e conferido: $detalhe" -Nivel sucesso
    Write-BizappLog 'Vale para o que for criado daqui em diante: apps e fluxos que já existem não mudam de lugar.' -Nivel discreto
}
Set-BizappSaida -Nome 'EstadoCanvas' -Valor (Get-TextoChave $depois.CanvasApps)
Set-BizappSaida -Nome 'EstadoFluxos' -Valor (Get-TextoChave $depois.CloudFlows)

Write-ResumoSolucoes -Pasta $pasta -Acao 'Aplicar' -Ctx $ctx -Aprovada $aprovada -Alterou $alterou -Detalhe $detalhe `
    -Extras ([ordered]@{ CanvasAppsAntes = $antes.CanvasApps; CanvasAppsDepois = $depois.CanvasApps; CloudFlowsAntes = $antes.CloudFlows; CloudFlowsDepois = $depois.CloudFlows })
