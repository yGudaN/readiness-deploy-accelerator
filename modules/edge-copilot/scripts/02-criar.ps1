#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-26 · Previsualizar e criar (CriarPiloto) a politica do Edge SEM atribuicao. Idempotente:
    se a politica deste item ja existe com o mesmo nome, nada e criado. Exige digitar CRIAR.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'EdgeCopilot.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'CopilotUrl', 'NomePolitica'

$confirmou = ([string]$entrada.ConfirmacaoCriar).Trim() -ceq 'CRIAR'
Set-BizappSaida -Nome 'ConfirmacaoCriar' -Valor ''
if (-not $confirmou) { throw 'Revise os valores e digite CRIAR no campo de confirmação. Nada foi alterado.' }
$url = ([string]$entrada.CopilotUrl).Trim()
$nome = ([string]$entrada.NomePolitica).Trim()
if ($url -notmatch '^https://\S+$') { throw "URL inválida: $url" }

$id = Connect-EdgeCopilot -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Criar'
$ctx = Get-Contexto
if (-not $ctx.TemIntune) { throw 'O tenant não tem licença do Microsoft Intune ativa. Nada foi alterado.' }
if (-not $ctx.Papeis) { throw 'A conta precisa ser Administrador Global ou Administrador do Intune. Nada foi alterado.' }

Write-BizappLog 'Lendo os ajustes do Edge no catálogo do Intune...'
$defs = Get-Definicoes
Export-BizappEvidencia -Pasta $pasta -Nome 'definicoes-configuracao.csv' -Dados $defs
$corpo = New-CorpoPolitica -Nome $nome -Url $url -Definicoes $defs
($corpo | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath (Join-Path $pasta 'corpo-proposto.json') -Encoding utf8
Write-BizappLog "Proposta: '$nome', Windows, página inicial e nova guia = $url, sem atribuição."

$existente = Find-Politica -Nome $nome
$alterou = $false
if ($existente) {
    if (-not (Test-PoliticaDoItem $existente)) { throw "Já existe uma política chamada '$nome' que não foi criada por este item. Ela não será alterada; escolha outro nome." }
    Write-BizappLog "A política '$nome' já existe: nova criação ignorada." -Nivel sucesso
    $politica = $existente
    Save-Referencia $politica
} else {
    Write-BizappLog "Criando '$nome'..."
    $politica = Invoke-Graph -Metodo POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' -Corpo $corpo
    Save-Referencia $politica
    $alterou = $true
    Write-BizappLog "Política criada: $($politica.id)" -Nivel sucesso
}

# Leitura posterior: os dois valores e nenhuma atribuicao nova
$valores = Get-Valores $politica.id
Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-depois.csv' -Dados $valores
$atrib = Get-Atribuicoes $politica.id
$falhas = @()
foreach ($d in $defs) {
    $v = $valores | Where-Object Definicao -eq $d.Principal | Select-Object -First 1
    if (-not $v -or $v.Opcao -ne $d.OpcaoHabilitado -or $v.Valor -ne $url) { $falhas += "$($d.Ajuste) = $($v.Valor)" }
    else { Write-BizappLog "$($d.Ajuste): habilitado, $url" -Nivel sucesso }
}
if ($alterou -and $atrib.Count) { $falhas += "a política nova tem $($atrib.Count) atribuição(ões)" }
Set-BizappSaida -Nome 'EstadoPolitica' -Valor (Get-TextoPolitica $politica $atrib.Count)
Set-BizappSaida -Nome 'IdPolitica' -Valor $politica.id

$aprovada = -not $falhas
Write-ResumoEdge -Pasta $pasta -Acao 'Criar' -Identidade $id -Aprovada $aprovada -Alterou $alterou `
    -Detalhe $(if ($aprovada) { 'Política conferida: página inicial e nova guia no Copilot, sem impacto nos dispositivos enquanto não for atribuída.' } else { "A conferência encontrou: $($falhas -join '; ')" }) `
    -Extras ([ordered]@{ Politica = $nome; PolicyId = $politica.id; Url = $url; Atribuicoes = $atrib.Count })
