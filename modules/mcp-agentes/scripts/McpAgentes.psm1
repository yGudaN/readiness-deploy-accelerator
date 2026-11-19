# Funcoes do item "MCP e recursos para agentes" (AUTO-12).
# Base: relatorio (originais/12-mcps-relatorio.docx) e script v3 do guia
# (originais/12-mcps-recursos-agentes.ps1). Do original vem a consulta somente leitura: conta,
# ambiente, conectores personalizados e politicas de DLP. O que o instalador acrescenta, validado no
# teste manual testes-manuais/Teste-AUTO12.ps1 (18/11/2026, CRM332072): a lista de clientes de MCP
# liberados no ambiente (tabela allowedmcpclient do Dataverse, coluna isenabled, a mesma da tela
# Dataverse MCP > Configuracoes avancadas do admin center).
# Conector personalizado e classificacao de DLP nao foram executados pelo autor: ficam orientados.

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'MCP-Agentes'
$script:ADMIN_SISTEMA = '627090ff-40a3-4053-8790-584edc5be201'   # id fixo do papel Administrador do sistema
$script:URL_DLP = 'https://api.bap.microsoft.com/providers/PowerPlatform.Governance/v1/policies'
$script:API_DLP = '2016-11-01'
$script:Base = $null
$script:Token = $null

function Invoke-Dataverse {
    param([string]$Metodo = 'GET', [Parameter(Mandatory)][string]$Caminho, [object]$Corpo)
    $p = @{
        Method  = $Metodo; Uri = "$script:Base/$Caminho"
        Headers = @{ Authorization = "Bearer $script:Token"; 'OData-Version' = '4.0'; 'OData-MaxVersion' = '4.0'; Accept = 'application/json' }
    }
    if ($null -ne $Corpo) { $p.Body = [System.Text.Encoding]::UTF8.GetBytes(($Corpo | ConvertTo-Json -Compress)); $p.ContentType = 'application/json; charset=utf-8' }
    try { Invoke-RestMethod @p } catch {
        $detalhe = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $null }
        $codigo = [int]$_.Exception.Response.StatusCode
        if ($codigo -eq 401) { throw 'O acesso ao Dataverse expirou ou foi negado (401). Rode a etapa de novo para fazer login.' }
        if ($codigo -eq 403) { throw "Sem permissão no Dataverse (403). Use uma conta com o papel Administrador do sistema. $detalhe" }
        throw "Dataverse: $(if ($detalhe) { $detalhe } else { $_.Exception.Message })"
    }
}

function Connect-McpAgentes {
    <# Conecta ao ambiente e confere o contexto (na primeira etapa vale a conta do login). #>
    param([Parameter(Mandatory)][hashtable]$Entrada, [switch]$PrimeiraEtapa)
    $url = ([string]$Entrada.EnvironmentUrl).Trim().TrimEnd('/')
    if ($url -notmatch '^https://[A-Za-z0-9-]+\.crm\d*\.dynamics\.com$') { throw "URL do ambiente inválida: $url" }
    $token = Get-BizappToken -Entrada $Entrada -Nome Dataverse
    $id = if ($PrimeiraEtapa) { Get-BizappIdentidade -Token $token }
    else { Assert-BizappContexto -Token $token -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta }
    $script:Base = "$url/api/data/v9.2"
    $script:Token = $token
    Write-BizappLog "Conectando a $url..."
    $org = (Invoke-Dataverse -Caminho "RetrieveCurrentOrganization(AccessType=@p)?@p=Microsoft.Dynamics.CRM.EndpointAccessType'Default'").Detail
    $eu = Invoke-Dataverse -Caminho 'WhoAmI'
    $papeis = @((Invoke-Dataverse -Caminho "systemusers($($eu.UserId))/systemuserroles_association?`$select=name,_roletemplateid_value").value)
    return [pscustomobject]@{
        Identidade = $id; Url = $url; Nome = $org.FriendlyName; EnvironmentId = $org.EnvironmentId; Versao = $org.OrganizationVersion
        AdminSistema = [bool]($papeis | Where-Object { $_._roletemplateid_value -eq $script:ADMIN_SISTEMA })
        Papeis = (@($papeis.name | Sort-Object -Unique) -join ', ')
    }
}

