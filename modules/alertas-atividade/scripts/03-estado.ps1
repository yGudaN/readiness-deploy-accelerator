#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-30 · Habilitar / Desabilitar (e remover, acao nova): muda o estado da politica de alerta
    criada por este item e confere pela consulta posterior. Politicas padrao da Microsoft ou
    criadas por outras pessoas nunca sao alteradas. Remover exige digitar CONFIRMO.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AlertasAtividade.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'NomeAlerta', 'NovoEstado'

$nome = ([string]$entrada.NomeAlerta).Trim()
$novo = [string]$entrada.NovoEstado
$acao = switch ($novo) {
    'ligar' { 'Habilitar' }
    'desligar' { 'Desabilitar' }
    'remover' { 'Remover' }
    default { throw "Ação inválida: $novo" }
}
if ($acao -eq 'Remover' -and ([string]$entrada.ConfirmacaoRemocao).Trim() -cne 'CONFIRMO') {
    throw 'Para remover a política, digite CONFIRMO no campo de confirmação. Nada foi alterado.'
}

try {
    $ctx = Connect-AlertasAtividade -Entrada $entrada
    $pasta = New-BizappEvidencias -Item $ITEM -Acao $acao
    Write-ContextoAlertas -Pasta $pasta -Ctx $ctx -Acao $acao -Extras ([ordered]@{ AlertName = $nome })

    $antes = Find-AlertaPorNome -Alertas (Get-AlertasTenant) -Nome $nome
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-antes.csv' -Dados (Get-AlertSnapshot -Alert $antes -Stage 'Antes' -Nome $nome)
    if (-not $antes) { throw "A política '$nome' não existe. Nada foi alterado." }
    if (-not (Test-AlertaDoItem $antes)) {
        throw "A política '$nome' não foi criada por este item (é padrão da Microsoft ou de outra pessoa). Ela não será alterada."
    }
    $permitido = if ($acao -eq 'Remover') { $ctx.PodeRemover } else { $ctx.PodeAlterar }
    if (-not $permitido) {
        throw 'A conta não tem permissão para alterar políticas de alerta (função Manage Alerts ou Organization Configuration no Microsoft Purview). Nada foi alterado.'
    }

    $alterou = $false
    $estavaDesligada = [string]$antes.Disabled -eq 'True'
    switch ($acao) {
        'Habilitar' {
            if (-not $estavaDesligada) { $detalhe = 'A política já estava habilitada; nenhuma alteração foi executada.' }
            else { Write-BizappLog "Ligando '$nome'..."; Set-AlertaLigado -Alerta $antes -Ligado $true; $alterou = $true; $detalhe = 'Política habilitada.' }
        }
        'Desabilitar' {
            if ($estavaDesligada) { $detalhe = 'A política já estava desabilitada; nenhuma alteração foi executada.' }
            else { Write-BizappLog "Desligando '$nome'..."; Set-AlertaLigado -Alerta $antes -Ligado $false; $alterou = $true; $detalhe = 'Política desabilitada.' }
        }
        'Remover' {
            Write-BizappLog "Removendo '$nome'..."
            Remove-AlertaAtividade -Alerta $antes
            $alterou = $true
            $detalhe = 'Política removida.'
        }
    }
    if (-not $alterou) { Write-BizappLog "$detalhe" -Nivel sucesso }

    Start-Sleep -Seconds 5
    $depois = Find-AlertaPorNome -Alertas (Get-AlertasTenant) -Nome $nome
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-depois.csv' -Dados (Get-AlertSnapshot -Alert $depois -Stage 'Depois' -Nome $nome)

    $aprovada = switch ($acao) {
        'Habilitar' { $null -ne $depois -and [string]$depois.Disabled -eq 'False' }
        'Desabilitar' { $null -ne $depois -and [string]$depois.Disabled -eq 'True' }
        'Remover' { $null -eq $depois }
    }
    if ($aprovada -and $alterou) { Write-BizappLog "$detalhe Conferido no tenant." -Nivel sucesso }
    Set-BizappSaida -Nome 'EstadoAlerta' -Valor (Get-TextoEstadoAlerta $depois)

    Write-ResumoAlertas -Pasta $pasta -Acao $acao -Ctx $ctx -Aprovada $aprovada -Alterou $alterou `
        -Resultado $(if ($aprovada) { 'Validado' } else { 'Falha' }) -Detalhe $detalhe -Extras ([ordered]@{ AlertName = $nome })
} finally {
    Disconnect-AlertasAtividade
}
