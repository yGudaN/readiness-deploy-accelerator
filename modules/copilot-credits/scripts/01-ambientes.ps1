#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-05 · Login e lista de ambientes (somente leitura), como as secoes 4 e 5 do original.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CopilotCredits.psm1') -Force
$entrada = Read-BizappEntrada

$id = Connect-CopilotCredits -Entrada $entrada -PrimeiraEtapa
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Ambientes'
Write-BizappLog "Conta     : $($id.Conta)" -Nivel sucesso
Write-BizappLog "Tenant ID : $($id.TenantId)" -Nivel sucesso

$ambientes = Get-Ambientes
if ($ambientes.Count -eq 0) { throw 'Nenhum ambiente encontrado.' }
Export-BizappEvidencia -Pasta $pasta -Nome 'ambientes.csv' -Dados $ambientes
foreach ($a in $ambientes) { Write-BizappLog "  $($a.Nome) · $($a.Tipo) · $($a.EnvironmentId)" -Nivel discreto }

Set-BizappSaida -Nome 'Conta' -Valor $id.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $id.TenantId
Set-BizappSaida -Nome 'ListaAmbientes' -Valor (($ambientes | ForEach-Object Nome) -join '; ')
Set-BizappSaida -Nome 'QtdAmbientes' -Valor "$($ambientes.Count) ambientes"
Write-ResumoCredits -Pasta $pasta -Acao 'Ambientes' -Identidade $id -Aprovada $true -Alterou $false -Detalhe 'Consulta concluída.' -Extras ([ordered]@{ Ambientes = $ambientes.Count })
