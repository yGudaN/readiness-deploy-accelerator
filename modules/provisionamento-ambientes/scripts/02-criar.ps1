#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-10 · Criar um ambiente (DEV, HML ou PROD), seguindo o roteiro do item: regiao, tipo,
    Dataverse opcional (idioma e moeda da regiao), grupo de seguranca, dominio e Managed
    Environment. Exige digitar CRIAR a cada camada. Nao cria PROD antes de DEV e HML. Nao duplica
    nomes. Nunca exclui ambientes (o roteiro proibe excluir como rollback).
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ProvisionamentoAmbientes.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'Camada', 'TipoAmbiente', 'Regiao', 'MacroRegiao', 'Dataverse', 'Gerenciado'

# Secao 9 do roteiro: nada e reaproveitado sem confirmacao. A confirmacao vale para uma criacao so.
$confirmou = ([string]$entrada.ConfirmacaoCriar).Trim() -ceq 'CRIAR'
Set-BizappSaida -Nome 'ConfirmacaoCriar' -Valor ''
if (-not $confirmou) { throw 'Revise o resumo e digite CRIAR no campo de confirmação. Nada foi criado.' }

$camada = [string]$entrada.Camada
if ($camada -notin 'DEV', 'HML', 'PROD') { throw "Camada inválida: $camada" }
$nome = ([string]$entrada.NomeAmbiente).Trim()
if (-not $nome) { throw 'Informe o nome do ambiente. Nada foi criado.' }
$tipo = [string]$entrada.TipoAmbiente
if ($tipo -notin 'Sandbox', 'Production') { throw "Tipo inválido: $tipo" }
$regiao = [string]$entrada.Regiao
$macro = if ([string]$entrada.MacroRegiao -eq 'auto') { Get-MacroRegiao $regiao } else { [string]$entrada.MacroRegiao }
$comDataverse = [string]$entrada.Dataverse -eq 'sim'
$gerenciado = [string]$entrada.Gerenciado -eq 'sim'
$grupo = ([string]$entrada.GrupoSeguranca).Trim()
$dominio = ([string]$entrada.Dominio).Trim().ToLowerInvariant()
$descricao = ([string]$entrada.Finalidade).Trim()
$idioma = ([string]$entrada.Idioma).Trim()
$moeda = ([string]$entrada.Moeda).Trim().ToUpperInvariant()
# Regra do roteiro: ambiente gerenciado (Sandbox ou Producao) exige Dataverse
if ($gerenciado -and -not $comDataverse) { throw 'Ambiente gerenciado exige Dataverse: escolha "Sim" em Dataverse ou "Não" em ambiente gerenciado. Nada foi criado.' }
if ($comDataverse) {
    if ($idioma -notmatch '^\d{4,5}$') { throw 'Informe o idioma base pelo código (ex.: 1046 para português do Brasil). Nada foi criado.' }
    if ($moeda -notmatch '^[A-Z]{3}$') { throw 'Informe a moeda com o código de 3 letras (ex.: BRL). Nada foi criado.' }
}

$id = Connect-Provisionamento -Entrada $entrada -ComPowerPlatform
$acao = "Criar-$camada"
$pasta = New-BizappEvidencias -Item $ITEM -Acao $acao
Write-ContextoProvisionamento -Pasta $pasta -Identidade $id -Acao $acao -Extras ([ordered]@{
        Camada = $camada; Nome = $nome; Descricao = $descricao; Tipo = $tipo; Regiao = $regiao; MacroRegiao = $macro; Dataverse = $comDataverse
        Idioma = $idioma; Moeda = $moeda; GrupoSeguranca = $grupo; Dominio = $dominio; Gerenciado = $gerenciado })

$antes = Set-AmbientesDoItem -Ambientes (Get-Ambientes) -TenantId $id.TenantId
Export-BizappEvidencia -Pasta $pasta -Nome 'ambientes-antes.csv' -Dados $antes
$doItem = @($antes | Where-Object CriadoPorEsteItem)

