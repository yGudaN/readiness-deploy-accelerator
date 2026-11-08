#Requires -Version 7.4
<#
.SYNOPSIS
    Mostra a conta, o tenant e o estado atual do Environment Routing. Nao altera nada.
    Se o roteamento ja estiver ligado, ja deixa marcada na proxima etapa a opcao atual.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ConfiguracoesTenant.psm1') -Force
$entrada = Read-BizappEntrada
$token = Get-BizappToken -Entrada $entrada -Nome PowerPlatformAdmin

$quem = Get-ContaDoToken -Token $token
Write-BizappLog "Conta: $($quem.Conta)" -Nivel sucesso
Write-BizappLog "Tenant: $($quem.TenantId)"
Set-BizappSaida -Nome 'Conta' -Valor $quem.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $quem.TenantId

$estado = Get-EstadoRoteamento -Token $token
Write-BizappLog "Environment Routing hoje: $($estado.Texto)"
Set-BizappSaida -Nome 'RoteamentoAntes' -Valor $estado.Texto
Set-BizappSaida -Nome 'EstadoAtual' -Valor $estado.Texto
if ($estado.Ligado) {
    # Saida com o mesmo id do campo: a proxima etapa ja abre com a opcao atual marcada
    Set-BizappSaida -Nome 'QuemRotear' -Valor $estado.Quem
    Write-BizappLog 'O roteamento já está ligado. Na próxima etapa a opção atual já vem marcada: avance sem mudar nada ou troque quem é roteado.' -Nivel aviso
}
