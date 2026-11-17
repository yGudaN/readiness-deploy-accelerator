# Funcoes do item "Configuracoes do Dataverse" (AUTO-11): idiomas, fusos horarios dos usuarios,
# equipes e caixas de correio, pela Web API do Dataverse com o token obtido pelo instalador.
# Validado no teste manual testes-manuais/Teste-AUTO11.ps1 (12/11/2026, tenant de demo).

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'Configuracoes-Dataverse'
$script:MARCA = 'Criada pelo Readiness Deploy Accelerator'
$script:ADMIN_SISTEMA = '627090ff-40a3-4053-8790-584edc5be201'   # id fixo do papel Administrador do sistema
$script:Base = $null
$script:Token = $null

# Lista aprovada do roteiro do item
$script:IDIOMAS = [ordered]@{
    '1046' = 'Português (Brasil)'; '1033' = 'Inglês (Estados Unidos)'; '3082' = 'Espanhol (Espanha)'
    '1036' = 'Francês (França)'; '1031' = 'Alemão (Alemanha)'; '1040' = 'Italiano (Itália)'
}

# Fusos oferecidos no instalador (nome padrao do Windows, igual em todos os ambientes)
$script:FUSOS = [ordered]@{
    brasilia = 'E. South America Standard Time'
    fortaleza = 'SA Eastern Standard Time'
    cuiaba = 'Central Brazilian Standard Time'
    manaus = 'SA Western Standard Time'
    riobranco = 'SA Pacific Standard Time'
    utc = 'UTC'
}

function Connect-ConfiguracoesDataverse {
    <#
    Conecta a Web API do ambiente e confere o contexto. Na primeira etapa ainda nao ha conta
    confirmada (vale a do login); nas outras, tenant e conta precisam ser os da primeira etapa.
    #>
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
    $papeis = Get-DataverseLista -Caminho "systemusers($($eu.UserId))/systemuserroles_association?`$select=name,_roletemplateid_value"
    $admin = [bool]($papeis | Where-Object { $_._roletemplateid_value -eq $script:ADMIN_SISTEMA })
    $idioma = @((Invoke-Dataverse -Caminho 'organizations?$select=languagecode').value)[0].languagecode
    return [pscustomobject]@{
        Identidade = $id; Url = $url; Nome = $org.FriendlyName; EnvironmentId = $org.EnvironmentId; OrganizationId = $org.OrganizationId
        Versao = $org.OrganizationVersion; IdiomaBase = $idioma; UsuarioId = $eu.UserId; AdminSistema = $admin
        Papeis = (@($papeis.name | Sort-Object -Unique) -join ', ')
    }
}

function Invoke-Dataverse {
    param([string]$Metodo = 'GET', [Parameter(Mandatory)][string]$Caminho, [object]$Corpo, [string]$UrlCompleta)
    $parametros = @{
        Method  = $Metodo
        Uri     = $(if ($UrlCompleta) { $UrlCompleta } else { "$script:Base/$Caminho" })
        Headers = @{ Authorization = "Bearer $script:Token"; 'OData-Version' = '4.0'; 'OData-MaxVersion' = '4.0'; Accept = 'application/json' }
    }
    if ($null -ne $Corpo) {
        $parametros.Body = [System.Text.Encoding]::UTF8.GetBytes(($Corpo | ConvertTo-Json -Depth 5 -Compress))
        $parametros.ContentType = 'application/json; charset=utf-8'
    }
    try {
        Invoke-RestMethod @parametros
    } catch {
        $detalhe = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $null }
        $codigo = [int]$_.Exception.Response.StatusCode
        if ($codigo -eq 401) { throw 'O acesso ao Dataverse expirou ou foi negado (401). Rode a etapa de novo para fazer login.' }
        if ($codigo -eq 403) { throw "Sem permissão no Dataverse (403). Use uma conta com o papel Administrador do sistema. $detalhe" }
        throw "Dataverse: $(if ($detalhe) { $detalhe } else { $_.Exception.Message })"
    }
}

function Get-DataverseLista {
    <# GET com paginacao (@odata.nextLink). #>
    param([Parameter(Mandatory)][string]$Caminho)
    $itens = [System.Collections.Generic.List[object]]::new()
    $r = Invoke-Dataverse -Caminho $Caminho
    while ($true) {
        foreach ($v in @($r.value)) { if ($null -ne $v) { $itens.Add($v) } }
        if (-not $r.'@odata.nextLink') { break }
        $r = Invoke-Dataverse -Caminho '-' -UrlCompleta $r.'@odata.nextLink'
    }
    return , $itens.ToArray()
}