function Write-AvisoAdmin([object]$Ctx) {
    if ($Ctx.AdminSistema) { Write-BizappLog "Conta $($Ctx.Identidade.Conta) é Administrador do sistema no ambiente." -Nivel sucesso; return }
    Write-BizappLog "A conta não tem o papel Administrador do sistema atribuído diretamente (papéis: $(if ($Ctx.Papeis) { $Ctx.Papeis } else { 'nenhum' }))." -Nivel aviso
    Write-BizappLog 'Sem esse papel, liberar ou bloquear clientes deve falhar. Se o papel vem de uma equipe, pode seguir.' -Nivel aviso
}

# ---------------------------------------------------------------- clientes de MCP

function Get-ConjuntoClientes {
    <# Nome do conjunto (entity set) da tabela, lido dos metadados para nao depender de suposicao. #>
    $m = Invoke-Dataverse -Caminho "EntityDefinitions(LogicalName='allowedmcpclient')?`$select=EntitySetName"
    return $m.EntitySetName
}

function Get-ClientesMcp {
    param([Parameter(Mandatory)][string]$Conjunto)
    $lista = @((Invoke-Dataverse -Caminho "$Conjunto`?`$select=allowedmcpclientid,name,uniquename,applicationid,isenabled,statecode&`$orderby=name").value)
    $clientes = @(foreach ($c in $lista) {
        [pscustomobject]@{
            Id = $c.allowedmcpclientid; Nome = $c.name; NomeUnico = $c.uniquename; ApplicationId = $c.applicationid
            Liberado = [bool]$c.isenabled; Ativo = ($c.statecode -eq 0)
        }
    })
    return , @($clientes)
}

function Get-TextoClientes([object[]]$Clientes, [bool]$Liberado) {
    $nomes = @($Clientes | Where-Object { $_.Liberado -eq $Liberado -and $_.Ativo } | ForEach-Object { $_.Nome })
    if ($nomes.Count) { $nomes -join ', ' } else { 'Nenhum' }
}

function Find-ClienteMcp {
    <# Acha um cliente pelo nome, pelo nome unico ou pelo ID do aplicativo (sem diferenciar maiusculas). #>
    param([Parameter(Mandatory)][object[]]$Clientes, [Parameter(Mandatory)][string]$Texto)
    $t = $Texto.Trim()
    $achados = @($Clientes | Where-Object { $_.Nome -eq $t -or $_.NomeUnico -eq $t -or $_.ApplicationId -eq $t })
    if ($achados.Count -eq 1) { return $achados[0] }
    if ($achados.Count -gt 1) { throw "Mais de um cliente corresponde a '$t'. Use o nome único ou o ID do aplicativo." }
    throw "Nenhum cliente de MCP chamado '$t' neste ambiente. Clientes existentes: $((@($Clientes | ForEach-Object { $_.Nome }) -join ', '))."
}

function Set-ClienteMcp {
    param([Parameter(Mandatory)][string]$Conjunto, [Parameter(Mandatory)][object]$Cliente, [bool]$Liberado)
    $null = Invoke-Dataverse -Metodo PATCH -Caminho "$Conjunto($($Cliente.Id))" -Corpo @{ isenabled = $Liberado }
}

function Test-ClienteCopilotStudio([object]$Cliente) {
    return ([string]$Cliente.NomeUnico) -like 'microsoftcopilotstudio*'
}

# ---------------------------------------------------------------- conectores e DLP (somente leitura)

