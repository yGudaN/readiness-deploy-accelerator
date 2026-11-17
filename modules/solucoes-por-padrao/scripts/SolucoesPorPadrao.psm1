# Funcoes do item "Apps e fluxos em solucoes" (AUTO-13): liga ou desliga, por ambiente, a criacao
# de canvas apps e cloud flows dentro de solucoes do Dataverse por padrao.
# O roteiro (originais/13-roteiro.docx) faz isso a mao no admin center. A documentacao da Microsoft
# ("Add canvas apps and cloud flows to a solution by default", consideracoes, item 5) diz que as
# duas chaves da tela gravam as colunas enablecanvasappsinsolutionsbydefault e
# enableflowsinsolutionbydefault da tabela organization, que a referencia lista como gravaveis.
# Validado no teste manual testes-manuais/Teste-AUTO13.ps1 (16/11/2026, CRM332072): a troca pela
# Web API apareceu igual no admin center.

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'Apps-Fluxos-Solucoes'
$script:ADMIN_SISTEMA = '627090ff-40a3-4053-8790-584edc5be201'   # id fixo do papel Administrador do sistema
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

function Connect-SolucoesPorPadrao {
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
    Write-BizappLog 'Sem esse papel a alteração deve falhar. Se o papel vem de uma equipe, pode seguir.' -Nivel aviso
}

function Get-Chaves {
    $o = @((Invoke-Dataverse -Caminho 'organizations?$select=organizationid,enablecanvasappsinsolutionsbydefault,enableflowsinsolutionbydefault').value)[0]
    [pscustomobject]@{ OrganizationId = $o.organizationid; CanvasApps = [bool]$o.enablecanvasappsinsolutionsbydefault; CloudFlows = [bool]$o.enableflowsinsolutionbydefault }
}

function Set-Chaves {
    <# Muda so as chaves diferentes do atual. Devolve a leitura depois. #>
    param([Parameter(Mandatory)][object]$Atual, [bool]$CanvasApps, [bool]$CloudFlows)
    $corpo = [ordered]@{}
    if ($CanvasApps -ne $Atual.CanvasApps) { $corpo.enablecanvasappsinsolutionsbydefault = $CanvasApps }
    if ($CloudFlows -ne $Atual.CloudFlows) { $corpo.enableflowsinsolutionbydefault = $CloudFlows }
    if (-not $corpo.Count) { return $null }
    $null = Invoke-Dataverse -Metodo PATCH -Caminho "organizations($($Atual.OrganizationId))" -Corpo $corpo
    return Get-Chaves
}

function Get-TextoChave([bool]$Ligada) { if ($Ligada) { 'Ligada' } else { 'Desligada' } }

function Write-ContextoSolucoes {
    param([string]$Pasta, [object]$Ctx, [string]$Acao, [System.Collections.IDictionary]$Extras = @{})
    $dados = [ordered]@{
        DataHoraUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-13'; Acao = $Acao
        TenantId = $Ctx.Identidade.TenantId; Conta = $Ctx.Identidade.Conta; Ambiente = $Ctx.Nome; Url = $Ctx.Url
        EnvironmentId = $Ctx.EnvironmentId; VersaoDataverse = $Ctx.Versao; AdministradorDoSistema = $Ctx.AdminSistema; Papeis = $Ctx.Papeis
    }
    foreach ($k in $Extras.Keys) { $dados[$k] = $Extras[$k] }
    Export-BizappEvidencia -Pasta $Pasta -Nome 'contexto.csv' -Dados ([pscustomobject]$dados)
}

function Write-ResumoSolucoes {
    param([string]$Pasta, [string]$Acao, [object]$Ctx, [bool]$Aprovada, [bool]$Alterou, [string]$Detalhe, [System.Collections.IDictionary]$Extras = @{})
    $resumo = [ordered]@{
        DataHoraFimUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-13'; Controle = 'Canvas apps e cloud flows em soluções por padrão'
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

Export-ModuleMember -Variable ITEM -Function Connect-SolucoesPorPadrao, Write-AvisoAdmin, Get-Chaves, Set-Chaves, Get-TextoChave, Write-ContextoSolucoes, Write-ResumoSolucoes
