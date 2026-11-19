#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-05 · Consultar os Copilot Credits disponiveis para o ambiente escolhido (secao 6 do
    original). Somente leitura.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CopilotCredits.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta'

$id = Connect-CopilotCredits -Entrada $entrada -ComApi
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
$Environment = Find-Ambiente -Ambientes (Get-Ambientes) -Texto $entrada.Ambiente
Write-BizappLog "Ambiente      : $($Environment.Nome)" -Nivel sucesso
Write-BizappLog "Environment ID: $($Environment.EnvironmentId)" -Nivel sucesso
Write-BizappLog "Tipo          : $($Environment.Tipo)" -Nivel sucesso

$d = Get-Disponibilidade -EnvironmentId $Environment.EnvironmentId
($d.Resposta | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $pasta 'disponibilidade.json') -Encoding utf8
if ($null -eq $d.Disponivel) {
    Write-BizappLog 'A API respondeu, mas MCSMessages (Copilot Credits) não foi encontrado. A resposta está em disponibilidade.json nas evidências.' -Nivel aviso
} else {
    Write-BizappLog "Copilot Credits disponíveis para alocar: $(Format-Creditos $d.Disponivel)" -Nivel sucesso
}

# O que ja esta alocado neste ambiente (a disponibilidade nao mostra isso)
$atual = Get-AlocacaoAmbiente -EnvironmentId $Environment.EnvironmentId
if ($atual) {
    if ($atual.Resposta) { ($atual.Resposta | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $pasta 'alocacao-atual.json') -Encoding utf8 }
    Write-BizappLog "Já alocado neste ambiente: $(Format-Creditos $atual.Alocado)" -Nivel sucesso
    Write-BizappLog "Quando a alocação se esgotar: $(Format-TenantPool $atual.TenantPool)"
}

Set-BizappSaida -Nome 'NomeAmbiente' -Valor $Environment.Nome
Set-BizappSaida -Nome 'IdAmbiente' -Valor $Environment.EnvironmentId
Set-BizappSaida -Nome 'CreditosDisponiveis' -Valor (Format-Creditos $d.Disponivel)
Set-BizappSaida -Nome 'AlocadoAtual' -Valor $(if ($atual) { Format-Creditos $atual.Alocado } else { 'Não foi possível ler' })
Set-BizappSaida -Nome 'TenantPoolAtual' -Valor $(if ($atual) { Format-TenantPool $atual.TenantPool } else { '' })
Write-ResumoCredits -Pasta $pasta -Acao 'Consultar' -Identidade $id -Aprovada $true -Alterou $false -Detalhe 'Leitura concluída. Nenhuma alteração foi realizada.' `
    -Extras ([ordered]@{ Ambiente = $Environment.Nome; EnvironmentId = $Environment.EnvironmentId; Disponivel = $d.Disponivel; AlocadoAtual = $(if ($atual) { $atual.Alocado }) })
