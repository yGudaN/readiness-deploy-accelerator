#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-33 · CriarReportOnly: cria a politica "MFA Copilot" SOMENTE em modo de relatorio
    (enabledForReportingButNotEnforced). Grava o corpo proposto (Previsualizar) nas evidencias.
    Idempotente: politica existente e valida e mantida; ID conhecido nao resolvido bloqueia
    nova criacao (evita duplicidade); politica que diverge do desenho bloqueia.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MfaCopilot.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta'
$inicio = Get-Date

$id = Connect-MfaCopilot -Entrada $entrada -Alteracao
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'CriarReportOnly'

$pre = Get-PreCondicoesTenant
if (-not $pre.TemLicenca) {
    throw 'Bloqueado: o tenant não tem licença Microsoft Entra ID P1 ou P2, necessária para o Acesso Condicional. Nada foi alterado.'
}
if ($pre.PadroesSeguranca) {
    Write-BizappLog 'Os padrões de segurança do Entra ID estão ligados: o Entra ID pode recusar a política.' -Nivel aviso
}

$ctx = Get-ContextoMfa -Identidade $id -ContasEmergencia $entrada.ContasEmergencia -Pasta $pasta -Acao 'CriarReportOnly'
$idsGrupos = @(Get-IdsGruposEsperados -Grupos $ctx.Grupos)
$antes = Test-PoliticaMfa -Politica $ctx.Politica -IdsGrupos $idsGrupos -IdsExcluidosObrigatorios $ctx.IdsExcluidos

$corpo = Get-CorpoPolitica -IdsGrupos $idsGrupos -IdsExcluidos $ctx.IdsExcluidos
$corpo | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $pasta 'corpo-proposto.json') -Encoding utf8
Write-BizappLog "Fora da política: $(@($id.Conta) + $ctx.Emergencia -join ', ')" -Nivel discreto

$acoes = [System.Collections.Generic.List[object]]::new()
$alterou = $false
$idPolitica = $ctx.IdReferencia
if ($null -eq $ctx.Politica) {
    if (-not [string]::IsNullOrWhiteSpace($ctx.IdReferencia)) {
        throw "Existe um ID conhecido para a política ($($ctx.IdReferencia)), mas ele ainda não foi encontrado no tenant. Nova criação bloqueada para evitar duplicidade: aguarde alguns minutos e rode a etapa de novo."
    }
    Write-BizappLog 'Criando a política em modo de relatório...'
    $criada = New-MgIdentityConditionalAccessPolicy -BodyParameter $corpo -ErrorAction Stop
    $idPolitica = [string]$criada.Id
    Save-ReferenciaPolitica -TenantId $id.TenantId -PolicyId $idPolitica
    $alterou = $true
    $acoes.Add((New-RegistroAcao -Acao 'CriarReportOnly' -Status 'Sucesso' -Detalhe "Política criada em report-only. Id=$idPolitica"))
    Write-BizappLog 'Política criada em modo de relatório.' -Nivel sucesso
} elseif ($antes.CoreConfigurationValid -and $antes.State -eq $ESTADO_RELATORIO) {
    $idPolitica = [string]$ctx.Politica.Id
    $acoes.Add((New-RegistroAcao -Acao 'CriarReportOnly' -Status 'Ignorado' -Detalhe 'Política já existente e válida. Idempotência confirmada.'))
    Write-BizappLog 'A política já existia em modo de relatório e com o desenho esperado: nada foi alterado.' -Nivel sucesso
} elseif ($antes.CoreConfigurationValid) {
    throw "A política já existe e está em outro estado ($(Get-TextoEstado $antes.State)). Use a próxima etapa para mudar o estado. Nada foi alterado."
} else {
    throw "A política ""$NOME_POLITICA"" já existe, mas diverge do desenho esperado: $($antes.Divergencias -join '; '). Revise no Entra ID. Nada foi alterado."
}

Write-BizappLog 'Validando o estado posterior (até 90 segundos)...' -Nivel discreto
$depois = @(Wait-PoliticaMfa -DeveExistir $true -IdPreferido $idPolitica -EstadoEsperado $ESTADO_RELATORIO)
if ($depois.Count -gt 1) { throw 'A validação posterior encontrou políticas duplicadas.' }
$avaliacao = Test-PoliticaMfa -Politica $(if ($depois.Count -eq 1) { $depois[0] }) -IdsGrupos $idsGrupos -IdsExcluidosObrigatorios $ctx.IdsExcluidos
Write-EstadoPolitica -Politica $(if ($depois.Count -eq 1) { $depois[0] }) -Avaliacao $avaliacao
$aprovada = $depois.Count -eq 1 -and $avaliacao.CoreConfigurationValid -and $avaliacao.State -eq $ESTADO_RELATORIO
Write-ResumoMfa -Pasta $pasta -Acao 'CriarReportOnly' -Identidade $id -Acoes $acoes -PoliticasDepois $depois -AvaliacaoAntes $antes -AvaliacaoDepois $avaliacao `
    -Alterou $alterou -Aprovada $aprovada -Nota $(if (-not $aprovada) { 'O estado posterior não corresponde ao esperado.' }) -Inicio $inicio
