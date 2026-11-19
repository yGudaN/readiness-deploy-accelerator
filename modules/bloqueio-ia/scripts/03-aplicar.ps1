#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-27 · Bloquear (ou avisar) os dominios no Defender, com expiracao obrigatoria e
    justificativa, ou remover os indicadores criados por este item. Indicadores de outra origem
    nunca sao alterados nem removidos. Exige digitar CONFIRMO.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BloqueioIa.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'DefenderClientId', 'AcaoBloqueio'

$confirmou = ([string]$entrada.ConfirmacaoBloqueio).Trim() -ceq 'CONFIRMO'
Set-BizappSaida -Nome 'ConfirmacaoBloqueio' -Valor ''
if (-not $confirmou) { throw 'Esta ação afeta os dispositivos do tenant: digite CONFIRMO no campo de confirmação. Nada foi alterado.' }
$acao = [string]$entrada.AcaoBloqueio
if ($acao -notin 'bloquear', 'avisar', 'remover') { throw "Ação inválida: $acao" }
$dominios = Get-Dominios $entrada.Dominios
$justificativa = ([string]$entrada.Justificativa).Trim()
if ($acao -ne 'remover' -and $justificativa.Length -lt 10) { throw 'Escreva a justificativa da mudança (pelo menos 10 caracteres). Nada foi alterado.' }
$dias = 0
if ($acao -ne 'remover' -and (-not [int]::TryParse(([string]$entrada.ExpiracaoDias).Trim(), [ref]$dias) -or $dias -lt 1 -or $dias -gt 365)) { throw 'Informe a expiração em dias (1 a 365). Nada foi alterado.' }
$grupos = @(([string]$entrada.GruposDispositivos) -split ';' | ForEach-Object Trim | Where-Object { $_ })

$id = Connect-BloqueioIa -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao $acao
$antes = Get-Indicadores -Dominios $dominios
Export-BizappEvidencia -Pasta $pasta -Nome 'indicadores-antes.csv' -Dados $antes

$acoes = [System.Collections.Generic.List[object]]::new()
$falhas = @()
foreach ($d in $dominios) {
    $existentes = @($antes | Where-Object Dominio -eq $d)
    $deOutros = @($existentes | Where-Object { -not $_.CriadoPorEsteItem })
    if ($acao -eq 'remover') {
        $meus = @($existentes | Where-Object CriadoPorEsteItem)
        if (-not $meus) { Write-BizappLog "$d · nenhum indicador deste item; nada a remover." -Nivel discreto }
        foreach ($i in $meus) { Remove-Indicador $i.Id; $acoes.Add([pscustomobject]@{ Dominio = $d; Operacao = 'DELETE'; Id = $i.Id }); Write-BizappLog "$d · indicador removido." -Nivel sucesso }
        if ($deOutros) { Write-BizappLog "$d · há $($deOutros.Count) indicador(es) de outra origem, mantido(s)." -Nivel aviso }
    } else {
        if ($deOutros) { Write-BizappLog "$d · já existe um indicador de outra origem ($($deOutros[0].Acao)). Ele não será alterado." -Nivel aviso; continue }
        $expira = (Get-Date).AddDays($dias)
        $r = Set-Indicador -Dominio $d -Acao $(if ($acao -eq 'avisar') { 'Warn' } else { 'Block' }) -Expira $expira -Justificativa $justificativa -Grupos $grupos
        $acoes.Add([pscustomobject]@{ Dominio = $d; Operacao = 'POST'; Id = $r.id; Acao = $r.action; Expira = $expira.ToString('o') })
        Write-BizappLog "$d · $(if ($acao -eq 'avisar') { 'aviso' } else { 'bloqueio' }) até $($expira.ToString('dd/MM/yyyy'))$(if ($grupos) { " para $($grupos -join ', ')" } else { ' para todos os dispositivos' })." -Nivel sucesso
    }
}
Export-BizappEvidencia -Pasta $pasta -Nome 'acoes.csv' -Dados @($acoes)

Start-Sleep -Seconds 3
$depois = Get-Indicadores -Dominios $dominios
Export-BizappEvidencia -Pasta $pasta -Nome 'indicadores-depois.csv' -Dados $depois
foreach ($a in $acoes) {
    $ainda = $depois | Where-Object Id -eq $a.Id
    if ($a.Operacao -eq 'DELETE' -and $ainda) { $falhas += "$($a.Dominio) ainda aparece" }
    if ($a.Operacao -eq 'POST' -and -not $ainda) { $falhas += "$($a.Dominio) não aparece depois de criar" }
}
$texto = Get-TextoIndicadores -Indicadores $depois -Dominios $dominios
Set-BizappSaida -Nome 'EstadoBloqueio' -Valor $texto
if ($acao -ne 'remover' -and $acoes.Count) {
    Write-BizappLog 'O bloqueio só vale nos dispositivos com o Defender for Endpoint e com indicadores de rede personalizados ligados (Configurações > Endpoints > Recursos avançados). Pode levar algumas horas para chegar aos dispositivos.' -Nivel discreto
}
$aprovada = -not $falhas
Write-ResumoBloqueio -Pasta $pasta -Acao $acao -Identidade $id -Aprovada $aprovada -Alterou ($acoes.Count -gt 0) `
    -Detalhe $(if ($aprovada) { "Concluído: $texto" } else { "A conferência encontrou: $($falhas -join '; ')" }) `
    -Extras ([ordered]@{ Dominios = ($dominios -join ';'); Justificativa = $justificativa; ExpiracaoDias = $dias; Grupos = ($grupos -join ';') })