function Get-ConectoresPersonalizados {
    $lista = @((Invoke-Dataverse -Caminho 'connectors?$select=connectorid,name,displayname,connectortype,createdon&$orderby=displayname').value)
    $conectores = @(foreach ($c in $lista) {
        [pscustomobject]@{ Id = $c.connectorid; Nome = $c.name; NomeExibicao = $c.displayname; Tipo = $c.connectortype; CriadoEm = $c.createdon }
    })
    return , @($conectores)
}

function Get-PoliticasDlp {
    <# Le as politicas de DLP do tenant (mesma API do item "Modelo de proteção"). Devolve $null se nao der para ler. #>
    param([Parameter(Mandatory)][string]$TokenPp)
    try {
        $resp = Invoke-RestMethod -Uri "$($script:URL_DLP)?`$top=100&api-version=$($script:API_DLP)" -Headers @{ Authorization = "Bearer $TokenPp" }
    } catch {
        Write-BizappLog "Não foi possível ler as políticas de DLP: $($_.Exception.Message)" -Nivel aviso
        return $null
    }
    $politicas = @(foreach ($p in @($resp.value)) {
        if ($null -eq $p) { continue }
        $props = $p.properties
        [pscustomobject]@{
            Nome = $p.name
            NomeExibicao = $(if ($props -and $props.displayName) { $props.displayName } elseif ($p.displayName) { $p.displayName } else { $p.name })
            Bruto = $p
        }
    })
    return , @($politicas)
}

# ---------------------------------------------------------------- evidencias

function Write-ContextoMcp {
    param([string]$Pasta, [object]$Ctx, [string]$Acao, [System.Collections.IDictionary]$Extras = @{})
    $dados = [ordered]@{
        DataHoraUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-12'; Acao = $Acao
        TenantId = $Ctx.Identidade.TenantId; Conta = $Ctx.Identidade.Conta; Ambiente = $Ctx.Nome; Url = $Ctx.Url
        EnvironmentId = $Ctx.EnvironmentId; VersaoDataverse = $Ctx.Versao; AdministradorDoSistema = $Ctx.AdminSistema; Papeis = $Ctx.Papeis
    }
    foreach ($k in $Extras.Keys) { $dados[$k] = $Extras[$k] }
    Export-BizappEvidencia -Pasta $Pasta -Nome 'contexto.csv' -Dados ([pscustomobject]$dados)
}

function Write-ResumoMcp {
    param([string]$Pasta, [string]$Acao, [object]$Ctx, [bool]$Aprovada, [bool]$Alterou, [string]$Detalhe, [System.Collections.IDictionary]$Extras = @{})
    $resumo = [ordered]@{
        DataHoraFimUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-12'; Controle = 'MCP e recursos para agentes'
        AcaoSolicitada = $Acao; TenantId = $Ctx.Identidade.TenantId; Conta = $Ctx.Identidade.Conta; Ambiente = $Ctx.Url; EnvironmentId = $Ctx.EnvironmentId
    }
    foreach ($k in $Extras.Keys) { $resumo[$k] = $Extras[$k] }
    $resumo.AlteracaoExecutada = $Alterou
    $resumo.ValidacaoAprovada = $Aprovada
    $resumo.Resultado = $(if ($Aprovada) { 'Validado' } else { 'Falha' })
    $resumo.Detalhe = $Detalhe
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject]$resumo)
    ([pscustomobject]$resumo) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Pasta 'resumo.json') -Encoding utf8
    if (-not $Aprovada) { throw "A conferência depois da alteração falhou: $Detalhe" }
}

Export-ModuleMember -Variable ITEM -Function Connect-McpAgentes, Write-AvisoAdmin, Get-ConjuntoClientes, Get-ClientesMcp, Get-TextoClientes,
    Find-ClienteMcp, Set-ClienteMcp, Test-ClienteCopilotStudio, Get-ConectoresPersonalizados, Get-PoliticasDlp, Write-ContextoMcp, Write-ResumoMcp
