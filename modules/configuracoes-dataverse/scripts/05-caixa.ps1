#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-11 · Ligar ou desligar a entrada e a saida de e-mail de uma caixa de correio
    (enabledforincomingemail / enabledforoutgoingemail) e conferir relendo. Nao aprova o
    endereco nem testa a caixa: isso continua no Power Platform admin center.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ConfiguracoesDataverse.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl', 'TenantId', 'Conta', 'AcaoCaixa'

$email = ([string]$entrada.EmailCaixa).Trim()
if (-not $email) { throw 'Informe o e-mail da caixa de correio. Nada foi alterado.' }
$ligar = switch ([string]$entrada.AcaoCaixa) { 'ligar' { $true } 'desligar' { $false } default { throw "Ação inválida: $($entrada.AcaoCaixa)" } }

$ctx = Connect-ConfiguracoesDataverse -Entrada $entrada
$rotuloAcao = if ($ligar) { 'Ligar-Caixa' } else { 'Desligar-Caixa' }
$pasta = New-BizappEvidencias -Item $ITEM -Acao $rotuloAcao
Write-ContextoDataverse -Pasta $pasta -Ctx $ctx -Acao $rotuloAcao -Extras ([ordered]@{ Caixa = $email })
Write-AvisoAdmin -Ctx $ctx

# Get-Caixas devolve a lista como um objeto so: guardar numa variavel antes de filtrar
function Find-Caixa { $todas = Get-Caixas; $todas | Where-Object { [string]::Equals($_.emailaddress, $email, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1 }
function Get-Snapshot([object]$Cx, [string]$Etapa) {
    [pscustomobject]@{ Etapa = $Etapa; Email = $email; Existe = [bool]$Cx; Entrada = $Cx.enabledforincomingemail; Saida = $Cx.enabledforoutgoingemail
        Aprovacao = $Cx.emailrouteraccessapproval; StatusEntrada = $Cx.incomingemailstatus; StatusSaida = $Cx.outgoingemailstatus; MailboxId = $Cx.mailboxid }
}

$antes = Find-Caixa
Export-BizappEvidencia -Pasta $pasta -Nome 'caixa-antes.csv' -Dados (Get-Snapshot $antes 'Antes')
if (-not $antes) { throw "Caixa de correio $email não encontrada no ambiente. Nada foi alterado." }
Write-BizappLog "Antes: $(Get-TextoCaixa $antes)"

$alterou = $false
if ([bool]$antes.enabledforincomingemail -eq $ligar -and [bool]$antes.enabledforoutgoingemail -eq $ligar) {
    $detalhe = "A entrada e a saída já estavam $(if ($ligar) { 'ligadas' } else { 'desligadas' }); nada foi alterado."
    Write-BizappLog $detalhe -Nivel sucesso
    $depois = $antes
} else {
    Write-BizappLog "$(if ($ligar) { 'Ligando' } else { 'Desligando' }) a entrada e a saída de e-mail..."
    $null = Invoke-Dataverse -Metodo PATCH -Caminho "mailboxes($($antes.mailboxid))" -Corpo @{ enabledforincomingemail = $ligar; enabledforoutgoingemail = $ligar }
    $alterou = $true
    $depois = Find-Caixa
    $detalhe = "Entrada e saída de e-mail $(if ($ligar) { 'ligadas' } else { 'desligadas' }) em $email."
}
Export-BizappEvidencia -Pasta $pasta -Nome 'caixa-depois.csv' -Dados (Get-Snapshot $depois 'Depois')
$aprovada = [bool]$depois.enabledforincomingemail -eq $ligar -and [bool]$depois.enabledforoutgoingemail -eq $ligar
if ($aprovada -and $alterou) { Write-BizappLog "$detalhe Conferido no ambiente." -Nivel sucesso }
if ($ligar -and [int]$depois.emailrouteraccessapproval -ne 1) {
    Write-BizappLog 'O endereço ainda não está aprovado: aprove e teste a caixa no Power Platform admin center para o e-mail começar a funcionar.' -Nivel aviso
}
Set-BizappSaida -Nome 'EstadoCaixa' -Valor (Get-TextoCaixa $depois)

Write-ResumoDataverse -Pasta $pasta -Acao $rotuloAcao -Ctx $ctx -Aprovada $aprovada -Alterou $alterou -Detalhe $detalhe -Extras ([ordered]@{ Caixa = $email })
