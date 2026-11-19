#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-35 · Consultar (somente leitura): conta e workspaces do Power BI que a conta acessa.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PowerBiKpis.psm1') -Force
$entrada = Read-BizappEntrada

$id = Connect-PowerBiKpis -Entrada $entrada -PrimeiraEtapa
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
Write-BizappLog "Conta: $($id.Conta)"

$ws = Get-Workspaces
Export-BizappEvidencia -Pasta $pasta -Nome 'workspaces.csv' -Dados @($ws | ForEach-Object { [pscustomobject]@{ Nome = $_.name; Id = $_.id; Capacidade = $_.isOnDedicatedCapacity } })
if ($ws.Count) {
    Write-BizappLog "Workspaces que a conta acessa: $($ws.Count)" -Nivel sucesso
    foreach ($w in ($ws | Sort-Object name)) { Write-BizappLog "  $($w.name) · $($w.id)" -Nivel discreto }
} else {
    Write-BizappLog 'A conta não acessa nenhum workspace compartilhado. Crie um em app.powerbi.com (o "Meu workspace" não serve).' -Nivel aviso
}

Set-BizappSaida -Nome 'Conta' -Valor $id.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $id.TenantId
Set-BizappSaida -Nome 'ListaWorkspaces' -Valor $(if ($ws.Count) { ($ws | Sort-Object name | ForEach-Object name) -join '; ' } else { 'Nenhum' })
Write-ResumoPowerBi -Pasta $pasta -Acao 'Consultar' -Identidade $id -Aprovada $true -Alterou $false -Detalhe 'Consulta concluída.' -Extras ([ordered]@{ Workspaces = $ws.Count })