function Write-AvisoAdmin {
    param([object]$Ctx)
    if ($Ctx.AdminSistema) { Write-BizappLog "Conta $($Ctx.Identidade.Conta) é Administrador do sistema no ambiente." -Nivel sucesso; return }
    # O papel tambem pode vir de uma equipe (grupo do Entra), que nao aparece aqui: so avisa
    Write-BizappLog "A conta não tem o papel Administrador do sistema atribuído diretamente (papéis: $(if ($Ctx.Papeis) { $Ctx.Papeis } else { 'nenhum' }))." -Nivel aviso
    Write-BizappLog 'Sem esse papel as alterações devem falhar. Se o papel vem de uma equipe, pode seguir.' -Nivel aviso
}

# ---------------------------------------------------------------- idiomas
# As listas IDIOMAS e FUSOS nao sao exportadas: o PowerShell nao diferencia maiusculas, e um
# $idiomas ou $fusos no script sobrescreveria a lista do modulo.
function Test-IdiomaAprovado([int]$Lcid) { return $script:IDIOMAS.Contains("$Lcid") }

function Get-NomePadraoFuso([string]$Chave) {
    <# Nome padrao do Windows do fuso escolhido no instalador (ou $null). #>
    if ($script:FUSOS.Contains($Chave)) { return $script:FUSOS[$Chave] }
    return $null
}

function Get-NomeIdioma([int]$Lcid) {
    if ($script:IDIOMAS.Contains("$Lcid")) { return "$($script:IDIOMAS["$Lcid"]) [$Lcid]" }
    try { return "$([System.Globalization.CultureInfo]::GetCultureInfo($Lcid).DisplayName) [$Lcid]" } catch { return "[$Lcid]" }
}

function Get-IdiomasAmbiente {
    $instalados = @((Invoke-Dataverse -Caminho 'RetrieveProvisionedLanguages()').RetrieveProvisionedLanguages | ForEach-Object { [int]$_ })
    $disponiveis = @((Invoke-Dataverse -Caminho 'RetrieveAvailableLanguages()').LocaleIds | ForEach-Object { [int]$_ })
    # Disponiveis = pacotes ja baixados no servidor. O admin center tambem oferece os ainda nao
    # baixados (versao 0.0), entao a lista para instalar e a aprovada menos os instalados.
    $aprovados = @($script:IDIOMAS.Keys | ForEach-Object { [int]$_ })
    return [pscustomobject]@{ Instalados = $instalados; Disponiveis = $disponiveis; ParaInstalar = @($aprovados | Where-Object { $_ -notin $instalados }) }
}

function Get-TextoIdiomas([int[]]$Lista) {
    if (-not $Lista.Count) { return 'Nenhum' }
    return (@($Lista | ForEach-Object { Get-NomeIdioma $_ }) -join ', ')
}

# ---------------------------------------------------------------- fusos
function Get-Fusos { Get-DataverseLista -Caminho 'timezonedefinitions?$select=timezonecode,userinterfacename,standardname&$orderby=userinterfacename' }

function Get-UsuariosFuso {
    <#
    Usuarios ativos de pessoas (sem usuarios de aplicativo, suporte da Microsoft ou nao interativos)
    com o fuso atual. accessmode: 0 leitura e gravacao, 1 administrativo, 2 leitura.
    #>
    param([object[]]$Fusos)
    $usuarios = Get-DataverseLista -Caminho 'systemusers?$select=systemuserid,fullname,internalemailaddress,domainname,accessmode,isdisabled,applicationid&$filter=isdisabled eq false and (accessmode eq 0 or accessmode eq 1 or accessmode eq 2)'
    $config = Get-DataverseLista -Caminho 'usersettingscollection?$select=systemuserid,timezonecode'
    $porId = @{}
    foreach ($c in $config) { $porId[[string]$c.systemuserid] = $c.timezonecode }
    return , @(foreach ($u in $usuarios) {
            if ($u.applicationid) { continue }
            $codigo = $porId[[string]$u.systemuserid]
            $fuso = $Fusos | Where-Object timezonecode -eq $codigo | Select-Object -First 1
            [pscustomobject]@{
                Nome = $u.fullname; Email = $(if ($u.internalemailaddress) { $u.internalemailaddress } else { $u.domainname })
                UserId = $u.systemuserid; TimeZoneCode = $codigo; Fuso = $fuso.userinterfacename; FusoPadrao = $fuso.standardname
            }
        })
}

function Get-TextoFusos {
    <# Ex.: "174 usuários: 174 em (GMT) Coordinated Universal Time" (os 2 fusos mais comuns). #>
    param([object[]]$Usuarios)
    if (-not $Usuarios.Count) { return 'Nenhum usuário' }
    $grupos = @($Usuarios | Group-Object Fuso | Sort-Object Count -Descending)
    $partes = @($grupos | Select-Object -First 2 | ForEach-Object { "$($_.Count) em $(if ($_.Name) { $_.Name } else { 'fuso não definido' })" })
    if ($grupos.Count -gt 2) { $partes += "$(($grupos | Select-Object -Skip 2 | Measure-Object Count -Sum).Sum) em outros" }
    return "$($Usuarios.Count) usuários: $($partes -join '; ')"
}

