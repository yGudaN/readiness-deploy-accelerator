#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-31 · HabilitarUAL / DesabilitarUAL: liga ou desliga a auditoria unificada do tenant.
    Ligar quando ja esta ligada (ou desligar quando ja esta desligada) nao altera nada.
    Desligar exige digitar CONFIRMO.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AuditoriaCopilot.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'AcaoAuditoria'

$ligar = switch ([string]$entrada.AcaoAuditoria) {
    'ligar' { $true }
    'desligar' { $false }
    default { throw "Ação inválida: $($entrada.AcaoAuditoria)" }
}
if (-not $ligar -and ([string]$entrada.ConfirmacaoRisco).Trim() -cne 'CONFIRMO') {
    throw 'Para desligar a auditoria, digite CONFIRMO no campo de confirmação. Nada foi alterado.'
}
$acao = if ($ligar) { 'HabilitarUAL' } else { 'DesabilitarUAL' }

try {
    $ctx = Connect-AuditoriaCopilot -Entrada $entrada
    $pasta = New-BizappEvidencias -Item $ITEM -Acao $acao
    Write-ContextoAuditoria -Pasta $pasta -Ctx $ctx -Acao $acao

    $antes = Get-ConfiguracaoUal
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-antes.csv' -Dados $antes
    $estavaLigada = $antes.UnifiedAuditLogIngestionEnabled -eq $true

    $alterou = $false
    if ($estavaLigada -eq $ligar) {
        Write-BizappLog "A auditoria já estava $(if ($ligar) { 'ligada' } else { 'desligada' }): nada foi alterado." -Nivel sucesso
    } else {
        if ($ligar) {
            Write-BizappLog 'Ligando a auditoria...'
        } else {
            Write-BizappLog 'Desligando a auditoria. Enquanto estiver desligada, nada é registrado no log de auditoria do tenant.' -Nivel aviso
        }
        Set-IngestaoUal -Ligada $ligar
        $alterou = $true
    }

    $depois = Get-ConfiguracaoUal
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-depois.csv' -Dados $depois
    $ficouLigada = $depois.UnifiedAuditLogIngestionEnabled -eq $true

    # Ligar pode levar ate 60 min para aparecer (no teste, a leitura logo depois ainda dizia desligada)
    $pendente = $ligar -and $alterou -and -not $ficouLigada
    $aprovada = ($ficouLigada -eq $ligar) -or $pendente
    $texto = if ($pendente) { 'Ligando (pode levar até 60 min)' } elseif ($ficouLigada) { 'Ligada' } else { 'Desligada' }
    if ($pendente) {
        Write-BizappLog 'Pedido aceito. A Microsoft leva até 60 minutos para ligar a auditoria; rode a consulta de novo depois para confirmar.' -Nivel aviso
    } elseif ($aprovada -and $alterou) {
        Write-BizappLog "Auditoria $($texto.ToLower()) e conferida." -Nivel sucesso
    }
    Set-BizappSaida -Nome 'Auditoria' -Valor $texto

    Write-ResumoAuditoria -Pasta $pasta -Acao $acao -Ctx $ctx -Aprovada $aprovada -Alterou $alterou -Extras ([ordered]@{
            UalAntes = $antes.UnifiedAuditLogIngestionEnabled; UalDepois = $depois.UnifiedAuditLogIngestionEnabled
            AguardandoPropagacao = $pendente })
} finally {
    Disconnect-AuditoriaCopilot
}
