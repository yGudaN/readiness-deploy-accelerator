#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-20 · HabilitarModelo / DesabilitarModelo / ReverterModelo. Ligar e remover exigem CONFIRMO:
    ligado, o Acesso Condicional passa a exigir MFA da conta admin em todos os apps.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ModeloProtecao.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'Prefixo', 'AcaoModelo'
$nomes = Get-NomesModelo -Prefixo ([string]$entrada.Prefixo).Trim()

$acao = switch ([string]$entrada.AcaoModelo) {
    'ligar' { 'HabilitarModelo' }
    'desligar' { 'DesabilitarModelo' }
    'remover' { 'ReverterModelo' }
    default { throw "Ação inválida: $($entrada.AcaoModelo)" }
}
if ($acao -ne 'DesabilitarModelo' -and ([string]$entrada.ConfirmacaoModelo).Trim() -cne 'CONFIRMO') {
    throw 'Para ligar ou remover o modelo, digite CONFIRMO no campo de confirmação. Nada foi alterado.'
}
$justificativa = "Executado pelo Readiness Deploy Accelerator ($acao)"

try {
    $ctx = Connect-ModeloProtecao -Entrada $entrada
    $pasta = New-BizappEvidencias -Item $ITEM -Acao $acao
    Write-EvidenciasModelo -Pasta $pasta -Ctx $ctx -Acao $acao -Justificativa $justificativa -Nomes $nomes

    $antes = Read-EstadoModelo -Ctx $ctx -Nomes $nomes
    Save-EstadoJson -Pasta $pasta -Nome 'configuracao-antes.json' -Estado $antes

    $acoes = [System.Collections.Generic.List[object]]::new()
    switch ($acao) {
        'HabilitarModelo' {
            Write-BizappLog "Ligando: a partir de agora a conta $($ctx.Identidade.Conta) precisa de MFA em todos os apps." -Nivel aviso
            Set-EstadoModelo -Ctx $ctx -Nomes $nomes -Estado $antes -Acoes $acoes -Ligar $true -Justificativa $justificativa
        }
        'DesabilitarModelo' { Set-EstadoModelo -Ctx $ctx -Nomes $nomes -Estado $antes -Acoes $acoes -Ligar $false -Justificativa $justificativa }
        'ReverterModelo' { Remove-ModeloProtecao -Ctx $ctx -Estado $antes -Acoes $acoes }
    }

    Start-Sleep -Seconds 5
    $depois = Read-EstadoModelo -Ctx $ctx -Nomes $nomes
    Save-EstadoJson -Pasta $pasta -Nome 'configuracao-depois.json' -Estado $depois
    $t = Write-EstadoSaidas -Estado $depois -Ctx $ctx
    if ($acao -eq 'ReverterModelo' -and ($t.EstadoDlpPurview -ne 'Não existe' -or $t.EstadoRotulo -ne 'Não existe') -and $ctx.Purview) {
        Write-BizappLog 'O Purview ainda lista objetos removidos: a exclusão costuma terminar em alguns minutos. Rode a consulta depois para conferir.' -Nivel aviso
    }

    Write-ResumoModelo -Pasta $pasta -Acao $acao -Ctx $ctx -Acoes $acoes -Justificativa $justificativa -ResultadoEsperado $(switch ($acao) {
            'HabilitarModelo' { 'Acesso Condicional ligado; DLP do Purview ligada; rótulo publicado para a conta admin.' }
            'DesabilitarModelo' { 'Acesso Condicional desligado; DLP do Purview desligada; rótulo tirado da política.' }
            'ReverterModelo' { 'Nenhum objeto do modelo depois da remoção (o Purview pode levar minutos).' } })
} finally {
    Disconnect-ModeloProtecao
}
