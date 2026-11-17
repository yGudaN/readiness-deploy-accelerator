# Funcoes do item "Ambientes DEV, HML e PROD" (AUTO-10): consulta e criacao de ambientes do
# Power Platform com Dataverse e, opcionalmente, Managed Environment.
# Validado no teste manual testes-manuais/Teste-AUTO10.ps1 (13/11/2026, tenant de demo crm332072):
#  - o New-AdminPowerAppEnvironment do roteiro foi recusado com MacroRegionRequired; a criacao vai
#    pela API de provisionamento (api.powerplatform.com, 2024-10-01) com macroRegion, como orienta a
#    Microsoft;
#  - idiomas e moedas so vieram pela macro regiao com a API 2021-04-01 (a mesma do PAC CLI 2.15);
#  - o Managed Environment usa o mesmo endereco do Set-AdminPowerAppEnvironmentGovernanceConfiguration.
# Fiel ao roteiro: regiao especifica primeiro (macro regiao so quando o tenant exige), Dataverse
# opcional, qualquer idioma da regiao, descricao como digitada (os ambientes do item ficam num
# registro local, nao numa marca na descricao), PROD so depois de DEV e HML, espera de 120 min.

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'Ambientes-Dev-Hml-Prod'
# Marca usada na descricao pela v1.6.0: ambientes com ela tambem contam como criados pelo item
$script:MARCA = 'Criado pelo Readiness Deploy Accelerator'
# Regiao especifica -> macro regiao (pagina "macro region geography" da Microsoft)
$script:MACRO = @{
    unitedstates = 'north-america'; canada = 'north-america'; southamerica = 'the-americas'; unitedkingdom = 'europe-uk'
    europe = 'eu-efta'; france = 'eu-efta'; germany = 'eu-efta'; switzerland = 'eu-efta'; norway = 'eu-efta'; sweden = 'eu-efta'; italy = 'eu-efta'; poland = 'eu-efta'
    southafrica = 'emea'; unitedarabemirates = 'emea'
    asia = 'asia-pacific'; australia = 'asia-pacific'; japan = 'asia-pacific'; india = 'asia-pacific'; korea = 'asia-pacific'
}
$script:BAP = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform'
$script:PPAPI = 'https://api.powerplatform.com'
$script:TokenBap = $null
$script:TokenPp = $null

function Connect-Provisionamento {
    <#
    Guarda os tokens e confere o contexto. Na primeira etapa vale a conta do login; nas outras,
    tenant e conta precisam ser os confirmados na primeira etapa.
    #>
    param([Parameter(Mandatory)][hashtable]$Entrada, [switch]$PrimeiraEtapa, [switch]$ComPowerPlatform)
    $script:TokenBap = Get-BizappToken -Entrada $Entrada -Nome Admin
    if ($ComPowerPlatform) { $script:TokenPp = Get-BizappToken -Entrada $Entrada -Nome PowerPlatform }
    if ($PrimeiraEtapa) { return Get-BizappIdentidade -Token $script:TokenBap }
    return Assert-BizappContexto -Token $script:TokenBap -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta
}

