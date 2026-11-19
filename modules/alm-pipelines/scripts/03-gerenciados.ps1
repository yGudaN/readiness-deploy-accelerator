#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-09 · Tornar HML e PROD gerenciados (o pipeline exige destinos gerenciados). Usa a mesma
    chamada validada no item 10. So muda o que ainda nao e gerenciado e confere relendo.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AlmPipelines.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'IdHml', 'IdProd'

$id = Connect-AlmPipelines -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Gerenciados'
$alterou = $false
$falhas = @()
$linhas = foreach ($c in 'HML', 'PROD') {
    $idAmb = if ($c -eq 'HML') { [string]$entrada.IdHml } else { [string]$entrada.IdProd }
    $antes = Get-Ambiente $idAmb
    $depois = $antes
    if ($antes.Gerenciado) { Write-BizappLog "$c ($($antes.Nome)) já é gerenciado." -Nivel sucesso }
    else {
        Write-BizappLog "Tornando $c ($($antes.Nome)) gerenciado..."
        Write-BizappProgresso -Percentual $(if ($c -eq 'HML') { 25 } else { 75 }) -Fase "Tornando $c gerenciado"
        $depois = Set-AmbienteGerenciado -Id $idAmb
        $alterou = $true
        if ($depois.Gerenciado) { Write-BizappLog "$c agora é gerenciado. Conferido no Power Platform." -Nivel sucesso }
        else { $falhas += "$c ainda não aparece como gerenciado" }
    }
    [pscustomobject]@{ Camada = $c; Nome = $antes.Nome; EnvironmentId = $idAmb; GerenciadoAntes = $antes.Gerenciado; GerenciadoDepois = $depois.Gerenciado }
}
Write-BizappProgresso -Percentual 100 -Fase 'Concluído'
Export-BizappEvidencia -Pasta $pasta -Nome 'gerenciados.csv' -Dados @($linhas)
$faltam = @($linhas | Where-Object { -not $_.GerenciadoDepois } | ForEach-Object Camada)
Set-BizappSaida -Nome 'Gerenciados' -Valor $(if ($faltam) { "Falta: $($faltam -join ', ')" } else { 'HML e PROD gerenciados' })

$aprovada = -not $falhas
Write-ResumoAlm -Pasta $pasta -Acao 'Gerenciados' -Identidade $id -Aprovada $aprovada -Alterou $alterou `
    -Detalhe $(if ($aprovada) { 'HML e PROD gerenciados.' } else { "A conferência falhou: $($falhas -join '; '). Confira no admin center e rode de novo." })
