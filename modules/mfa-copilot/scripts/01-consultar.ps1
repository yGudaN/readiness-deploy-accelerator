#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-33 · Consultar (somente leitura): conta, licenca Entra ID P1/P2, padroes de seguranca,
    grupos Copilot-Premium/Copilot-Geral e estado da politica "MFA Copilot". Nao altera nada.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MfaCopilot.psm1') -Force
$entrada = Read-BizappEntrada
$inicio = Get-Date

$id = Connect-MfaCopilot -Entrada $entrada
Write-BizappLog "Conta: $($id.Conta)" -Nivel sucesso
Write-BizappLog "Tenant: $($id.TenantId)"
# Confirmados aqui; as proximas etapas abortam se o login for de outro tenant ou conta
Set-BizappSaida -Nome 'Conta' -Valor $id.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $id.TenantId

$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'

$pre = Get-PreCondicoesTenant
Export-BizappEvidencia -Pasta $pasta -Nome 'pre-condicoes.csv' -Dados $pre
if ($pre.TemLicenca) {
    Write-BizappLog "Licença Microsoft Entra ID: $($pre.Licencas)" -Nivel sucesso
    Set-BizappSaida -Nome 'LicencaEntra' -Valor 'Encontrada'
} else {
    Write-BizappLog 'Licença Microsoft Entra ID P1 ou P2: não encontrada. Sem ela a política de Acesso Condicional não pode ser criada.' -Nivel aviso
    Set-BizappSaida -Nome 'LicencaEntra' -Valor 'Não encontrada'
}
if ($pre.PadroesSeguranca) {
    Write-BizappLog 'Padrões de segurança do Entra ID: LIGADOS. Com eles ligados o Entra ID não aceita políticas de Acesso Condicional; desligue-os antes de criar a política (Entra admin center > Visão geral > Propriedades > Gerenciar padrões de segurança).' -Nivel aviso
    Set-BizappSaida -Nome 'PadroesSeguranca' -Valor 'Ligados'
} else {
    Write-BizappLog 'Padrões de segurança do Entra ID: desligados.'
    Set-BizappSaida -Nome 'PadroesSeguranca' -Valor 'Desligados'
}

$ctx = Get-ContextoMfa -Identidade $id -ContasEmergencia '' -Pasta $pasta -Acao 'Consultar'
foreach ($g in $ctx.Grupos) { Write-BizappLog "$($g.NomeConsultado): $($g.StatusConsulta)" -Nivel $(if ($g.CorrespondenciaUnica) { 'info' } else { 'aviso' }) }
$idsGrupos = @(Get-IdsGruposEsperados -Grupos $ctx.Grupos)

$avaliacao = Test-PoliticaMfa -Politica $ctx.Politica -IdsGrupos $idsGrupos -IdsExcluidosObrigatorios $ctx.IdsExcluidos
Write-EstadoPolitica -Politica $ctx.Politica -Avaliacao $avaliacao

# Contas que a politica ja exclui (alem da conta do login): sugeridas como contas de emergencia
if ($ctx.Politica) {
    $excluidas = @($ctx.Politica.Conditions.Users.ExcludeUsers | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_ -ne [string]$ctx.Admin.Id })
    $upns = foreach ($u in $excluidas) {
        try { (Get-MgUser -UserId $u -Property 'userPrincipalName' -ErrorAction Stop).UserPrincipalName } catch { }
    }
    if ($upns) {
        Write-BizappLog "Contas já excluídas da política: $($upns -join ', ')" -Nivel discreto
        Set-BizappSaida -Nome 'ContasEmergencia' -Valor ($upns -join '; ')
    }
}

Write-ResumoMfa -Pasta $pasta -Acao 'Consultar' -Identidade $id -Acoes @(New-RegistroAcao -Acao 'Consultar' -Status 'Sucesso' -Detalhe 'Consulta concluída.') `
    -PoliticasDepois @($(if ($ctx.Politica) { $ctx.Politica })) -AvaliacaoAntes $avaliacao -AvaliacaoDepois $avaliacao -Alterou $false -Aprovada $true -Inicio $inicio
