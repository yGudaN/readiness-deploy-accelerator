#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-20 · CriarModelo: cria o que falta dos 5 objetos do modelo. O que ja existe nao e
    alterado. Acesso Condicional em modo de relatorio e DLP do Purview em teste.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ModeloProtecao.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'Prefixo'
$nomes = Get-NomesModelo -Prefixo ([string]$entrada.Prefixo).Trim()
$justificativa = 'Executado pelo Readiness Deploy Accelerator'

try {
    $ctx = Connect-ModeloProtecao -Entrada $entrada
    $pasta = New-BizappEvidencias -Item $ITEM -Acao 'CriarModelo'
    Write-EvidenciasModelo -Pasta $pasta -Ctx $ctx -Acao 'CriarModelo' -Justificativa $justificativa -Nomes $nomes

    $antes = Read-EstadoModelo -Ctx $ctx -Nomes $nomes
    Save-EstadoJson -Pasta $pasta -Nome 'configuracao-antes.json' -Estado $antes

    $acoes = [System.Collections.Generic.List[object]]::new()
    New-ModeloProtecao -Ctx $ctx -Nomes $nomes -Estado $antes -Acoes $acoes -Justificativa $justificativa

    Start-Sleep -Seconds 5
    $depois = Read-EstadoModelo -Ctx $ctx -Nomes $nomes
    Save-EstadoJson -Pasta $pasta -Nome 'configuracao-depois.json' -Estado $depois
    $null = Write-EstadoSaidas -Estado $depois -Ctx $ctx
    Write-BizappLog 'A distribuição de DLP e rótulos é assíncrona e pode levar algumas horas para chegar aos aplicativos.' -Nivel discreto

    Write-ResumoModelo -Pasta $pasta -Acao 'CriarModelo' -Ctx $ctx -Acoes $acoes -Justificativa $justificativa -ResultadoEsperado $(
        if ($ctx.Purview) { 'Objetos do modelo existentes; Acesso Condicional em modo de relatório; DLP do Purview em teste.' }
        else { 'Power Platform e Acesso Condicional criados; componentes do Purview bloqueados.' })
} finally {
    Disconnect-ModeloProtecao
}