function Invoke-Admin {
    <# Chamada ao servico de administracao (BAP) ou a Power Platform API, com erros legiveis. #>
    param([string]$Metodo = 'GET', [Parameter(Mandatory)][string]$Url, [object]$Corpo, [switch]$PowerPlatform, [switch]$Resposta)
    $token = if ($PowerPlatform) { $script:TokenPp } else { $script:TokenBap }
    $p = @{ Method = $Metodo; Uri = $Url; Headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' } }
    if ($null -ne $Corpo) {
        $p.Body = [System.Text.Encoding]::UTF8.GetBytes(($Corpo | ConvertTo-Json -Depth 8 -Compress))
        $p.ContentType = 'application/json; charset=utf-8'
    }
    try {
        if ($Resposta) { return Invoke-WebRequest @p -UseBasicParsing }
        return Invoke-RestMethod @p
    } catch {
        $codigo = [int]$_.Exception.Response.StatusCode
        $detalhe = try {
            $e = $_.ErrorDetails.Message | ConvertFrom-Json
            if ($e.error) { "$($e.error.code): $($e.error.message)" }
            elseif ($e.errorDetail) { "$($e.errorDetail.code): $(($e.errorDetail.fieldErrors.PSObject.Properties | ForEach-Object { "$($_.Name) - $($_.Value.errorMessages -join ' ')" }) -join '; ')" }
            else { $_.ErrorDetails.Message }
        } catch { $null }
        if ($codigo -eq 401) { throw 'O acesso ao admin do Power Platform expirou ou foi negado (401). Rode a etapa de novo para fazer login.' }
        if ($codigo -eq 403) { throw "Sem permissão (403). É preciso ser Administrador do Power Platform ou Administrador Global. $detalhe" }
        throw "Admin do Power Platform (HTTP $codigo): $(if ($detalhe) { $detalhe } else { $_.Exception.Message })"
    }
}

function Get-Lista {
    param([Parameter(Mandatory)][string]$Url)
    $itens = [System.Collections.Generic.List[object]]::new()
    while ($Url) {
        $r = Invoke-Admin -Url $Url
        foreach ($v in @($r.value)) { if ($null -ne $v) { $itens.Add($v) } }
        $Url = [string]$r.nextLink
    }
    return , $itens.ToArray()
}

# ---------------------------------------------------------------- ambientes
function ConvertTo-Ambiente([object]$A) {
    $p = $A.properties
    [pscustomobject]@{
        Nome = $p.displayName; EnvironmentId = $A.name; Tipo = $p.environmentSku; Regiao = $A.location
        Estado = $p.provisioningState; UrlDataverse = $p.linkedEnvironmentMetadata.instanceUrl
        GrupoSeguranca = $p.linkedEnvironmentMetadata.securityGroupId; Gerenciado = ($p.governanceConfiguration.protectionLevel -eq 'Standard')
        Descricao = $p.description; CriadoPorEsteItem = ([string]$p.description).Contains($script:MARCA); CriadoEm = $p.createdTime
        Camada = $(if ([string]$p.description -match 'Camada (DEV|HML|PROD)') { $Matches[1] } else { '' })
    }
}

# ---------------------------------------------------------------- registro dos ambientes do item
function Get-ArquivoRegistro { Join-Path (Get-BizappPastaEvidencias -Item $script:ITEM) 'ambientes-criados.csv' }

function Get-RegistroItem([string]$TenantId) {
    <# Ambientes criados por este item neste computador (secao 9 do roteiro: Environment ID de cada camada). #>
    $arq = Get-ArquivoRegistro
    if (-not (Test-Path -LiteralPath $arq)) { return , @() }
    return , @(Import-Csv -LiteralPath $arq | Where-Object { $_.TenantId -eq $TenantId })
}

function Add-RegistroItem {
    param([Parameter(Mandatory)][object]$Ambiente, [string]$Camada, [string]$TenantId, [string]$Conta, [string]$MacroRegiao)
    $arq = Get-ArquivoRegistro
    New-Item -ItemType Directory -Force -Path (Split-Path $arq) | Out-Null
    $nova = [pscustomobject]@{
        TenantId = $TenantId; EnvironmentId = $Ambiente.EnvironmentId; Camada = $Camada; Nome = $Ambiente.Nome; Tipo = $Ambiente.Tipo
        Regiao = $Ambiente.Regiao; MacroRegiao = $MacroRegiao; UrlDataverse = $Ambiente.UrlDataverse
        Conta = $Conta; CriadoEmUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    # Regrava o arquivo inteiro (se as colunas mudarem entre versoes, o -Append recusaria a linha)
    $linhas = @(if (Test-Path -LiteralPath $arq) { Import-Csv -LiteralPath $arq }) + $nova
    $linhas | Select-Object TenantId, EnvironmentId, Camada, Nome, Tipo, Regiao, MacroRegiao, UrlDataverse, Conta, CriadoEmUtc |
        Export-Csv -LiteralPath $arq -NoTypeInformation -Encoding utf8
}

function Set-AmbientesDoItem {
    <# Marca na lista os ambientes do item (registro local ou marca da v1.6.0) e a camada de cada um. #>
    param([object[]]$Ambientes, [string]$TenantId)
    $registro = Get-RegistroItem $TenantId
    foreach ($a in $Ambientes) {
        $linha = $registro | Where-Object EnvironmentId -eq $a.EnvironmentId | Select-Object -Last 1
        if ($linha) { $a.CriadoPorEsteItem = $true; $a.Camada = $linha.Camada }
    }
    return , @($Ambientes)
}

function Get-TextoAmbientesDoItem([object[]]$Ambientes) {
    $doItem = @($Ambientes | Where-Object CriadoPorEsteItem | Sort-Object { @('DEV', 'HML', 'PROD').IndexOf($_.Camada) })
    if (-not $doItem) { return 'Nenhum' }
    return ($doItem | ForEach-Object { "$(if ($_.Camada) { "$($_.Camada): " })$($_.Nome) ($($_.Regiao))" }) -join '; '
}

function Get-Ambientes {
    $lista = Get-Lista -Url "$script:BAP/scopes/admin/environments?`$expand=properties.capacity&api-version=2021-04-01"
    return , @($lista | ForEach-Object { ConvertTo-Ambiente $_ })
}

function Get-Ambiente([string]$Id) {
    return ConvertTo-Ambiente (Invoke-Admin -Url "$script:BAP/scopes/admin/environments/$Id`?api-version=2021-04-01")
}

function Get-CapacidadeUsada {
    <# Banco de dados usado por ambiente (MB), lido junto com a lista. #>
    $lista = Get-Lista -Url "$script:BAP/scopes/admin/environments?`$expand=properties.capacity&api-version=2021-04-01"
    return , @(foreach ($a in $lista) {
            foreach ($c in @($a.properties.capacity)) {
                if ($c) { [pscustomobject]@{ Ambiente = $a.properties.displayName; Tipo = $c.capacityType; UsadoMB = $c.actualConsumption } }
            }
        })
}

function Get-TextoAmbiente([object]$A) {
    if (-not $A) { return 'Não existe' }
    $partes = @($A.Tipo, $A.Regiao, $(if ($A.UrlDataverse) { 'com Dataverse' } else { 'sem Dataverse' }), $(if ($A.Gerenciado) { 'gerenciado' } else { 'não gerenciado' }))
    return "$($A.Nome) · $($partes -join ', ')"
}

# ---------------------------------------------------------------- idiomas e moedas
function Get-MacroRegiao([string]$Regiao) { if ($script:MACRO.ContainsKey($Regiao)) { return $script:MACRO[$Regiao] } return $null }

function Get-ListaRegiao {
    <#
    Idiomas ou moedas para criar o Dataverse. Tenta a regiao (como o roteiro) e depois a macro
    regiao: no tenant de demo so a macro regiao respondeu (InvalidMacroRegion para a regiao).
    #>
    param([ValidateSet('environmentLanguages', 'environmentCurrencies')][string]$Tipo, [string[]]$Locais)
    foreach ($l in ($Locais | Where-Object { $_ } | Select-Object -Unique)) {
        try {
            $r = Invoke-Admin -Url "$script:BAP/locations/$l/$Tipo`?api-version=2021-04-01"
            $nomes = @($r.value | ForEach-Object { [string]$_.name })
            if ($nomes.Count) { return , $nomes }
        } catch { Write-BizappLog "Lista de $(if ($Tipo -eq 'environmentLanguages') { 'idiomas' } else { 'moedas' }) por '$l' não veio: $($_.Exception.Message)" -Nivel discreto }
    }
    return , @()
}

# ---------------------------------------------------------------- criacao
function New-AmbienteProvisionado {
    <#
    Pede a criacao pela API de provisionamento e acompanha ate o ambiente ficar pronto (com o
    Dataverse, se pedido). Primeiro pede a regiao escolhida, como o roteiro; se o tenant exigir
    macro regiao (MacroRegionRequired), repete com a macro regiao e a Microsoft escolhe o
    datacenter. Devolve o ambiente lido no fim, com .ModoRegiao.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Corpo, [Parameter(Mandatory)][string]$Regiao, [string]$MacroRegiao,
        [switch]$ComDataverse, [int]$LimiteMinutos = 120, [string[]]$IdsAntes = @())
    $url = "$script:PPAPI/environmentmanagement/provisioning/environments?api-version=2024-10-01"
    $Corpo.location = $Regiao
    $modo = "região $Regiao"
    try {
        $r = Invoke-Admin -Metodo POST -Url $url -Corpo $Corpo -PowerPlatform -Resposta
    } catch {
        if ($_.Exception.Message -notmatch 'MacroRegion' -or -not $MacroRegiao) { throw }
        Write-BizappLog "O tenant não permite escolher a região exata (exige macro região). Criando na macro região ${MacroRegiao}: a Microsoft escolhe o datacenter dentro dela." -Nivel aviso
        $Corpo.Remove('location')
        $Corpo.macroRegion = $MacroRegiao
        $modo = "macro região $MacroRegiao"
        $r = Invoke-Admin -Metodo POST -Url $url -Corpo $Corpo -PowerPlatform -Resposta
    }
    $local = [string]($r.Headers['Location'] | Select-Object -First 1)
    Write-BizappLog "Pedido aceito (HTTP $([int]$r.StatusCode))." -Nivel discreto
    $id = if ($local -match '/environments/([0-9a-fA-F-]{36})/') { $Matches[1] } else { $null }

    $inicio = Get-Date
    $ultimoLog = $inicio
    while ($true) {
        Start-Sleep -Seconds 20
        $amb = $null
        if ($id) { try { $amb = Get-Ambiente $id } catch { $amb = $null } }
        else { $todos = Get-Ambientes; $amb = $todos | Where-Object { $_.Nome -eq $Corpo.displayName -and $_.EnvironmentId -notin $IdsAntes } | Select-Object -First 1 }
        $min = [int]((Get-Date) - $inicio).TotalMinutes
        $estado = if ($amb) { $amb.Estado } else { 'Na fila' }
        Write-BizappProgresso -Percentual ([math]::Min(95, 10 + $min * 6)) -Fase "Criando o ambiente ($estado)"
        if ($amb -and $amb.Estado -eq 'Succeeded' -and ($amb.UrlDataverse -or -not $ComDataverse)) {
            $amb | Add-Member -NotePropertyName ModoRegiao -NotePropertyValue $modo -Force
            return $amb
        }
        if ($amb -and $amb.Estado -match 'Failed') { throw "A criação do ambiente falhou no Power Platform (estado $($amb.Estado)). Veja o ambiente no admin center." }
        if (((Get-Date) - $ultimoLog).TotalMinutes -ge 3) { Write-BizappLog "Ainda criando: $min min, estado $estado." -Nivel discreto; $ultimoLog = Get-Date }
        if ($min -ge $LimiteMinutos) {
            throw "O ambiente ainda não ficou pronto em $LimiteMinutos min. Acompanhe no admin center (Gerenciar > Ambientes) e rode a consulta de novo."
        }
    }
}

function Set-AmbienteGerenciado {
    <# Liga o Managed Environment (protectionLevel Standard), como o Set-AdminPowerAppEnvironmentGovernanceConfiguration do roteiro. #>
    param([Parameter(Mandatory)][string]$Id)
    $corpo = @{ protectionLevel = 'Standard'; settings = @{ extendedSettings = @{} } }
    $null = Invoke-Admin -Metodo POST -Url "$script:BAP/environments/$Id/governanceConfiguration?api-version=2021-04-01" -Corpo $corpo -Resposta
    # A leitura demora alguns segundos para refletir (no teste, cerca de 40 s)
    for ($i = 1; $i -le 9; $i++) {
        Start-Sleep -Seconds 20
        $amb = Get-Ambiente $Id
        if ($amb.Gerenciado) { return $amb }
    }
    return $amb
}

# ---------------------------------------------------------------- evidencias
function Write-ContextoProvisionamento {
    param([string]$Pasta, [object]$Identidade, [string]$Acao, [System.Collections.IDictionary]$Extras = @{})
    $dados = [ordered]@{ DataHoraUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-10'; Acao = $Acao; TenantId = $Identidade.TenantId; Conta = $Identidade.Conta }
    foreach ($k in $Extras.Keys) { $dados[$k] = $Extras[$k] }
    Export-BizappEvidencia -Pasta $Pasta -Nome 'contexto.csv' -Dados ([pscustomobject]$dados)
}

function Write-ResumoProvisionamento {
    param([string]$Pasta, [string]$Acao, [object]$Identidade, [bool]$Aprovada, [bool]$Alterou, [string]$Detalhe, [System.Collections.IDictionary]$Extras = @{})
    $resumo = [ordered]@{
        DataHoraFimUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-10'; Controle = 'Provisionamento de ambientes DEV / HML / PROD'
        AcaoSolicitada = $Acao; TenantId = $Identidade.TenantId; Conta = $Identidade.Conta
    }
    foreach ($k in $Extras.Keys) { $resumo[$k] = $Extras[$k] }
    $resumo.AlteracaoExecutada = $Alterou
    $resumo.ValidacaoAprovada = $Aprovada
    $resumo.Resultado = $(if ($Aprovada) { 'Validado' } else { 'Falha' })
    $resumo.Detalhe = $Detalhe
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject]$resumo)
    ([pscustomobject]$resumo) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Pasta 'resumo.json') -Encoding utf8
    if (-not $Aprovada) { throw "A conferência depois da criação falhou: $Detalhe" }
}

Export-ModuleMember -Variable ITEM -Function Connect-Provisionamento, Invoke-Admin, Get-Ambientes, Get-Ambiente, Get-CapacidadeUsada, `
    Get-TextoAmbiente, Get-MacroRegiao, Get-ListaRegiao, New-AmbienteProvisionado, Set-AmbienteGerenciado, `
    Get-RegistroItem, Add-RegistroItem, Set-AmbientesDoItem, Get-TextoAmbientesDoItem, `
    Write-ContextoProvisionamento, Write-ResumoProvisionamento
