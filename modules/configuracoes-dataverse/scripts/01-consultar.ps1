#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-11 · Consultar (somente leitura): ambiente, conta e papel, idiomas instalados e
    disponiveis, fusos dos usuarios, equipes, unidades de negocio e caixas de correio.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ConfiguracoesDataverse.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl'

$ctx = Connect-ConfiguracoesDataverse -Entrada $entrada -PrimeiraEtapa
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
Write-BizappLog "Ambiente: $($ctx.Nome) (versão $($ctx.Versao)) · idioma base $(Get-NomeIdioma $ctx.IdiomaBase)" -Nivel sucesso
Write-AvisoAdmin -Ctx $ctx
Write-ContextoDataverse -Pasta $pasta -Ctx $ctx -Acao 'Consultar'

Write-BizappLog 'Lendo os idiomas...'
$idiomas = Get-IdiomasAmbiente
Export-BizappEvidencia -Pasta $pasta -Nome 'idiomas.csv' -Dados @(@($idiomas.Disponiveis + $idiomas.ParaInstalar + $idiomas.Instalados) | Sort-Object -Unique | ForEach-Object {
        [pscustomobject]@{ LCID = $_; Idioma = Get-NomeIdioma $_; Instalado = ($_ -in $idiomas.Instalados); PacoteNoServidor = ($_ -in $idiomas.Disponiveis); ListaAprovada = (Test-IdiomaAprovado $_) } })
Write-BizappLog "Idiomas instalados: $(Get-TextoIdiomas $idiomas.Instalados)"
Write-BizappLog "Da lista aprovada, ainda não instalados: $(Get-TextoIdiomas $idiomas.ParaInstalar)"

Write-BizappLog 'Lendo os fusos horários dos usuários...'
$fusos = Get-Fusos
$usuarios = Get-UsuariosFuso -Fusos $fusos
Export-BizappEvidencia -Pasta $pasta -Nome 'usuarios-fuso.csv' -Dados $usuarios
$textoFusos = Get-TextoFusos -Usuarios $usuarios
Write-BizappLog "Usuários ativos: $textoFusos"

Write-BizappLog 'Lendo as equipes e unidades de negócio...'
$equipes = Get-Equipes
$unidades = Get-UnidadesNegocio
Export-BizappEvidencia -Pasta $pasta -Nome 'equipes.csv' -Dados @($equipes | ForEach-Object {
        [pscustomobject]@{ Nome = $_.name; Tipo = Get-TextoTipoEquipe $_.teamtype; Padrao = $_.isdefault; CriadaPorEsteItem = (Test-EquipeDoItem $_); TeamId = $_.teamid; UnidadeId = $_._businessunitid_value }
    })
Export-BizappEvidencia -Pasta $pasta -Nome 'unidades-negocio.csv' -Dados @($unidades | ForEach-Object {
        [pscustomobject]@{ Nome = $_.name; Raiz = (-not $_._parentbusinessunitid_value); Desabilitada = $_.isdisabled; BusinessUnitId = $_.businessunitid }
    })
$raiz = $unidades | Where-Object { -not $_._parentbusinessunitid_value } | Select-Object -First 1
$doItem = @($equipes | Where-Object { Test-EquipeDoItem $_ })
$textoEquipes = "$($equipes.Count) ($(@($equipes | Where-Object teamtype -eq 0).Count) proprietárias)"
$textoUnidades = "$($unidades.Count)$(if ($raiz) { " · principal: $($raiz.name)" })"
Write-BizappLog "Equipes: $textoEquipes · criadas por este item: $(if ($doItem) { ($doItem.name) -join ', ' } else { 'nenhuma' })"
Write-BizappLog "Unidades de negócio: $textoUnidades"

Write-BizappLog 'Lendo as caixas de correio...'
$caixas = Get-Caixas
Export-BizappEvidencia -Pasta $pasta -Nome 'caixas-correio.csv' -Dados @($caixas | ForEach-Object {
        [pscustomobject]@{ Nome = $_.name; Email = $_.emailaddress; Entrada = $_.enabledforincomingemail; Saida = $_.enabledforoutgoingemail
            Aprovacao = $_.emailrouteraccessapproval; StatusEntrada = $_.incomingemailstatus; StatusSaida = $_.outgoingemailstatus; MailboxId = $_.mailboxid }
    })
$ligadas = @($caixas | Where-Object { $_.enabledforincomingemail -and $_.enabledforoutgoingemail }).Count
$textoCaixas = "$($caixas.Count) ($ligadas com entrada e saída ligadas)"
Write-BizappLog "Caixas de correio: $textoCaixas"

Set-BizappSaida -Nome 'Conta' -Valor $ctx.Identidade.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $ctx.Identidade.TenantId
Set-BizappSaida -Nome 'NomeAmbiente' -Valor $ctx.Nome
Set-BizappSaida -Nome 'EnvironmentId' -Valor $ctx.EnvironmentId
Set-BizappSaida -Nome 'PapelAdmin' -Valor $(if ($ctx.AdminSistema) { 'Administrador do sistema' } else { 'Sem o papel Administrador do sistema' })
Set-BizappSaida -Nome 'IdiomaBase' -Valor (Get-NomeIdioma $ctx.IdiomaBase)
Set-BizappSaida -Nome 'IdiomasInstalados' -Valor (Get-TextoIdiomas $idiomas.Instalados)
Set-BizappSaida -Nome 'IdiomasDisponiveis' -Valor (Get-TextoIdiomas $idiomas.ParaInstalar)
Set-BizappSaida -Nome 'FusosUsuarios' -Valor $textoFusos
Set-BizappSaida -Nome 'Equipes' -Valor $textoEquipes
Set-BizappSaida -Nome 'UnidadesNegocio' -Valor $textoUnidades
Set-BizappSaida -Nome 'EquipesDoItem' -Valor $(if ($doItem) { ($doItem.name) -join ', ' } else { 'Nenhuma' })
Set-BizappSaida -Nome 'CaixasCorreio' -Valor $textoCaixas

Write-ResumoDataverse -Pasta $pasta -Acao 'Consultar' -Ctx $ctx -Aprovada $true -Alterou $false -Detalhe 'Consulta concluída.' `
    -Extras ([ordered]@{ IdiomasInstalados = ($idiomas.Instalados -join ';'); Usuarios = $usuarios.Count; Equipes = $equipes.Count; Caixas = $caixas.Count })
