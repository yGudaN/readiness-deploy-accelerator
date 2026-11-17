#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-10 · Consultar (somente leitura): conta, ambientes do tenant (tipo, regiao, Dataverse,
    Managed Environment) e capacidade de banco de dados usada por ambiente.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ProvisionamentoAmbientes.psm1') -Force
$entrada = Read-BizappEntrada

$id = Connect-Provisionamento -Entrada $entrada -PrimeiraEtapa
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
Write-ContextoProvisionamento -Pasta $pasta -Identidade $id -Acao 'Consultar'
Write-BizappLog "Conta: $($id.Conta)"

Write-BizappLog 'Lendo os ambientes...'
$ambientes = Set-AmbientesDoItem -Ambientes (Get-Ambientes) -TenantId $id.TenantId
Export-BizappEvidencia -Pasta $pasta -Nome 'ambientes.csv' -Dados $ambientes
foreach ($a in ($ambientes | Sort-Object Nome)) {
    Write-BizappLog "  $(Get-TextoAmbiente $a)$(if ($a.CriadoPorEsteItem) { " · criado por este item$(if ($a.Camada) { " ($($a.Camada))" })" })" -Nivel discreto
}
$doItem = @($ambientes | Where-Object CriadoPorEsteItem)
$padrao = $ambientes | Where-Object Tipo -eq 'Default' | Select-Object -First 1

$capacidade = Get-CapacidadeUsada
Export-BizappEvidencia -Pasta $pasta -Nome 'capacidade-usada.csv' -Dados $capacidade
$bancoMb = [math]::Round((@($capacidade | Where-Object Tipo -eq 'Database') | Measure-Object UsadoMB -Sum).Sum, 0)
Write-BizappLog "Banco de dados usado pelos ambientes: $bancoMb MB. Cada ambiente novo com Dataverse precisa de 1 GB livre: confira o total em Licenças > Capacidade no admin center." -Nivel discreto

$textoAmbientes = "$($ambientes.Count) ($(@($ambientes | Where-Object UrlDataverse).Count) com Dataverse, $(@($ambientes | Where-Object Gerenciado).Count) gerenciados)"
Write-BizappLog "Ambientes: $textoAmbientes" -Nivel sucesso

Set-BizappSaida -Nome 'Conta' -Valor $id.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $id.TenantId
Set-BizappSaida -Nome 'Ambientes' -Valor $textoAmbientes
Set-BizappSaida -Nome 'AmbientesDoItem' -Valor (Get-TextoAmbientesDoItem $ambientes)
Set-BizappSaida -Nome 'RegiaoPadrao' -Valor $(if ($padrao) { $padrao.Regiao } else { '' })
Set-BizappSaida -Nome 'BancoUsado' -Valor "$bancoMb MB"

Write-ResumoProvisionamento -Pasta $pasta -Acao 'Consultar' -Identidade $id -Aprovada $true -Alterou $false -Detalhe 'Consulta concluída.' `
    -Extras ([ordered]@{ Ambientes = $ambientes.Count; AmbientesDoItem = $doItem.Count })