function Set-FusoUsuario {
    param([Parameter(Mandatory)][string]$UserId, [Parameter(Mandatory)][int]$Codigo)
    $null = Invoke-Dataverse -Metodo PATCH -Caminho "usersettingscollection($UserId)" -Corpo @{ timezonecode = $Codigo }
    return [int](Invoke-Dataverse -Caminho "usersettingscollection($UserId)?`$select=timezonecode").timezonecode
}

# ---------------------------------------------------------------- equipes
function Get-UnidadesNegocio { Get-DataverseLista -Caminho 'businessunits?$select=businessunitid,name,_parentbusinessunitid_value,isdisabled&$orderby=name' }

function Get-Equipes {
    Get-DataverseLista -Caminho 'teams?$select=teamid,name,teamtype,membershiptype,description,azureactivedirectoryobjectid,isdefault,_businessunitid_value&$orderby=name'
}

function Get-TextoTipoEquipe([int]$Tipo) {
    switch ($Tipo) { 0 { 'Proprietária' } 1 { 'Acesso' } 2 { 'Grupo de segurança do Entra' } 3 { 'Grupo do Office do Entra' } default { "Tipo $Tipo" } }
}

function Test-EquipeDoItem([object]$Equipe) { return ([string]$Equipe.description).Contains($script:MARCA) }

# ---------------------------------------------------------------- caixas de correio
function Get-Caixas {
    Get-DataverseLista -Caminho 'mailboxes?$select=mailboxid,name,emailaddress,enabledforincomingemail,enabledforoutgoingemail,emailrouteraccessapproval,incomingemailstatus,outgoingemailstatus,_regardingobjectid_value'
}

function Get-TextoCaixa([object]$Caixa) {
    if (-not $Caixa) { return 'Não encontrada' }
    $e = if ($Caixa.enabledforincomingemail) { 'ligada' } else { 'desligada' }
    $s = if ($Caixa.enabledforoutgoingemail) { 'ligada' } else { 'desligada' }
    $aprov = switch ([int]$Caixa.emailrouteraccessapproval) { 1 { 'endereço aprovado' } 2 { 'aprovação pendente' } 3 { 'aprovação rejeitada' } default { 'endereço não aprovado' } }
    return "$($Caixa.emailaddress) · entrada $e, saída $s$(if ($aprov) { " · $aprov" })"
}

# ---------------------------------------------------------------- evidencias
function Write-ContextoDataverse {
    param([string]$Pasta, [object]$Ctx, [string]$Acao, [System.Collections.IDictionary]$Extras = @{})
    $dados = [ordered]@{
        DataHoraUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-11'; Acao = $Acao
        TenantId = $Ctx.Identidade.TenantId; Conta = $Ctx.Identidade.Conta; Ambiente = $Ctx.Nome; Url = $Ctx.Url
        EnvironmentId = $Ctx.EnvironmentId; OrganizationId = $Ctx.OrganizationId; VersaoDataverse = $Ctx.Versao
        IdiomaBase = $Ctx.IdiomaBase; AdministradorDoSistema = $Ctx.AdminSistema; Papeis = $Ctx.Papeis
    }
    foreach ($k in $Extras.Keys) { $dados[$k] = $Extras[$k] }
    Export-BizappEvidencia -Pasta $Pasta -Nome 'contexto.csv' -Dados ([pscustomobject]$dados)
}

function Write-ResumoDataverse {
    <# resumo.csv / resumo.json; interrompe se a validacao falhou. #>
    param([string]$Pasta, [string]$Acao, [object]$Ctx, [bool]$Aprovada, [bool]$Alterou, [string]$Detalhe, [System.Collections.IDictionary]$Extras = @{})
    $resumo = [ordered]@{
        DataHoraFimUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-11'; Controle = 'Configurações do Dataverse'
        AcaoSolicitada = $Acao; TenantId = $Ctx.Identidade.TenantId; Conta = $Ctx.Identidade.Conta; Ambiente = $Ctx.Url
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

Export-ModuleMember -Variable ITEM, MARCA -Function Connect-ConfiguracoesDataverse, Test-IdiomaAprovado, Get-NomePadraoFuso, Invoke-Dataverse, Get-DataverseLista, `
    Write-AvisoAdmin, Get-NomeIdioma, Get-IdiomasAmbiente, Get-TextoIdiomas, Get-Fusos, Get-UsuariosFuso, Get-TextoFusos, Set-FusoUsuario, `
    Get-UnidadesNegocio, Get-Equipes, Get-TextoTipoEquipe, Test-EquipeDoItem, Get-Caixas, Get-TextoCaixa, Write-ContextoDataverse, Write-ResumoDataverse
