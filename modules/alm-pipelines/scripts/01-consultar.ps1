#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-09 · Consultar (somente leitura): ambientes do tenant e regiao do tenant (onde fica o host
    da plataforma). Sugere DEV, HML e PROD criados pelo item 10, se houver.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AlmPipelines.psm1') -Force
$entrada = Read-BizappEntrada

$id = Connect-AlmPipelines -Entrada $entrada -PrimeiraEtapa
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
Write-BizappLog "Conta: $($id.Conta)"

$ambientes = Get-Ambientes
Export-BizappEvidencia -Pasta $pasta -Nome 'ambientes.csv' -Dados $ambientes
$padrao = $ambientes | Where-Object Tipo -eq 'Default' | Select-Object -First 1
$regiaoTenant = if ($padrao) { $padrao.Regiao } else { '' }
Write-BizappLog "Região do tenant (onde fica o host dos pipelines): $regiaoTenant"
Write-BizappLog 'Ambientes que podem entrar no pipeline (com Dataverse):'
$comDataverse = @($ambientes | Where-Object UrlDataverse | Sort-Object Nome)
foreach ($a in $comDataverse) { Write-BizappLog "  $(Get-TextoAmbiente $a)" -Nivel discreto }

$sug = Get-SugestoesDoItem10 -Ambientes $ambientes -TenantId $id.TenantId
if ($sug.Count) { Write-BizappLog "Sugestão (criados pelo item Ambientes DEV, HML e PROD): $(($sug.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name) = $($_.Value)" }) -join '; ')" -Nivel sucesso }

Set-BizappSaida -Nome 'Conta' -Valor $id.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $id.TenantId
Set-BizappSaida -Nome 'RegiaoTenant' -Valor $regiaoTenant
Set-BizappSaida -Nome 'AmbientesDisponiveis' -Valor $(if ($comDataverse) { ($comDataverse | ForEach-Object { "$($_.Nome) ($($_.Regiao))" }) -join '; ' } else { 'Nenhum com Dataverse' })
# Preenche os campos da proxima etapa com a sugestao (o usuario pode trocar)
if ($sug.DEV) { Set-BizappSaida -Nome 'AmbienteDev' -Valor $sug.DEV }
if ($sug.HML) { Set-BizappSaida -Nome 'AmbienteHml' -Valor $sug.HML }
if ($sug.PROD) { Set-BizappSaida -Nome 'AmbienteProd' -Valor $sug.PROD }

Write-ResumoAlm -Pasta $pasta -Acao 'Consultar' -Identidade $id -Aprovada $true -Alterou $false -Detalhe 'Consulta concluída.' `
    -Extras ([ordered]@{ Ambientes = $ambientes.Count; ComDataverse = $comDataverse.Count; RegiaoTenant = $regiaoTenant })
