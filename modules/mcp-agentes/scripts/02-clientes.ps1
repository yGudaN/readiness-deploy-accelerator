#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-12 · Liberar ou bloquear um cliente de MCP no ambiente (tabela allowedmcpclient, coluna
    isenabled) e conferir relendo. Exige digitar CONFIRMO. Os clientes do Copilot Studio nao sao
    bloqueados por aqui, porque isso desliga o MCP do Dataverse nos agentes do ambiente.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'McpAgentes.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl', 'TenantId', 'Conta', 'ClienteMcp', 'AcaoCliente'

# A confirmacao vale para uma execucao so
$confirmou = ([string]$entrada.ConfirmacaoClientes).Trim() -ceq 'CONFIRMO'
Set-BizappSaida -Nome 'ConfirmacaoClientes' -Valor ''
if (-not $confirmou) { throw 'Revise o cliente e a ação e digite CONFIRMO no campo de confirmação. Nada foi alterado.' }
$liberar = [string]$entrada.AcaoCliente -eq 'liberar'
$textoAcao = if ($liberar) { 'Liberar' } else { 'Bloquear' }

$ctx = Connect-McpAgentes -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao $textoAcao
Write-ContextoMcp -Pasta $pasta -Ctx $ctx -Acao $textoAcao -Extras ([ordered]@{ ClientePedido = $entrada.ClienteMcp })
Write-AvisoAdmin -Ctx $ctx

$conjunto = Get-ConjuntoClientes
$antes = Get-ClientesMcp -Conjunto $conjunto
Export-BizappEvidencia -Pasta $pasta -Nome 'clientes-mcp-antes.csv' -Dados $antes
$cliente = Find-ClienteMcp -Clientes $antes -Texto ([string]$entrada.ClienteMcp)
Write-BizappLog "Cliente: $($cliente.Nome) ($($cliente.NomeUnico)) · hoje $(if ($cliente.Liberado) { 'liberado' } else { 'bloqueado' })"
if (-not $liberar -and (Test-ClienteCopilotStudio $cliente)) {
    throw "O cliente $($cliente.Nome) é o próprio Copilot Studio: bloqueá-lo desliga o MCP do Dataverse nos agentes do ambiente. Se for mesmo necessário, faça no admin center. Nada foi alterado."
}

$alterou = $false
if ($cliente.Liberado -eq $liberar) {
    Write-BizappLog "O cliente já estava $(if ($liberar) { 'liberado' } else { 'bloqueado' }); nada foi alterado." -Nivel sucesso
} else {
    Set-ClienteMcp -Conjunto $conjunto -Cliente $cliente -Liberado $liberar
    $alterou = $true
}

$depois = Get-ClientesMcp -Conjunto $conjunto
Export-BizappEvidencia -Pasta $pasta -Nome 'clientes-mcp-depois.csv' -Dados $depois
$conferido = @($depois | Where-Object { $_.Id -eq $cliente.Id })[0]
$aprovada = $null -ne $conferido -and $conferido.Liberado -eq $liberar
$detalhe = "$($cliente.Nome) $(if ($conferido.Liberado) { 'liberado' } else { 'bloqueado' })."
if ($aprovada -and $alterou) {
    Write-BizappLog "Alterado e conferido: $detalhe" -Nivel sucesso
    if ($liberar) {
        Write-BizappLog 'Para clientes fora do Copilot Studio, o MCP do Dataverse também precisa estar permitido nas configurações do ambiente (Produto > Recursos > Dataverse Model Context Protocol).' -Nivel discreto
    }
}

Set-BizappSaida -Nome 'ClientesLiberados' -Valor (Get-TextoClientes -Clientes $depois -Liberado $true)
Set-BizappSaida -Nome 'ClientesBloqueados' -Valor (Get-TextoClientes -Clientes $depois -Liberado $false)

Write-ResumoMcp -Pasta $pasta -Acao $textoAcao -Ctx $ctx -Aprovada $aprovada -Alterou $alterou -Detalhe $detalhe `
    -Extras ([ordered]@{ Cliente = $cliente.Nome; NomeUnico = $cliente.NomeUnico; LiberadoAntes = $cliente.Liberado; LiberadoDepois = $conferido.Liberado })
