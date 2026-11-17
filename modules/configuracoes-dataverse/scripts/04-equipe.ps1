#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-11 · Criar uma equipe proprietaria (teamtype 0) numa unidade de negocio, ou remover uma
    equipe criada por este item (marca na descricao). Remover exige digitar CONFIRMO.
    Nao duplica: se ja existe equipe com o mesmo nome, nada e criado.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ConfiguracoesDataverse.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl', 'TenantId', 'Conta', 'AcaoEquipe'

$nome = ([string]$entrada.NomeEquipe).Trim()
if (-not $nome) { throw 'Informe o nome da equipe. Nada foi alterado.' }
$acao = [string]$entrada.AcaoEquipe
if ($acao -notin 'criar', 'remover') { throw "Ação inválida: $acao" }
if ($acao -eq 'remover' -and ([string]$entrada.ConfirmacaoEquipe).Trim() -cne 'CONFIRMO') {
    throw 'Para remover a equipe, digite CONFIRMO no campo de confirmação. Nada foi alterado.'
}

$ctx = Connect-ConfiguracoesDataverse -Entrada $entrada
$rotuloAcao = if ($acao -eq 'criar') { 'Criar-Equipe' } else { 'Remover-Equipe' }
$pasta = New-BizappEvidencias -Item $ITEM -Acao $rotuloAcao
Write-ContextoDataverse -Pasta $pasta -Ctx $ctx -Acao $rotuloAcao -Extras ([ordered]@{ Equipe = $nome; Unidade = $entrada.UnidadeNegocio })
Write-AvisoAdmin -Ctx $ctx

# Get-Equipes devolve a lista como um objeto so: guardar numa variavel antes de filtrar
function Find-Equipe { $todas = Get-Equipes; @($todas | Where-Object { [string]::Equals($_.name, $nome, [StringComparison]::OrdinalIgnoreCase) }) }
function Get-Snapshot([object[]]$Lista, [string]$Etapa) {
    if (-not $Lista.Count) { return [pscustomobject]@{ Etapa = $Etapa; Nome = $nome; Existe = $false } }
    $Lista | ForEach-Object { [pscustomobject]@{ Etapa = $Etapa; Nome = $_.name; Existe = $true; Tipo = Get-TextoTipoEquipe $_.teamtype; CriadaPorEsteItem = (Test-EquipeDoItem $_); TeamId = $_.teamid; UnidadeId = $_._businessunitid_value } }
}

$antes = Find-Equipe
Export-BizappEvidencia -Pasta $pasta -Nome 'equipe-antes.csv' -Dados @(Get-Snapshot $antes 'Antes')
$alterou = $false

if ($acao -eq 'criar') {
    $unidades = Get-UnidadesNegocio
    $textoUnidade = ([string]$entrada.UnidadeNegocio).Trim()
    $unidade = if ($textoUnidade) { $unidades | Where-Object { [string]::Equals($_.name, $textoUnidade, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1 }
    else { $unidades | Where-Object { -not $_._parentbusinessunitid_value } | Select-Object -First 1 }
    if (-not $unidade) { throw "Unidade de negócio '$textoUnidade' não encontrada (existentes: $(($unidades.name) -join ', ')). Nada foi alterado." }

    if ($antes.Count) {
        $detalhe = "Já existe uma equipe chamada '$($antes[0].name)' ($(Get-TextoTipoEquipe $antes[0].teamtype)); nada foi criado."
        Write-BizappLog $detalhe -Nivel sucesso
        $depois = $antes
        $aprovada = $true
    } else {
        Write-BizappLog "Criando a equipe proprietária '$nome' na unidade '$($unidade.name)'..."
        $null = Invoke-Dataverse -Metodo POST -Caminho 'teams' -Corpo @{
            name = $nome; teamtype = 0; description = $MARCA
            'businessunitid@odata.bind' = "/businessunits($($unidade.businessunitid))"
        }
        $alterou = $true
        $depois = Find-Equipe
        $aprovada = $depois.Count -eq 1 -and [int]$depois[0].teamtype -eq 0
        $detalhe = "Equipe '$nome' criada na unidade '$($unidade.name)'. Adicione membros e papéis de segurança no Power Platform admin center."
        if ($aprovada) { Write-BizappLog "$detalhe Conferido no ambiente." -Nivel sucesso }
    }
    $estado = if ($depois.Count) { "$($depois[0].name) · $(Get-TextoTipoEquipe $depois[0].teamtype)" } else { 'Não existe' }
} else {
    if (-not $antes.Count) { throw "A equipe '$nome' não existe. Nada foi alterado." }
    $equipe = $antes[0]
    if (-not (Test-EquipeDoItem $equipe)) { throw "A equipe '$nome' não foi criada por este item. Ela não será removida." }
    Write-BizappLog "Removendo a equipe '$nome'..."
    $null = Invoke-Dataverse -Metodo DELETE -Caminho "teams($($equipe.teamid))"
    $alterou = $true
    $depois = Find-Equipe
    $aprovada = $depois.Count -eq 0
    $detalhe = "Equipe '$nome' removida."
    if ($aprovada) { Write-BizappLog "$detalhe Conferido no ambiente." -Nivel sucesso }
    $estado = "$nome · removida"
}
Export-BizappEvidencia -Pasta $pasta -Nome 'equipe-depois.csv' -Dados @(Get-Snapshot $depois 'Depois')
Set-BizappSaida -Nome 'EstadoEquipe' -Valor $estado

Write-ResumoDataverse -Pasta $pasta -Acao $rotuloAcao -Ctx $ctx -Aprovada $aprovada -Alterou $alterou -Detalhe $detalhe -Extras ([ordered]@{ Equipe = $nome })
