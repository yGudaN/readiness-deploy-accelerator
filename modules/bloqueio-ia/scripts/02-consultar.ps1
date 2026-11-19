#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-27 · Consultar (somente leitura, so GET): indicadores do Defender para os dominios
    informados. Nenhuma alteracao.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BloqueioIa.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'DefenderClientId'

$dominios = Get-Dominios $entrada.Dominios
$id = Connect-BloqueioIa -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
Write-BizappLog "Consultando no Defender: $($dominios -join ', ')"
$ind = Get-Indicadores -Dominios $dominios
Export-BizappEvidencia -Pasta $pasta -Nome 'indicadores.csv' -Dados $ind
$texto = Get-TextoIndicadores -Indicadores $ind -Dominios $dominios
Write-BizappLog "Indicadores: $texto" -Nivel sucesso
Write-BizappLog 'Nenhuma alteração foi executada.' -Nivel discreto

Set-BizappSaida -Nome 'EstadoBloqueio' -Valor $texto
Set-BizappSaida -Nome 'Conta' -Valor $id.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $id.TenantId
Write-ResumoBloqueio -Pasta $pasta -Acao 'Consultar' -Identidade $id -Aprovada $true -Alterou $false -Detalhe 'Consulta concluída.' `
    -Extras ([ordered]@{ Dominios = ($dominios -join ';'); Indicadores = $ind.Count })
