#Requires -Version 7.4
<#
.SYNOPSIS
    Liga o Environment Routing no tenant (COE-IA-003) com a opcao escolhida e confere se a
    alteracao foi gravada. Se o tenant ja estiver exatamente assim, nao altera nada.

.NOTES
    Segue o documento: liga enableDefaultEnvironmentRouting, sem criar regras de roteamento.
    A necessidade de regras esta em aberto (ver PENDENCIAS.md na raiz do repositorio).
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ConfiguracoesTenant.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'QuemRotear'
$token = Get-BizappToken -Entrada $entrada -Nome PowerPlatformAdmin

$NOMES = @{ novos = 'só makers novos'; todos = 'makers novos e existentes' }
$desejado = $entrada.QuemRotear
$atual = Get-EstadoRoteamento -Token $token

if ($atual.Ligado -and $atual.Quem -eq $desejado) {
    Write-BizappLog "Já está configurado assim: $($atual.Texto). Nada foi alterado." -Nivel sucesso
} else {
    Write-BizappLog "Hoje: $($atual.Texto)."
    Write-BizappLog "Passando para: Ligado, para $($NOMES[$desejado])."
    Set-GovernancaTenant -Token $token -Valores @{
        enableDefaultEnvironmentRouting = $true
        environmentRoutingAllMakers     = ($desejado -eq 'todos')
    }

    # A alteracao pode levar alguns segundos para aparecer na leitura
    for ($i = 1; $i -le 6; $i++) {
        Start-Sleep -Seconds 5
        $atual = Get-EstadoRoteamento -Token $token
        if ($atual.Ligado -and $atual.Quem -eq $desejado) { break }
    }
    if (-not ($atual.Ligado -and $atual.Quem -eq $desejado)) {
        throw "A alteração não foi gravada (o tenant está: $($atual.Texto)). Confira se a conta é Administrador do Power Platform e tente de novo."
    }
    Write-BizappLog "Validado: $($atual.Texto)." -Nivel sucesso
}

Set-BizappSaida -Nome 'RoteamentoDepois' -Valor $atual.Texto