# Resumo antes de criar (o roteiro mostra o resumo e pede CRIAR)
Write-BizappLog '=== Resumo ==='
Write-BizappLog "Camada: $camada · Nome: $nome · Tipo: $tipo"
Write-BizappLog "Região: $regiao (se o tenant exigir, macro região $macro)"
Write-BizappLog "Dataverse: $(if ($comDataverse) { "sim, idioma $idioma, moeda $moeda, domínio $(if ($dominio) { $dominio } else { 'automático' })" } else { 'não' })"
Write-BizappLog "Grupo de segurança: $(if ($grupo) { $grupo } else { 'nenhum' }) · Gerenciado: $(if ($gerenciado) { 'sim' } else { 'não' })"
if ($descricao) { Write-BizappLog "Descrição: $descricao" }

# Nao duplica
$mesmoNome = $antes | Where-Object { [string]::Equals($_.Nome, $nome, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
if ($mesmoNome) { throw "Já existe um ambiente chamado '$($mesmoNome.Nome)'. Escolha outro nome. Nada foi criado." }

# Secao 11 do roteiro: nao criar PROD antes de validar DEV e HML
if ($camada -eq 'PROD') {
    $faltam = @('DEV', 'HML' | Where-Object { $c = $_; -not ($doItem | Where-Object { $_.Camada -eq $c -and $_.Estado -eq 'Succeeded' }) })
    if ($faltam) { throw "Crie e valide $($faltam -join ' e ') antes do PROD, como pede o roteiro. Nada foi criado." }
}

# Mesma regiao em todas as camadas
$outrasRegioes = @($doItem | Where-Object { $_.Regiao -and $_.Regiao -ne $regiao } | ForEach-Object { "$($_.Camada) em $($_.Regiao)" })
if ($outrasRegioes) { Write-BizappLog "Atenção: a região escolhida ($regiao) é diferente da de outros ambientes deste item ($($outrasRegioes -join ', ')). O recomendado é usar a mesma região em DEV, HML e PROD." -Nivel aviso }

# Idioma e moeda (secao 5 do roteiro: valores da regiao)
if ($comDataverse) {
    $idiomas = Get-ListaRegiao -Tipo environmentLanguages -Locais @($regiao, $macro)
    $moedas = Get-ListaRegiao -Tipo environmentCurrencies -Locais @($regiao, $macro)
    if ($idiomas.Count -and $idioma -notin $idiomas) { throw "O idioma $idioma não está na lista da região ($($idiomas.Count) idiomas disponíveis; veja idiomas.csv nas evidências). Nada foi criado." }
    if ($moedas.Count -and $moeda -notin $moedas) { throw "A moeda $moeda não está na lista da região. Nada foi criado." }
    Export-BizappEvidencia -Pasta $pasta -Nome 'idiomas.csv' -Dados @($idiomas | ForEach-Object { [pscustomobject]@{ LCID = $_ } })
    Export-BizappEvidencia -Pasta $pasta -Nome 'moedas.csv' -Dados @($moedas | ForEach-Object { [pscustomobject]@{ Moeda = $_ } })
    if ($idiomas.Count -and $moedas.Count) { Write-BizappLog "Idioma $idioma e moeda $moeda conferidos na lista da região." -Nivel discreto }
    else { Write-BizappLog 'A lista de idiomas ou moedas não veio; o Power Platform confere na criação.' -Nivel aviso }
}

$corpo = [ordered]@{ displayName = $nome; environmentSku = $tipo }
if ($descricao) { $corpo.description = $descricao }
if ($comDataverse) {
    $metadados = [ordered]@{ baseLanguageCode = [int]$idioma; currency = @{ code = $moeda } }
    if ($grupo) { $metadados.securityGroupId = $grupo }
    if ($dominio) { $metadados.domainName = $dominio }
    $corpo.databaseType = 'CommonDataService'
    $corpo.linkedEnvironmentMetadata = $metadados
}

Write-BizappLog "Criando '$nome'..."
$inicio = Get-Date
$amb = New-AmbienteProvisionado -Corpo $corpo -Regiao $regiao -MacroRegiao $macro -ComDataverse:$comDataverse -IdsAntes @($antes.EnvironmentId)
($corpo | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $pasta 'pedido-criacao.json') -Encoding utf8
Write-BizappLog "Ambiente criado em $([int]((Get-Date) - $inicio).TotalMinutes) min ($($amb.ModoRegiao)), no datacenter $($amb.Regiao)$(if ($amb.UrlDataverse) { ": $($amb.UrlDataverse)" })." -Nivel sucesso
Add-RegistroItem -Ambiente $amb -Camada $camada -TenantId $id.TenantId -Conta $id.Conta -MacroRegiao $(if ($amb.ModoRegiao -like 'macro*') { $macro } else { '' })

if ($gerenciado) {
    Write-BizappLog 'Tornando o ambiente gerenciado...'
    Write-BizappProgresso -Percentual 97 -Fase 'Tornando o ambiente gerenciado'
    $amb = Set-AmbienteGerenciado -Id $amb.EnvironmentId
}
Write-BizappProgresso -Percentual 100 -Fase 'Concluído'
Export-BizappEvidencia -Pasta $pasta -Nome 'ambiente-criado.csv' -Dados $amb

# Validacao (secao 8 do roteiro)
$falhas = @()
if ($amb.Nome -ne $nome) { $falhas += "nome $($amb.Nome)" }
if ($amb.Tipo -ne $tipo) { $falhas += "tipo $($amb.Tipo)" }
if ($comDataverse -and -not $amb.UrlDataverse) { $falhas += 'sem Dataverse' }
if ($grupo -and $amb.GrupoSeguranca -ne $grupo) { $falhas += "grupo $($amb.GrupoSeguranca)" }
if ($gerenciado -and -not $amb.Gerenciado) { $falhas += 'ainda não aparece como gerenciado' }
$depoisOutras = @($doItem | Where-Object { $_.Regiao -and $_.Regiao -ne $amb.Regiao } | ForEach-Object { "$($_.Camada) em $($_.Regiao)" })
if ($depoisOutras) { Write-BizappLog "Atenção: este ambiente ficou em $($amb.Regiao), diferente de $($depoisOutras -join ', ')." -Nivel aviso }
$aprovada = -not $falhas
$detalhe = if ($aprovada) { "Ambiente '$nome' criado e conferido: $(Get-TextoAmbiente $amb)." } else { "Ambiente '$nome' criado, mas a conferência encontrou: $($falhas -join '; ')." }
if ($aprovada) { Write-BizappLog $detalhe -Nivel sucesso }
Write-BizappLog "Environment ID ($camada): $($amb.EnvironmentId)"
Write-BizappLog 'Próximos passos do roteiro: abra o ambiente e valide criar uma solução, uma conexão e as permissões. Depois revise DLP, grupos de ambientes, roteamento, pipelines, auditoria e políticas de agentes.' -Nivel aviso

$depois = Set-AmbientesDoItem -Ambientes (Get-Ambientes) -TenantId $id.TenantId
Set-BizappSaida -Nome 'EstadoAmbiente' -Valor "$camada · $(Get-TextoAmbiente $amb)"
Set-BizappSaida -Nome 'UrlAmbiente' -Valor ([string]$amb.UrlDataverse)
Set-BizappSaida -Nome 'EnvironmentIdCriado' -Valor $amb.EnvironmentId
Set-BizappSaida -Nome 'AmbientesDoItem' -Valor (Get-TextoAmbientesDoItem $depois)

Write-ResumoProvisionamento -Pasta $pasta -Acao $acao -Identidade $id -Aprovada $aprovada -Alterou $true -Detalhe $detalhe `
    -Extras ([ordered]@{ Camada = $camada; Nome = $nome; EnvironmentId = $amb.EnvironmentId; Regiao = $amb.Regiao; Modo = $amb.ModoRegiao; Url = $amb.UrlDataverse; Gerenciado = $amb.Gerenciado })
