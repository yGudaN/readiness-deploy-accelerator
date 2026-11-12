#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-31 · Consultar (somente leitura): auditoria unificada ligada ou nao, politicas de retencao
    de auditoria, licencas da conta e eventos do Copilot dos ultimos N dias.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AuditoriaCopilot.psm1') -Force
$entrada = Read-BizappEntrada
$dias = [int]$(if ($entrada.DiasPesquisa) { $entrada.DiasPesquisa } else { 7 })
if ($dias -lt 1 -or $dias -gt 180) { throw "Período inválido: $dias dias (de 1 a 180)." }
$nomePolitica = $(if ($entrada.NomePolitica) { [string]$entrada.NomePolitica } else { 'Retencao-Auditoria-Copilot' })

# Primeira etapa: ainda nao ha conta confirmada, entao vale a do login
$id = Get-BizappIdentidade -Token (Get-BizappToken -Entrada $entrada -Nome Graph)
$entrada.TenantId = $id.TenantId
$entrada.Conta = $id.Conta

try {
    $ctx = Connect-AuditoriaCopilot -Entrada $entrada
    $pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
    Write-ContextoAuditoria -Pasta $pasta -Ctx $ctx -Acao 'Consultar' -Extras @{ DiasPesquisa = $dias }

    Write-BizappLog 'Lendo a configuração da auditoria...'
    $config = Get-ConfiguracaoUal
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-antes.csv' -Dados $config
    $ligada = $config.UnifiedAuditLogIngestionEnabled -eq $true

    Write-BizappLog 'Lendo as políticas de retenção de auditoria...'
    $politicas = Get-PoliticasRetencao
    Export-PoliticasRetencao -Pasta $pasta -Nome 'politicas-antes.csv' -Politicas $politicas

    $eventos = @()
    $mensagem = 'Auditoria desligada; pesquisa não executada.'
    if ($ligada) {
        Write-BizappLog "Pesquisando eventos do Copilot dos últimos $dias dias (pode levar alguns minutos)..."
        $eventos = Search-EventosCopilot -Dias $dias
        $mensagem = if ($eventos.Count) { 'Consulta concluída com eventos encontrados.' } else { 'Consulta concluída sem eventos. Resultado zero não representa falha.' }
    }
    if ($eventos.Count) {
        Export-BizappEvidencia -Pasta $pasta -Nome 'eventos-copilot.csv' -Dados $eventos
    } else {
        Export-BizappEvidencia -Pasta $pasta -Nome 'eventos-copilot.csv' -Dados ([pscustomobject]@{
                DataHoraUtc = (Get-Date).ToUniversalTime(); Resultado = 'Sem registros'; Quantidade = 0; Observacao = $mensagem })
    }

    $textoAuditoria = if ($ligada) { 'Ligada' } else { 'Desligada' }
    $textoEventos = if ($ligada) { "$($eventos.Count) nos últimos $dias dias" } else { 'Não pesquisados (auditoria desligada)' }
    Write-BizappLog "Auditoria: $textoAuditoria" -Nivel $(if ($ligada) { 'sucesso' } else { 'aviso' })
    Write-BizappLog "Eventos do Copilot: $textoEventos"
    Write-BizappLog "Políticas de retenção de auditoria: $($politicas.Count)"
    if (-not $ctx.TemPremium) {
        Write-BizappLog 'A conta não tem licença com auditoria premium (ex.: Microsoft 365 E5): a política de retenção não poderá ser criada.' -Nivel aviso
    }
    Write-BizappLog 'O conteúdo das conversas (prompts, respostas e arquivos) não é lido nem exportado.' -Nivel discreto

    Set-BizappSaida -Nome 'Conta' -Valor $ctx.Identidade.Conta
    Set-BizappSaida -Nome 'TenantId' -Valor $ctx.Identidade.TenantId
    Set-BizappSaida -Nome 'Auditoria' -Valor $textoAuditoria
    Set-BizappSaida -Nome 'LicencaAuditoria' -Valor $(if ($ctx.TemPremium) { 'Encontrada' } else { 'Não encontrada' })
    Set-BizappSaida -Nome 'PoliticaCopilot' -Valor (Get-TextoPolitica -Politicas $politicas -Nome $nomePolitica)
    Set-BizappSaida -Nome 'PoliticasRetencao' -Valor "$($politicas.Count)"
    Set-BizappSaida -Nome 'EventosCopilot' -Valor $textoEventos

    Write-ResumoAuditoria -Pasta $pasta -Acao 'Consultar' -Ctx $ctx -Aprovada $true -Alterou $false -Extras ([ordered]@{
            UalAntes = $config.UnifiedAuditLogIngestionEnabled; UalDepois = $config.UnifiedAuditLogIngestionEnabled
            StatusPesquisa = $(if ($ligada) { 'Concluída' } else { 'Ignorada' }); MensagemPesquisa = $mensagem
            EventosEncontrados = $eventos.Count; PoliticasAntes = $politicas.Count; PoliticasDepois = $politicas.Count; DiasPesquisa = $dias })
} finally {
    Disconnect-AuditoriaCopilot
}
