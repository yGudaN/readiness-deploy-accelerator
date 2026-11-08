#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-22 · Consultar (somente leitura): conta, funcao, licencas e estado dos grupos
    Copilot-Premium e Copilot-Geral, com pacote de evidencias. Nao altera nada.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GruposCopilot.psm1') -Force
$entrada = Read-BizappEntrada
$inicio = Get-Date

$ctx = Connect-GruposCopilot -Entrada $entrada
$id = $ctx.Identidade
Write-BizappLog "Conta: $($id.Conta) · funções: $(($ctx.Funcoes.Funcao | Sort-Object -Unique) -join ', ')" -Nivel sucesso
Write-BizappLog "Tenant: $($id.TenantId)"
# Confirmados aqui; as proximas etapas abortam se o login for de outro tenant ou conta
Set-BizappSaida -Nome 'Conta' -Valor $id.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $id.TenantId

$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
$licencas = Get-InventarioLicencas
Export-BizappEvidencia -Pasta $pasta -Nome 'funcoes-administrativas.csv' -Dados $ctx.Funcoes
Export-BizappEvidencia -Pasta $pasta -Nome 'licencas-tenant.csv' -Dados $licencas.Evidencia
$copilot = @($licencas.Evidencia | Where-Object CandidataCopilot)
Write-BizappLog "Licenças com Copilot no tenant: $(if ($copilot) { ($copilot | ForEach-Object { "$($_.SkuPartNumber) ($($_.UnidadesDisponiveis) disponíveis)" }) -join ', ' } else { 'nenhuma' })"

$defs = Get-DefinicoesGrupos
$grupos = @(Get-GroupSnapshot -GroupDefinitions $defs -SubscribedSkus $licencas.Skus)
$membros = @(Get-MemberSnapshot -GroupDefinitions $defs)
Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-antes.csv' -Dados $grupos
Export-BizappEvidencia -Pasta $pasta -Nome 'membros-antes.csv' -Dados $membros
Export-BizappEvidencia -Pasta $pasta -Nome 'acoes.csv' -Dados ([pscustomobject]@{ DataHora = (Get-Date).ToString('o'); Acao = 'Consultar'; Grupo = 'Ambos'; ObjetoId = $null; Resultado = 'Consulta concluída; nenhuma alteração executada' })

Write-ResumoGrupos -Snapshot $grupos -Membros $membros
$notas = @($defs | Where-Object { -not ($grupos | Where-Object NomeConsultado -eq $_.DisplayName) } | ForEach-Object { "A consulta não produziu registro para $($_.DisplayName)." })
Write-ResumoExecucao -Pasta $pasta -Acao 'Consultar' -Identidade $id -Alterou $false -Aprovada (-not $notas) -Notas $notas -Inicio $inicio
