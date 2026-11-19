#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-12 · Consultar (somente leitura): ambiente e papel da conta, clientes de MCP liberados,
    conectores personalizados do ambiente e politicas de DLP do tenant. Nada e alterado.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'McpAgentes.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl'

$ctx = Connect-McpAgentes -Entrada $entrada -PrimeiraEtapa
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
Write-ContextoMcp -Pasta $pasta -Ctx $ctx -Acao 'Consultar'
Write-BizappLog "Ambiente: $($ctx.Nome) · Environment ID $($ctx.EnvironmentId)" -Nivel sucesso
Write-AvisoAdmin -Ctx $ctx

# Clientes de MCP
$conjunto = Get-ConjuntoClientes
$clientes = Get-ClientesMcp -Conjunto $conjunto
Export-BizappEvidencia -Pasta $pasta -Nome 'clientes-mcp.csv' -Dados $clientes
$liberados = Get-TextoClientes -Clientes $clientes -Liberado $true
$bloqueados = Get-TextoClientes -Clientes $clientes -Liberado $false
Write-BizappLog "Clientes de MCP no ambiente: $($clientes.Count)"
Write-BizappLog "Liberados: $liberados"
Write-BizappLog "Bloqueados: $bloqueados"

# Conectores personalizados
$conectores = Get-ConectoresPersonalizados
Export-BizappEvidencia -Pasta $pasta -Nome 'conectores.csv' -Dados $conectores
$textoConectores = if ($conectores.Count) { "$($conectores.Count): $((@($conectores | ForEach-Object { $_.NomeExibicao }) -join ', '))" } else { 'Nenhum' }
Write-BizappLog "Conectores personalizados no ambiente: $textoConectores"

# Politicas de DLP do tenant
$tokenPp = Get-BizappToken -Entrada $entrada -Nome PowerPlatform
$politicas = Get-PoliticasDlp -TokenPp $tokenPp
$textoDlp = if ($null -eq $politicas) { 'Não foi possível ler' }
elseif ($politicas.Count) { "$($politicas.Count): $((@($politicas | ForEach-Object { $_.NomeExibicao }) -join ', '))" }
else { 'Nenhuma' }
if ($null -ne $politicas) {
    Export-BizappEvidencia -Pasta $pasta -Nome 'politicas-dlp.csv' -Dados @($politicas | Select-Object Nome, NomeExibicao)
    @($politicas | ForEach-Object { $_.Bruto }) | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $pasta 'politicas-dlp-bruto.json') -Encoding utf8
}
Write-BizappLog "Políticas de DLP no tenant: $textoDlp"
if ($null -ne $politicas -and -not $politicas.Count) {
    Write-BizappLog 'Sem política de DLP, qualquer conector (inclusive um conector MCP personalizado) fica liberado para agentes e fluxos.' -Nivel aviso
}

Set-BizappSaida -Nome 'Conta' -Valor $ctx.Identidade.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $ctx.Identidade.TenantId
Set-BizappSaida -Nome 'NomeAmbiente' -Valor $ctx.Nome
Set-BizappSaida -Nome 'EnvironmentId' -Valor $ctx.EnvironmentId
Set-BizappSaida -Nome 'PapelAdmin' -Valor $(if ($ctx.AdminSistema) { 'Administrador do sistema' } else { 'Sem o papel Administrador do sistema' })
Set-BizappSaida -Nome 'ClientesLiberados' -Valor $liberados
Set-BizappSaida -Nome 'ClientesBloqueados' -Valor $bloqueados
Set-BizappSaida -Nome 'Conectores' -Valor $textoConectores
Set-BizappSaida -Nome 'PoliticasDlp' -Valor $textoDlp

Write-ResumoMcp -Pasta $pasta -Acao 'Consultar' -Ctx $ctx -Aprovada $true -Alterou $false -Detalhe 'Consulta concluída.' `
    -Extras ([ordered]@{ ClientesMcp = $clientes.Count; ClientesLiberados = $liberados; ClientesBloqueados = $bloqueados; Conectores = $textoConectores; PoliticasDlp = $textoDlp })
