#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-33 · Habilitar / Desabilitar / Reverter (e voltar para modo de relatorio).
    Mesmas travas do script validado:
      - Habilitar exige politica valida, conta de emergencia e confirmacao de risco;
      - Reverter (excluir) exige politica com o desenho esperado e confirmacao de risco;
      - acao que ja esta no estado pedido e ignorada (idempotente).
    "relatorio" (voltar para modo de relatorio) nao existia no original: e o mesmo PATCH de
    estado, para desfazer um Habilitar sem excluir a politica.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MfaCopilot.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'NovoEstado'
$inicio = Get-Date

$acoesValidas = @{
    habilitar   = @{ Acao = 'Habilitar'; Estado = 'enabled' }
    relatorio   = @{ Acao = 'VoltarReportOnly'; Estado = $ESTADO_RELATORIO }
    desabilitar = @{ Acao = 'Desabilitar'; Estado = 'disabled' }
    excluir     = @{ Acao = 'Reverter'; Estado = $null }
}
$pedido = $acoesValidas[[string]$entrada.NovoEstado]
if (-not $pedido) { throw "Opção inválida: $($entrada.NovoEstado)" }
$acao = $pedido.Acao

# Confirmacao de risco (no original: HABILITAR-MFA-COPILOT / REMOVER-MFA-COPILOT)
if ($acao -in 'Habilitar', 'Reverter' -and ([string]$entrada.ConfirmacaoRisco).Trim() -cne 'CONFIRMO') {
    throw 'Para ligar ou excluir a política, digite CONFIRMO no campo de confirmação. Nada foi alterado.'
}
if ($acao -eq 'Habilitar' -and -not @(ConvertTo-ListaContas -Texto $entrada.ContasEmergencia).Count) {
    throw 'Para ligar a política, informe pelo menos uma conta de emergência (ela fica fora da política). Nada foi alterado.'
}

$id = Connect-MfaCopilot -Entrada $entrada -Alteracao
$pasta = New-BizappEvidencias -Item $ITEM -Acao $acao
$ctx = Get-ContextoMfa -Identidade $id -ContasEmergencia $entrada.ContasEmergencia -Pasta $pasta -Acao $acao
$idsGrupos = @(Get-IdsGruposEsperados -Grupos $ctx.Grupos)
$antes = Test-PoliticaMfa -Politica $ctx.Politica -IdsGrupos $idsGrupos -IdsExcluidosObrigatorios $ctx.IdsExcluidos

$acoes = [System.Collections.Generic.List[object]]::new()
$alterou = $false
$idPolitica = $(if ($ctx.Politica) { [string]$ctx.Politica.Id } else { $ctx.IdReferencia })

if ($acao -eq 'Reverter') {
    if ($null -eq $ctx.Politica) {
        $acoes.Add((New-RegistroAcao -Acao $acao -Status 'Ignorado' -Detalhe 'Política já ausente.'))
        Write-BizappLog 'A política já não existe: nada foi alterado.' -Nivel sucesso
    } else {
        if (-not $antes.CoreConfigurationValid) {
            throw "Exclusão bloqueada: a política não corresponde ao desenho criado por este item ($($antes.Divergencias -join '; ')). Nada foi alterado."
        }
        Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $ctx.Politica.Id -Confirm:$false -ErrorAction Stop
        $alterou = $true
        $acoes.Add((New-RegistroAcao -Acao $acao -Status 'Sucesso' -Detalhe 'Política removida.'))
        Write-BizappLog 'Política excluída.' -Nivel sucesso
    }
} else {
    if ($null -eq $ctx.Politica) { throw 'A política ainda não existe. Crie-a na etapa anterior.' }
    if ($acao -ne 'Desabilitar' -and -not $antes.CoreConfigurationValid) {
        throw "A política diverge do desenho esperado ($($antes.Divergencias -join '; ')). Nada foi alterado."
    }
    if ($antes.State -eq $pedido.Estado) {
        $acoes.Add((New-RegistroAcao -Acao $acao -Status 'Ignorado' -Detalhe "Política já em $($pedido.Estado)."))
        Write-BizappLog "A política já está assim ($(Get-TextoEstado $pedido.Estado)): nada foi alterado." -Nivel sucesso
    } else {
        Write-BizappLog "Mudando a política para: $(Get-TextoEstado $pedido.Estado)..."
        Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $ctx.Politica.Id -BodyParameter @{ State = $pedido.Estado } -ErrorAction Stop
        $alterou = $true
        $acoes.Add((New-RegistroAcao -Acao $acao -Status 'Sucesso' -Detalhe "State=$($pedido.Estado)."))
    }
}

Write-BizappLog 'Validando o estado posterior (até 90 segundos)...' -Nivel discreto
$deveExistir = $acao -ne 'Reverter'
$depois = @(Wait-PoliticaMfa -DeveExistir $deveExistir -IdPreferido $idPolitica -EstadoEsperado $pedido.Estado)
if ($depois.Count -gt 1) { throw 'A validação posterior encontrou políticas duplicadas.' }
$politicaDepois = if ($depois.Count -eq 1) { $depois[0] } else { $null }
$avaliacao = Test-PoliticaMfa -Politica $politicaDepois -IdsGrupos $idsGrupos -IdsExcluidosObrigatorios $ctx.IdsExcluidos
Write-EstadoPolitica -Politica $politicaDepois -Avaliacao $avaliacao

$aprovada = switch ($acao) {
    'Reverter' { $depois.Count -eq 0 }
    'Desabilitar' { $depois.Count -eq 1 -and $avaliacao.State -eq 'disabled' }
    default { $depois.Count -eq 1 -and $avaliacao.CoreConfigurationValid -and $avaliacao.State -eq $pedido.Estado }
}
if ($acao -eq 'Reverter' -and $aprovada) { Remove-ReferenciaPolitica -TenantId $id.TenantId }
if ($acao -eq 'Habilitar' -and $aprovada) {
    Write-BizappLog 'A política está LIGADA: os membros dos dois grupos passam a precisar de MFA para entrar no Office 365.' -Nivel aviso
}
Write-ResumoMfa -Pasta $pasta -Acao $acao -Identidade $id -Acoes $acoes -PoliticasDepois $depois -AvaliacaoAntes $antes -AvaliacaoDepois $avaliacao `
    -Alterou $alterou -Aprovada $aprovada -Nota $(if (-not $aprovada) { 'O estado posterior não corresponde ao esperado.' }) -Inicio $inicio
