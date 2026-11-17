#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-11 · Ajustar o fuso horario de um usuario ou de todos os usuarios ativos (usersettings).
    Guarda o fuso anterior de cada usuario em usuarios-fuso-antes.csv e confere relendo.
    Todos os usuarios exige digitar CONFIRMO.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ConfiguracoesDataverse.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl', 'TenantId', 'Conta', 'Fuso', 'AlcanceFuso'

$chave = [string]$entrada.Fuso
$padraoFuso = Get-NomePadraoFuso $chave
if (-not $padraoFuso) { throw "Fuso inválido: $chave" }
$alcance = [string]$entrada.AlcanceFuso
$email = ([string]$entrada.EmailUsuario).Trim()
if ($alcance -eq 'usuario' -and -not $email) { throw 'Informe o e-mail do usuário. Nada foi alterado.' }
if ($alcance -eq 'todos' -and ([string]$entrada.ConfirmacaoFuso).Trim() -cne 'CONFIRMO') {
    throw 'Para mudar o fuso de todos os usuários, digite CONFIRMO no campo de confirmação. Nada foi alterado.'
}
if ($alcance -notin 'usuario', 'todos') { throw "Alcance inválido: $alcance" }

$ctx = Connect-ConfiguracoesDataverse -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Fuso'
Write-ContextoDataverse -Pasta $pasta -Ctx $ctx -Acao 'Fuso' -Extras ([ordered]@{ Fuso = $padraoFuso; Alcance = $alcance; Usuario = $email })
Write-AvisoAdmin -Ctx $ctx

$fusos = Get-Fusos
$novo = $fusos | Where-Object standardname -eq $padraoFuso | Select-Object -First 1
if (-not $novo) { throw "O fuso $($padraoFuso) não existe neste ambiente. Nada foi alterado." }
$usuarios = Get-UsuariosFuso -Fusos $fusos
Export-BizappEvidencia -Pasta $pasta -Nome 'usuarios-fuso-antes.csv' -Dados $usuarios

$alvos = if ($alcance -eq 'usuario') {
    @($usuarios | Where-Object { [string]::Equals($_.Email, $email, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
} else { $usuarios }
if (-not $alvos.Count) { throw "Usuário ativo $email não encontrado no ambiente. Nada foi alterado." }

$mudar = @($alvos | Where-Object { [int]$_.TimeZoneCode -ne [int]$novo.timezonecode })
Write-BizappLog "Fuso escolhido: $($novo.userinterfacename). $($alvos.Count) usuário(s) no alcance, $($mudar.Count) com outro fuso."

$resultado = [System.Collections.Generic.List[object]]::new()
$i = 0
foreach ($u in $mudar) {
    $i++
    Write-BizappProgresso -Percentual ([math]::Round(100 * $i / $mudar.Count)) -Fase "Ajustando $i de $($mudar.Count)"
    try {
        $lido = Set-FusoUsuario -UserId $u.UserId -Codigo ([int]$novo.timezonecode)
        $ok = $lido -eq [int]$novo.timezonecode
        $resultado.Add([pscustomobject]@{ Nome = $u.Nome; Email = $u.Email; Antes = $u.TimeZoneCode; Depois = $lido; Sucesso = $ok; Erro = '' })
        if ($alcance -eq 'usuario') { Write-BizappLog "$($u.Nome): $($u.Fuso) → $($novo.userinterfacename)" -Nivel $(if ($ok) { 'sucesso' } else { 'aviso' }) }
    } catch {
        $resultado.Add([pscustomobject]@{ Nome = $u.Nome; Email = $u.Email; Antes = $u.TimeZoneCode; Depois = ''; Sucesso = $false; Erro = $_.Exception.Message })
        Write-BizappLog "$($u.Nome): $($_.Exception.Message)" -Nivel aviso
    }
}
Export-BizappEvidencia -Pasta $pasta -Nome 'usuarios-fuso-alterados.csv' -Dados @($resultado)

$falhas = @($resultado | Where-Object { -not $_.Sucesso }).Count
$alterados = $resultado.Count - $falhas
$detalhe = if (-not $mudar.Count) { "Os usuários já estavam em $($novo.userinterfacename); nada foi alterado." }
else { "$alterados usuário(s) passaram para $($novo.userinterfacename)$(if ($falhas) { "; $falhas falharam (veja usuarios-fuso-alterados.csv)" })." }
Write-BizappLog $detalhe -Nivel $(if ($falhas) { 'aviso' } else { 'sucesso' })
Write-BizappLog 'O fuso anterior de cada usuário está em usuarios-fuso-antes.csv, na pasta de evidências.' -Nivel discreto

$estado = if ($alcance -eq 'usuario') { "$($alvos[0].Nome) · $($novo.userinterfacename)" } else { "Todos ($($alvos.Count)) · $($novo.userinterfacename)$(if ($falhas) { " · $falhas falharam" })" }
Set-BizappSaida -Nome 'EstadoFuso' -Valor $estado

Write-ResumoDataverse -Pasta $pasta -Acao 'Fuso' -Ctx $ctx -Aprovada ($falhas -eq 0) -Alterou ($alterados -gt 0) -Detalhe $detalhe `
    -Extras ([ordered]@{ Fuso = $novo.standardname; Alcance = $alcance; NoAlcance = $alvos.Count; Alterados = $alterados; Falhas = $falhas })
