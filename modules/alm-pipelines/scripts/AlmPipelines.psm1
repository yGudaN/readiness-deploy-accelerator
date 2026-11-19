# Funcoes do item "ALM com Pipelines" (AUTO-09): preflight de DEV, HML e PROD para Power Platform
# Pipelines no host da plataforma (sem host dedicado), como o roteiro (originais/09-roteiro.docx).
# Validado no teste manual testes-manuais/Teste-AUTO09.ps1 (17/11/2026, CRM332072):
#  - preflight igual ao do roteiro (Dataverse nos tres, gerenciado em HML e PROD, regiao);
#  - com o DEV no Brasil e o host da plataforma nos EUA, o registro do HML no host ficou invalido
#    (erro 0x80040265); com os tres na regiao do tenant, pipeline e deployment funcionaram;
#  - o host da plataforma e oculto: "pac pipeline list" no DEV responde "Resource not found for
#    the segment 'deploymentpipelines'". Por isso o pipeline e criado e conferido na tela.

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'ALM-Pipelines'
$script:BAP = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform'
$script:Token = $null

function Connect-AlmPipelines {
    param([Parameter(Mandatory)][hashtable]$Entrada, [switch]$PrimeiraEtapa)
    $script:Token = Get-BizappToken -Entrada $Entrada -Nome Admin
    if ($PrimeiraEtapa) { return Get-BizappIdentidade -Token $script:Token }
    return Assert-BizappContexto -Token $script:Token -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta
}

function Invoke-Admin {
    param([string]$Metodo = 'GET', [Parameter(Mandatory)][string]$Url, [object]$Corpo)
    $p = @{ Method = $Metodo; Uri = $Url; Headers = @{ Authorization = "Bearer $script:Token"; Accept = 'application/json' } }
    if ($null -ne $Corpo) { $p.Body = [System.Text.Encoding]::UTF8.GetBytes(($Corpo | ConvertTo-Json -Depth 6 -Compress)); $p.ContentType = 'application/json; charset=utf-8' }
    try { Invoke-RestMethod @p } catch {
        $codigo = [int]$_.Exception.Response.StatusCode
        $detalhe = try { $e = $_.ErrorDetails.Message | ConvertFrom-Json; "$($e.error.code): $($e.error.message)" } catch { $null }
        if ($codigo -eq 401) { throw 'O acesso ao admin do Power Platform expirou ou foi negado (401). Rode a etapa de novo para fazer login.' }
        if ($codigo -eq 403) { throw "Sem permissão (403). É preciso ser Administrador do Power Platform ou Administrador Global. $detalhe" }
        throw "Admin do Power Platform (HTTP $codigo): $(if ($detalhe) { $detalhe } else { $_.Exception.Message })"
    }
}

function ConvertTo-Ambiente([object]$A) {
    $p = $A.properties
    [pscustomobject]@{
        Nome = $p.displayName; EnvironmentId = $A.name; Tipo = $p.environmentSku; Regiao = $A.location
        UrlDataverse = $p.linkedEnvironmentMetadata.instanceUrl; Gerenciado = ($p.governanceConfiguration.protectionLevel -eq 'Standard')
        Descricao = $p.description
    }
}

function Get-Ambientes {
    $itens = [System.Collections.Generic.List[object]]::new()
    $url = "$script:BAP/scopes/admin/environments?api-version=2021-04-01"
    while ($url) {
        $r = Invoke-Admin -Url $url
        foreach ($v in @($r.value)) { if ($null -ne $v) { $itens.Add((ConvertTo-Ambiente $v)) } }
        $url = [string]$r.nextLink
    }
    return , $itens.ToArray()
}

function Get-Ambiente([string]$Id) { ConvertTo-Ambiente (Invoke-Admin -Url "$script:BAP/scopes/admin/environments/$Id`?api-version=2021-04-01") }

