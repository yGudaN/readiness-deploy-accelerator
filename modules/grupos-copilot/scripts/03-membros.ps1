#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-22 · AdicionarMembro / RemoverMembro: inclui ou retira um usuario dos grupos escolhidos,
    confirmando por nova consulta. Idempotente: quem ja e membro (ou ja nao e) e "ignorado".
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GruposCopilot.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'GrupoAlvo', 'UsuarioUPN', 'OperacaoMembro'
$inicio = Get-Date
$adicionar = $entrada.OperacaoMembro -eq 'adicionar'
$acao = if ($adicionar) { 'AdicionarMembro' } else { 'RemoverMembro' }

$ctx = Connect-GruposCopilot -Entrada $entrada -EscoposExtras @('GroupMember.ReadWrite.All')
$id = $ctx.Identidade
$pasta = New-BizappEvidencias -Item $ITEM -Acao $acao
$defs = Get-DefinicoesGrupos -GrupoAlvo $entrada.GrupoAlvo
Export-BizappEvidencia -Pasta $pasta -Nome 'membros-antes.csv' -Dados @(Get-MemberSnapshot -GroupDefinitions $defs)

$usuario = Get-MgUser -UserId $entrada.UsuarioUPN -Property @('Id', 'UserPrincipalName', 'AccountEnabled') -ErrorAction Stop
if ($adicionar -and $usuario.AccountEnabled -ne $true) { throw "O usuário $($entrada.UsuarioUPN) não está habilitado." }

$acoes = [System.Collections.Generic.List[object]]::new()
$alterou = $false
foreach ($d in $defs) {
    $grupo = @(Get-ExactGroups -DisplayName $d.DisplayName)
    if ($grupo.Count -ne 1) { throw "O grupo $($d.DisplayName) precisa existir uma única vez (encontrados: $($grupo.Count)). Rode a etapa de criação antes." }
    if (@($grupo[0].GroupTypes) -contains 'DynamicMembership') { throw "O grupo $($d.DisplayName) é dinâmico: membros não podem ser alterados manualmente." }

    $ids = @(Get-MgGroupMember -GroupId $grupo[0].Id -All -ErrorAction Stop | ForEach-Object { [string]$_.Id })
    $jaMembro = $usuario.Id -in $ids
    if ($jaMembro -eq $adicionar) {
        $msg = if ($adicionar) { 'Usuário já era membro; inclusão ignorada' } else { 'Usuário não era membro; remoção ignorada' }
        Write-BizappLog "$($d.DisplayName): $msg." -Nivel discreto
        $acoes.Add([pscustomobject]@{ DataHora = (Get-Date).ToString('o'); Acao = $acao; Grupo = $d.DisplayName; ObjetoId = $usuario.Id; Resultado = $msg })
        continue
    }

    if ($adicionar) { New-MgGroupMember -GroupId $grupo[0].Id -DirectoryObjectId $usuario.Id -ErrorAction Stop }
    else { Remove-MgGroupMemberByRef -GroupId $grupo[0].Id -DirectoryObjectId $usuario.Id -Confirm:$false -ErrorAction Stop }
    $alterou = $true
    if (-not (Test-MembershipState -GroupId $grupo[0].Id -DirectoryObjectId $usuario.Id -ShouldExist $adicionar)) {
        throw "A $(if ($adicionar) { 'inclusão' } else { 'remoção' }) em $($d.DisplayName) não foi confirmada."
    }
    $msg = if ($adicionar) { 'Usuário adicionado e associação confirmada' } else { 'Usuário removido e ausência confirmada' }
    Write-BizappLog "$($d.DisplayName): $msg." -Nivel sucesso
    $acoes.Add([pscustomobject]@{ DataHora = (Get-Date).ToString('o'); Acao = $acao; Grupo = $d.DisplayName; ObjetoId = $usuario.Id; Resultado = $msg })
}
Export-BizappEvidencia -Pasta $pasta -Nome 'acoes.csv' -Dados $acoes

# Quality gate: reconsulta a participacao em cada grupo
$depois = @(Get-MemberSnapshot -GroupDefinitions $defs)
Export-BizappEvidencia -Pasta $pasta -Nome 'membros-depois.csv' -Dados $depois
$notas = foreach ($d in $defs) {
    $existe = [bool]($depois | Where-Object { $_.GrupoDisplayName -eq $d.DisplayName -and $_.MemberId -eq $usuario.Id })
    if ($existe -ne $adicionar) { "O estado do membro em $($d.DisplayName) não corresponde ao esperado." }
}
Write-ResumoExecucao -Pasta $pasta -Acao $acao -Identidade $id -Alterou $alterou -Aprovada (-not $notas) -Notas @($notas) -Inicio $inicio -Extra $entrada.UsuarioUPN
