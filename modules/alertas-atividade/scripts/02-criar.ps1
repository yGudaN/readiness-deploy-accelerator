#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-30 · CriarAnomala / CriarSimples: cria a politica de alerta de atividade, ligada, e confere
    pela consulta posterior. Se ja existir com o mesmo nome, nao cria de novo.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AlertasAtividade.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'TipoAlerta', 'NomeAlerta', 'Operacao', 'NotificarConta'

$tipo = [string]$entrada.TipoAlerta
if ($tipo -notin 'anomala', 'simples') { throw "Tipo inválido: $tipo" }
$nome = ([string]$entrada.NomeAlerta).Trim()
if ($nome -notmatch '^[A-Za-z0-9._ -]{3,64}$') { throw 'Nome inválido: use letras sem acento, números, espaço, ponto, hífen ou sublinhado (3 a 64).' }
$operacao = ([string]$entrada.Operacao).Trim()
if ($operacao -notmatch '^[A-Za-z0-9-]{2,80}$') { throw "Atividade inválida: $operacao" }
$notificar = ([string]$entrada.NotificarConta).Trim()
if ($notificar -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw "E-mail para notificação inválido: $notificar" }
$limite = 0; $janela = 0
if ($tipo -eq 'simples') {
    if (-not [int]::TryParse([string]$entrada.Limite, [ref]$limite) -or $limite -lt 3) { throw 'Quantidade inválida: use 3 ou mais.' }
    if (-not [int]::TryParse([string]$entrada.Janela, [ref]$janela) -or $janela -lt 61) { throw 'Janela inválida: use 61 minutos ou mais.' }
}
$acao = if ($tipo -eq 'anomala') { 'CriarAnomala' } else { 'CriarSimples' }
$justificativa = 'Executado pelo Readiness Deploy Accelerator'

try {
    $ctx = Connect-AlertasAtividade -Entrada $entrada
    $pasta = New-BizappEvidencias -Item $ITEM -Acao $acao
    Write-ContextoAlertas -Pasta $pasta -Ctx $ctx -Acao $acao -Extras ([ordered]@{
            AlertName = $nome; Operation = $operacao; NotifyUser = $notificar; Threshold = $limite; TimeWindow = $janela; Justificativa = $justificativa })

    $antes = Find-AlertaPorNome -Alertas (Get-AlertasTenant) -Nome $nome
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-antes.csv' -Dados (Get-AlertSnapshot -Alert $antes -Stage 'Antes' -Nome $nome)

    $alterou = $false
    if ($antes) {
        if (-not (Test-AlertaDoItem $antes)) {
            throw "Já existe uma política '$nome' que não foi criada por este item. Ela não será alterada; escolha outro nome."
        }
        $detalhe = 'A política já existia; nenhuma criação foi executada.'
        Write-BizappLog "A política '$nome' já existe ($(Get-TextoEstadoAlerta $antes)): nada foi alterado." -Nivel sucesso
    } else {
        if (-not $ctx.TemLicenca) {
            throw 'Nenhuma licença com alertas avançados (ex.: Microsoft 365 E5 ou Office 365 E5) foi localizada no tenant. Nada foi alterado.'
        }
        if (-not $ctx.PodeCriar) {
            throw 'A conta não tem permissão para criar políticas de alerta (função Manage Alerts ou Organization Configuration no Microsoft Purview). Nada foi alterado.'
        }
        Write-BizappLog "Criando a política '$nome'..."
        New-AlertaAtividade -Tipo $tipo -Nome $nome -Operacao $operacao -Notificar $notificar -Limite $limite -Janela $janela -Justificativa $justificativa
        $alterou = $true
        $detalhe = if ($tipo -eq 'anomala') { 'Política de agregação anômala criada e habilitada; linha de base pendente.' } else { 'Política agregada simples criada e habilitada.' }
    }

    Start-Sleep -Seconds 5
    $depois = Find-AlertaPorNome -Alertas (Get-AlertasTenant) -Nome $nome
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-depois.csv' -Dados (Get-AlertSnapshot -Alert $depois -Stage 'Depois' -Nome $nome)

    # Mesma validacao do original para o que foi criado agora; se ja existia, basta existir
    $aprovada = if (-not $alterou) { $null -ne $depois }
    elseif ($tipo -eq 'simples') {
        $null -ne $depois -and [string]$depois.AggregationType -eq 'SimpleAggregation' -and [int]$depois.Threshold -eq $limite -and
        [int]$depois.TimeWindow -eq $janela -and [string]$depois.Disabled -eq 'False'
    } else {
        $null -ne $depois -and [string]$depois.AggregationType -eq 'AnomalousAggregation' -and [string]$depois.Disabled -eq 'False'
    }
    if ($aprovada -and $alterou) {
        Write-BizappLog 'Política criada, ligada e conferida no tenant.' -Nivel sucesso
        if ($tipo -eq 'anomala') {
            Write-BizappLog 'A Microsoft leva até 7 dias para aprender o padrão de cada usuário; nesse período a política não gera alertas.' -Nivel aviso
        }
    }
    Set-BizappSaida -Nome 'EstadoAlerta' -Valor (Get-TextoEstadoAlerta $depois)

    $resultado = if ($aprovada -and $tipo -eq 'anomala') { 'Configuração validada; disparo depende da linha de base' } elseif ($aprovada) { 'Validado' } else { 'Falha' }
    Write-ResumoAlertas -Pasta $pasta -Acao $acao -Ctx $ctx -Aprovada $aprovada -Alterou $alterou -Resultado $resultado -Detalhe $detalhe -Extras ([ordered]@{
            AlertName = $nome; Operation = $operacao; AggregationType = $(if ($tipo -eq 'anomala') { 'AnomalousAggregation' } else { 'SimpleAggregation' })
            Threshold = $(if ($tipo -eq 'simples') { $limite }); TimeWindow = $(if ($tipo -eq 'simples') { $janela }); Justificativa = $justificativa })
} finally {
    Disconnect-AlertasAtividade
}