function Find-Ambiente {
    <# Ambiente pelo ID ou pelo nome (sem diferenciar maiusculas). Nome repetido exige o ID. #>
    param([object[]]$Ambientes, [string]$Texto, [string]$Camada)
    $t = ([string]$Texto).Trim()
    if (-not $t) { throw "Informe o ambiente $Camada. Nada foi alterado." }
    $porId = @($Ambientes | Where-Object { $_.EnvironmentId -eq $t })
    if ($porId) { return $porId[0] }
    $porNome = @($Ambientes | Where-Object { [string]::Equals($_.Nome, $t, [StringComparison]::OrdinalIgnoreCase) })
    if ($porNome.Count -gt 1) { throw "Há mais de um ambiente chamado '$t'. Informe o ID do ambiente $Camada. Nada foi alterado." }
    if (-not $porNome) { throw "Ambiente $Camada '$t' não encontrado. Confira o nome na lista da consulta. Nada foi alterado." }
    return $porNome[0]
}

function Get-SugestoesDoItem10 {
    <# DEV, HML e PROD criados pelo item "Ambientes DEV, HML e PROD" neste computador, se houver. #>
    param([object[]]$Ambientes, [string]$TenantId)
    $sug = @{}
    $arq = Join-Path (Get-BizappPastaEvidencias -Item 'Ambientes-Dev-Hml-Prod') 'ambientes-criados.csv'
    $registro = if (Test-Path -LiteralPath $arq) { @(Import-Csv -LiteralPath $arq | Where-Object TenantId -eq $TenantId) } else { @() }
    foreach ($c in 'DEV', 'HML', 'PROD') {
        $linha = $registro | Where-Object { $_.Camada -eq $c -and ($Ambientes.EnvironmentId -contains $_.EnvironmentId) } | Select-Object -Last 1
        $amb = if ($linha) { $Ambientes | Where-Object EnvironmentId -eq $linha.EnvironmentId | Select-Object -First 1 }
        else { $Ambientes | Where-Object { ([string]$_.Descricao) -match "Camada $c" } | Select-Object -First 1 }
        if ($amb) { $sug[$c] = $amb.Nome }
    }
    return $sug
}

function Set-AmbienteGerenciado {
    <# Liga o ambiente gerenciado (protectionLevel Standard), como no item 10; confere relendo. #>
    param([Parameter(Mandatory)][string]$Id)
    $null = Invoke-Admin -Metodo POST -Url "$script:BAP/environments/$Id/governanceConfiguration?api-version=2021-04-01" -Corpo @{ protectionLevel = 'Standard'; settings = @{ extendedSettings = @{} } }
    for ($i = 1; $i -le 9; $i++) {
        Start-Sleep -Seconds 20
        $amb = Get-Ambiente $Id
        if ($amb.Gerenciado) { return $amb }
    }
    return $amb
}

function Get-TextoAmbiente([object]$A) {
    "$($A.Nome) · $($A.Tipo), $($A.Regiao), $(if ($A.UrlDataverse) { 'com Dataverse' } else { 'sem Dataverse' }), $(if ($A.Gerenciado) { 'gerenciado' } else { 'não gerenciado' })"
}

function Write-ResumoAlm {
    param([string]$Pasta, [string]$Acao, [object]$Identidade, [bool]$Aprovada, [bool]$Alterou, [string]$Detalhe, [System.Collections.IDictionary]$Extras = @{})
    $resumo = [ordered]@{
        DataHoraFimUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-09'; Controle = 'ALM para agentes com Power Platform Pipelines'
        AcaoSolicitada = $Acao; TenantId = $Identidade.TenantId; Conta = $Identidade.Conta
    }
    foreach ($k in $Extras.Keys) { $resumo[$k] = $Extras[$k] }
    $resumo.AlteracaoExecutada = $Alterou
    $resumo.ValidacaoAprovada = $Aprovada
    $resumo.Resultado = $(if ($Aprovada) { 'Validado' } else { 'Falha' })
    $resumo.Detalhe = $Detalhe
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject]$resumo)
    ([pscustomobject]$resumo) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Pasta 'resumo.json') -Encoding utf8
    if (-not $Aprovada) { throw $Detalhe }
}

Export-ModuleMember -Variable ITEM -Function Connect-AlmPipelines, Get-Ambientes, Get-Ambiente, Find-Ambiente, Get-SugestoesDoItem10, `
    Set-AmbienteGerenciado, Get-TextoAmbiente, Write-ResumoAlm
