#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-31 · AplicarRetencao: cria ou atualiza a politica de retencao de auditoria dos eventos do
    Copilot (CopilotInteraction) e confere o resultado. Tambem remove a politica (acao nova; no
    teste foi feita a mao com Remove-UnifiedAuditLogRetentionPolicy).
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AuditoriaCopilot.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'AcaoRetencao', 'NomePolitica'

$acaoRetencao = [string]$entrada.AcaoRetencao
if ($acaoRetencao -notin 'aplicar', 'remover') { throw "Ação inválida: $acaoRetencao" }
$nome = ([string]$entrada.NomePolitica).Trim()
if ($nome -notmatch '^[\w .-]{1,64}$') { throw 'Nome da política inválido: use letras, números, espaço, ponto, hífen ou sublinhado (até 64).' }

if ($acaoRetencao -eq 'aplicar') {
    $duracao = [string]$entrada.DuracaoRetencao
    if ($duracao -notin 'ThreeMonths', 'SixMonths', 'NineMonths', 'TwelveMonths', 'TenYears') { throw "Duração inválida: $duracao" }
    $prioridade = 0
    if (-not [int]::TryParse([string]$entrada.Prioridade, [ref]$prioridade) -or $prioridade -lt 1 -or $prioridade -gt 10000) {
        throw 'Prioridade inválida: use um número de 1 a 10000.'
    }
} elseif (([string]$entrada.ConfirmacaoRetencao).Trim() -cne 'CONFIRMO') {
    throw 'Para remover a política, digite CONFIRMO no campo de confirmação. Nada foi alterado.'
}
$acao = if ($acaoRetencao -eq 'aplicar') { 'AplicarRetencao' } else { 'RemoverRetencao' }

try {
    $ctx = Connect-AuditoriaCopilot -Entrada $entrada
    $pasta = New-BizappEvidencias -Item $ITEM -Acao $acao
    Write-ContextoAuditoria -Pasta $pasta -Ctx $ctx -Acao $acao -Extras ([ordered]@{
            NomePolitica = $nome; DuracaoRetencao = $(if ($acao -eq 'AplicarRetencao') { $duracao }); Prioridade = $(if ($acao -eq 'AplicarRetencao') { $prioridade }) })

    $antes = Get-PoliticasRetencao
    Export-PoliticasRetencao -Pasta $pasta -Nome 'politicas-antes.csv' -Politicas $antes
    $existente = Find-PoliticaPorNome -Politicas $antes -Nome $nome

    $alterou = $false
    if ($acao -eq 'AplicarRetencao') {
        if (-not $ctx.TemPremium) {
            throw 'Nenhuma licença com auditoria premium (ex.: Microsoft 365 E5 ou Office 365 E5) foi encontrada na conta administrativa. A política não foi aplicada.'
        }
        $mesmo = $existente -and [string]$existente.RetentionDuration -eq $duracao -and [int]$existente.Priority -eq $prioridade -and
            (@(([string]$existente.RecordTypes).Split(';')) -contains 'CopilotInteraction')
        # A prioridade e unica no tenant: outra politica com o mesmo numero faz o Purview recusar
        # ("Priority needs to be unique"). Para antes, dizendo qual politica usa e um numero livre.
        $ocupada = @($antes) | Where-Object {
            [int]$_.Priority -eq $prioridade -and -not [string]::Equals([string]$_.Name, $nome, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if ($ocupada) {
            $usadas = @($antes | ForEach-Object { [int]$_.Priority })
            $livre = $prioridade
            while ($livre -in $usadas -and $livre -lt 10000) { $livre++ }
            Set-BizappSaida -Nome 'Prioridade' -Valor "$livre"
            throw "A prioridade $prioridade já é usada pela política '$($ocupada.Name)'. Cada política precisa de uma prioridade diferente: o campo foi trocado para $livre, que está livre. Aplique de novo (ou remova a outra política no Microsoft Purview). Nada foi alterado."
        }
        if ($mesmo) {
            Write-BizappLog "A política '$nome' já existe com estes valores: nada foi alterado." -Nivel sucesso
        } else {
            Write-BizappLog "$(if ($existente) { 'Atualizando' } else { 'Criando' }) a política '$nome' ($(Get-TextoDuracao $duracao), prioridade $prioridade)..."
            $resultado = Set-PoliticaRetencaoCopilot -Nome $nome -Duracao $duracao -Prioridade $prioridade -Existente $existente
            $alterou = $true
            Write-BizappLog "Política $($resultado.ToLower())." -Nivel sucesso
        }
    } else {
        if (-not $existente) {
            Write-BizappLog "A política '$nome' não existe: nada foi alterado." -Nivel sucesso
        } else {
            Write-BizappLog "Removendo a política '$nome'..."
            Remove-PoliticaRetencaoCopilot -Existente $existente
            $alterou = $true
        }
    }

    $depois = Get-PoliticasRetencao
    Export-PoliticasRetencao -Pasta $pasta -Nome 'politicas-depois.csv' -Politicas $depois
    $final = Find-PoliticaPorNome -Politicas $depois -Nome $nome
    $aprovada = if ($acao -eq 'AplicarRetencao') {
        $null -ne $final -and [string]$final.RetentionDuration -eq $duracao -and [int]$final.Priority -eq $prioridade -and
            (@(([string]$final.RecordTypes).Split(';')) -contains 'CopilotInteraction')
    } else {
        $null -eq $final
    }
    if ($aprovada -and $alterou) { Write-BizappLog 'Resultado conferido no tenant.' -Nivel sucesso }
    if ($acao -eq 'AplicarRetencao' -and $aprovada) {
        Write-BizappLog 'Pode levar alguns minutos para a política aparecer no portal do Microsoft Purview (Auditoria > Políticas).' -Nivel discreto
    }
    Set-BizappSaida -Nome 'PoliticaCopilot' -Valor (Get-TextoPolitica -Politicas $depois -Nome $nome)
    Set-BizappSaida -Nome 'PoliticasRetencao' -Valor "$($depois.Count)"

    Write-ResumoAuditoria -Pasta $pasta -Acao $acao -Ctx $ctx -Aprovada $aprovada -Alterou $alterou -Extras ([ordered]@{
            PoliticasAntes = $antes.Count; PoliticasDepois = $depois.Count; NomePolitica = $nome
            DuracaoRetencao = $(if ($acao -eq 'AplicarRetencao') { $duracao }); Prioridade = $(if ($acao -eq 'AplicarRetencao') { $prioridade }) })
} finally {
    Disconnect-AuditoriaCopilot
}
