#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-05 · Alocar Copilot Credits ao ambiente (secoes 7 a 9 do original): quantidade, TenantPool,
    confirmacao ALOCAR, PUT allocationsV2 e reconsulta. Mesmas regras do original: quantidade nao
    pode ser negativa nem maior que o disponivel.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CopilotCredits.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'IdAmbiente', 'TenantPool'

# A confirmacao vale para uma execucao so
$Confirm = ([string]$entrada.ConfirmacaoAlocar).Trim().ToUpper()
Set-BizappSaida -Nome 'ConfirmacaoAlocar' -Valor ''
if ($Confirm -ne 'ALOCAR') { throw 'Operação cancelada: digite ALOCAR no campo de confirmação para executar.' }

# So numeros inteiros, sem separador: "5.000" seria lido como 5 em algumas culturas
$textoQtd = ([string]$entrada.Quantidade).Trim()
if ($textoQtd -notmatch '^\d{1,9}$') { throw "Quantidade inválida: '$textoQtd'. Use só números, sem ponto (ex.: 5000). Nada foi alterado." }
[decimal]$CreditQuantity = [decimal]::Parse($textoQtd, [Globalization.CultureInfo]::InvariantCulture)
if ($CreditQuantity -lt 0) { throw 'Quantidade inválida. Nada foi alterado.' }
$TenantPool = [string]$entrada.TenantPool -eq 'sim'

$id = Connect-CopilotCredits -Entrada $entrada -ComApi
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Alocar'
$EnvironmentId = [string]$entrada.IdAmbiente
$EnvironmentName = [string]$entrada.NomeAmbiente

$antes = Get-Disponibilidade -EnvironmentId $EnvironmentId
if ($null -eq $antes.Disponivel) { throw 'A API não retornou MCSMessages (Copilot Credits) para este ambiente. Nada foi alterado.' }
$AvailableQuantity = $antes.Disponivel
if ($CreditQuantity -gt $AvailableQuantity) { throw "Solicitado $CreditQuantity, mas a disponibilidade retornada é $AvailableQuantity. Nada foi alterado." }
$alocAntes = Get-AlocacaoAmbiente -EnvironmentId $EnvironmentId
if ($alocAntes -and $alocAntes.Resposta) { ($alocAntes.Resposta | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $pasta 'alocacao-antes.json') -Encoding utf8 }

Write-BizappLog '=== RESUMO ==='
Write-BizappLog "Tenant        : $($id.TenantId)"
Write-BizappLog "Ambiente      : $EnvironmentName"
Write-BizappLog "Environment ID: $EnvironmentId"
Write-BizappLog "Disponível    : $(Format-Creditos $AvailableQuantity)"
if ($alocAntes) { Write-BizappLog "Alocado hoje  : $(Format-Creditos $alocAntes.Alocado)" }
Write-BizappLog "Nova alocação : $(Format-Creditos $CreditQuantity) (substitui o valor atual do ambiente)"
Write-BizappLog "Usar a capacidade do tenant depois de esgotar: $(if ($TenantPool) { 'sim' } else { 'não' })"

Write-BizappLog 'Enviando a alocação...'
$AllocationResult = Set-Alocacao -EnvironmentId $EnvironmentId -CreditQuantity $CreditQuantity -TenantPool $TenantPool
Write-BizappLog 'Alocação enviada com sucesso.' -Nivel sucesso
($AllocationResult | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $pasta 'retorno-alocacao.json') -Encoding utf8

# Valida novamente a API (secao 9)
$depois = Get-Disponibilidade -EnvironmentId $EnvironmentId
($depois.Resposta | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $pasta 'disponibilidade-depois.json') -Encoding utf8
Write-BizappLog "Copilot Credits disponíveis para alocar depois: $(Format-Creditos $depois.Disponivel)"

# Conferencia pela alocacao do ambiente (pode levar alguns segundos para refletir)
$alocDepois = $null
foreach ($tentativa in 1..4) {
    $alocDepois = Get-AlocacaoAmbiente -EnvironmentId $EnvironmentId
    if (-not $alocDepois -or $alocDepois.Alocado -eq $CreditQuantity) { break }
    Start-Sleep -Seconds 10
}
$conferido = $null -ne $alocDepois -and $alocDepois.Alocado -eq $CreditQuantity
if ($alocDepois -and $alocDepois.Resposta) { ($alocDepois.Resposta | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $pasta 'alocacao-depois.json') -Encoding utf8 }
if ($conferido) {
    Write-BizappLog "Conferido: $(Format-Creditos $alocDepois.Alocado) alocados em $EnvironmentName. Quando esgotar: $(Format-TenantPool $alocDepois.TenantPool)." -Nivel sucesso
} elseif ($alocDepois) {
    Write-BizappLog "A alocação do ambiente ainda mostra $(Format-Creditos $alocDepois.Alocado). Pode levar até 15 minutos para refletir: confira no admin center (Licenciamento > Copilot Studio > Gerenciar Copilot Credits)." -Nivel aviso
} else {
    Write-BizappLog 'Não foi possível conferir a alocação do ambiente. Confira no admin center (Licenciamento > Copilot Studio > Gerenciar Copilot Credits).' -Nivel aviso
}
Write-BizappLog 'O número "disponível para alocar" pode não mudar logo depois da alocação. A conferência vale pelo valor alocado no ambiente.' -Nivel discreto

$estado = "$(Format-Creditos $CreditQuantity) alocados em $EnvironmentName · capacidade do tenant depois de esgotar: $(if ($TenantPool) { 'sim' } else { 'não' })$(if (-not $conferido) { ' · conferir no admin center' })"
Set-BizappSaida -Nome 'EstadoAlocacao' -Valor $estado
Set-BizappSaida -Nome 'CreditosDisponiveis' -Valor (Format-Creditos $depois.Disponivel)
if ($alocDepois) { Set-BizappSaida -Nome 'AlocadoAtual' -Valor (Format-Creditos $alocDepois.Alocado) }
Write-ResumoCredits -Pasta $pasta -Acao 'Alocar' -Identidade $id -Aprovada $true -Alterou $true -Detalhe $(if ($conferido) { 'Alocação conferida no ambiente.' } else { 'Alocação enviada; conferir no admin center.' }) `
    -Extras ([ordered]@{ Ambiente = $EnvironmentName; EnvironmentId = $EnvironmentId; DisponivelAntes = $AvailableQuantity; AlocadoAntes = $(if ($alocAntes) { $alocAntes.Alocado }); Alocado = $CreditQuantity; TenantPool = $TenantPool; DisponivelDepois = $depois.Disponivel; AlocadoDepois = $(if ($alocDepois) { $alocDepois.Alocado }); Conferido = $conferido })
