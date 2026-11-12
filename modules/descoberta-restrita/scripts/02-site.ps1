#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-16 · Habilitar / Desabilitar a descoberta restrita em UM site e conferir o resultado.
    Site ja no estado pedido nao e alterado. Site fora do tenant, OneDrive ou admin center e bloqueado.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DescobertaRestrita.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'SiteUrl', 'AcaoRcd'

$ligar = switch ([string]$entrada.AcaoRcd) {
    'ligar' { $true }
    'desligar' { $false }
    default { throw "Ação inválida: $($entrada.AcaoRcd)" }
}
$acao = if ($ligar) { 'Habilitar' } else { 'Desabilitar' }
$justificativa = "Executado pelo Readiness Deploy Accelerator ($acao)"

try {
    $ctx = Connect-DescobertaRestrita -Entrada $entrada
    $site = Get-SiteNormalizado -Url ([string]$entrada.SiteUrl) -Ctx $ctx
    $pasta = New-BizappEvidencias -Item $ITEM -Acao $acao
    Write-ContextoRcd -Pasta $pasta -Ctx $ctx -Acao $acao -Site $site -Justificativa $justificativa

    $antes = Get-RcdSiteState -Identity $site
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-antes.csv' -Dados $antes
    Write-BizappLog "$($antes.SiteTitle): hoje · $(Get-TextoRcd $antes.RestrictContentOrgWideSearch)"

    $depois = $antes; $alterou = $false
    if ([bool]$antes.RestrictContentOrgWideSearch -eq $ligar) {
        Write-BizappLog 'O site já está no estado pedido: nada foi alterado.' -Nivel sucesso
    } else {
        Write-BizappLog "$(if ($ligar) { 'Ligando' } else { 'Desligando' }) a descoberta restrita..."
        try {
            $depois = Set-RcdSite -Site $site -Ligar $ligar
            $alterou = $true
        } catch {
            $msg = if (Test-ErroSemSam $_) { $MENSAGEM_SEM_SAM } else { $_.Exception.Message }
            Write-ResumoRcd -Pasta $pasta -Site $site -Acao $acao -Antes $antes -Depois $antes -Alterou $false -Aprovada $false -Justificativa $justificativa -Erro $_.Exception.Message
            Set-BizappSaida -Nome 'EstadoSite' -Valor "$($antes.SiteTitle) · $(Get-TextoRcd $antes.RestrictContentOrgWideSearch)"
            if (Test-ErroSemSam $_) { Write-BizappLog "Detalhe do SharePoint: $($_.Exception.Message)" -Nivel discreto }
            throw $msg
        }
    }
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-depois.csv' -Dados $depois
    $aprovada = [bool]$depois.RestrictContentOrgWideSearch -eq $ligar
    Set-BizappSaida -Nome 'EstadoSite' -Valor "$($depois.SiteTitle) · $(Get-TextoRcd $depois.RestrictContentOrgWideSearch)"
    Write-ResumoRcd -Pasta $pasta -Site $site -Acao $acao -Antes $antes -Depois $depois -Alterou $alterou -Aprovada $aprovada -Justificativa $justificativa
    if (-not $aprovada) { throw 'O comando foi enviado, mas o SharePoint não confirmou o novo estado depois de 6 tentativas. Rode a consulta mais tarde para conferir.' }
    if ($alterou) {
        Write-BizappLog 'Alterado e conferido. As permissões do site não mudaram.' -Nivel sucesso
        Write-BizappLog 'A pesquisa e o Copilot levam um tempo para refletir a mudança (em sites grandes, pode passar de um dia).' -Nivel discreto
    }
} finally {
    Disconnect-DescobertaRestrita
}
