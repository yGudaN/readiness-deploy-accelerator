#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-11 · Instalar um idioma da lista aprovada (ProvisionLanguageAsync). A instalacao e
    assincrona (pode levar ate 1 hora), nao muda o idioma base e nao e desfeita por este item.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ConfiguracoesDataverse.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl', 'TenantId', 'Conta', 'Idioma'

$lcid = [int]$entrada.Idioma
if (-not (Test-IdiomaAprovado $lcid)) { throw "Idioma fora da lista aprovada: $lcid. Nada foi alterado." }
$nome = Get-NomeIdioma $lcid

$ctx = Connect-ConfiguracoesDataverse -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Idioma'
Write-ContextoDataverse -Pasta $pasta -Ctx $ctx -Acao 'Idioma' -Extras ([ordered]@{ Idioma = $lcid })
Write-AvisoAdmin -Ctx $ctx

$antes = Get-IdiomasAmbiente
Export-BizappEvidencia -Pasta $pasta -Nome 'idiomas-antes.csv' -Dados @(@($antes.Disponiveis + $antes.Instalados + $lcid) | Sort-Object -Unique | ForEach-Object {
        [pscustomobject]@{ LCID = $_; Instalado = ($_ -in $antes.Instalados); PacoteNoServidor = ($_ -in $antes.Disponiveis) } })

$alterou = $false
if ($lcid -in $antes.Instalados) {
    $detalhe = "$nome já estava instalado; nada foi alterado."
    $estado = "$nome · instalado"
    Write-BizappLog $detalhe -Nivel sucesso
    $aprovada = $true
} else {
    # O pacote pode ainda nao estar baixado no servidor (versao 0.0 no admin center): o ambiente
    # baixa durante a instalacao. Se recusar, o erro do Dataverse aparece e nada e alterado.
    if ($lcid -notin $antes.Disponiveis) { Write-BizappLog "O pacote de $nome ainda não está baixado no ambiente; ele é baixado durante a instalação." -Nivel discreto }
    Write-BizappLog "Pedindo a instalação de $nome..."
    $r = Invoke-Dataverse -Metodo POST -Caminho 'ProvisionLanguageAsync' -Corpo @{ Language = $lcid }
    $alterou = $true
    $aprovada = $true
    $detalhe = "Instalação de $nome pedida. Ela roda em segundo plano e pode levar até 1 hora; o idioma base não muda."
    $estado = "$nome · instalação pedida (até 1 hora)"
    Write-BizappLog $detalhe -Nivel sucesso
    if ($r.AsyncOperationId) { Write-BizappLog "Operação $($r.AsyncOperationId)." -Nivel discreto }
    Write-BizappLog 'Depois de instalado, cada usuário escolhe o idioma em Configurações > Opções pessoais > Idiomas.' -Nivel discreto
}
Set-BizappSaida -Nome 'EstadoIdioma' -Valor $estado

Write-ResumoDataverse -Pasta $pasta -Acao 'Idioma' -Ctx $ctx -Aprovada $aprovada -Alterou $alterou -Detalhe $detalhe -Extras ([ordered]@{ Idioma = $lcid })
