#Requires -Version 5.1
<#
.SYNOPSIS
    Teste manual do AUTO-10 (provisionamento de ambientes DEV / HML / PROD do Power Platform)
    no tenant de demo, seguindo o roteiro em Word do item
    (originais/10-provisionamento-ambientes-roteiro.docx; o cabecalho diz COE-IA-007).

.DESCRIPTION
    O item nao tem script pronto: o roteiro traz o script interativo para copiar e colar. Este
    teste roda os mesmos cmdlets do roteiro (Microsoft.PowerApps.Administration.PowerShell, no
    Windows PowerShell 5.1) para criar UM ambiente de teste (camada DEV, Sandbox) e conferir.

    Acrescimos ao roteiro (marcados com [+] na tela):
      - lista os ambientes que ja existem e a capacidade do tenant antes de criar;
      - macro regiao: neste tenant o New-AdminPowerAppEnvironment do roteiro e recusado com
        MacroRegionRequired. Como orienta a Microsoft, a criacao vai pela API de provisionamento
        (api.powerplatform.com, 2024-10-01) com macroRegion, usando o login do proprio modulo;
      - idiomas e moedas sao listados para a regiao escolhida (os cmdlets pedem a regiao);
      - confere que o retorno da criacao traz um Environment ID (GUID). O roteiro usa como
        alternativa a URL da instancia, que NAO e um Environment ID;
      - le o ambiente depois de criar (SKU, regiao, Dataverse, grupo, Managed Environment);
      - (opcional) remove o ambiente de TESTE no fim, so se voce digitar REMOVER. O roteiro
        proibe excluir como rollback em cliente; aqui e so limpeza do laboratorio.

    Ordem do teste:
      1. Modulo Microsoft.PowerApps.Administration.PowerShell
      2. Login e conferencia da conta
      3. Consultar: ambientes existentes, capacidade e regioes (somente leitura)
      4. Escolher regiao, idioma e moeda
      5. Resumo e criacao do ambiente de teste (digite CRIAR)
      6. (opcional) Managed Environment
      7. Validacao
      8. (opcional) Remover o ambiente de teste (digite REMOVER)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Teste-AUTO10.ps1
#>
param(
    [string]$TenantIdEsperado = '6a1a0a9c-5bbb-4060-8231-08f2ad74171e',
    [string]$ContaEsperada = 'admin@crm332072.onmicrosoft.com',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO10-Teste')
)

$ErrorActionPreference = 'Stop'
$NOME_TESTE = 'LAB-AUTO10-DEV'
$MODULO = 'Microsoft.PowerApps.Administration.PowerShell'

function Etapa([string]$Numero, [string]$Titulo) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host " ETAPA $Numero - $Titulo" -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
}

function Confirmar([string]$Pergunta) {
    return (Read-Host "$Pergunta (S/N)") -match '^[sS]'
}

$resultados = New-Object System.Collections.Generic.List[object]
function Registrar([string]$Parte, [string]$Acao, [bool]$Ok, [string]$Detalhe = '') {
    $script:resultados.Add([pscustomobject]@{ Parte = $Parte; Acao = $Acao; Sucesso = $Ok; Detalhe = $Detalhe })
    $cor = if ($Ok) { 'Green' } else { 'Red' }
    $txt = if ($Ok) { 'OK' } else { 'FALHOU' }
    $det = if ($Detalhe) { ": $Detalhe" } else { '' }
    Write-Host "  $txt - $Parte / $Acao$det" -ForegroundColor $cor
}

function Salvar([string]$Nome, [object[]]$Dados) {
    $arq = Join-Path $script:Evid $Nome
    if (@($Dados).Count) { @($Dados) | Export-Csv -Path $arq -NoTypeInformation -Encoding UTF8 }
    else { [pscustomobject]@{ Resultado = 'Sem registros' } | Export-Csv -Path $arq -NoTypeInformation -Encoding UTF8 }
}

function Resumir-Ambiente($Amb) {
    <# Campos que o checklist do roteiro manda conferir, lidos do objeto do cmdlet. #>
    $p = $Amb.Internal.properties
    [pscustomobject]@{
        DisplayName     = $Amb.DisplayName
        EnvironmentId   = $Amb.EnvironmentName
        Sku             = $p.environmentSku
        Regiao          = $Amb.Location
        Estado          = $p.provisioningState
        UrlDataverse    = $p.linkedEnvironmentMetadata.instanceUrl
        DominioDataverse = $p.linkedEnvironmentMetadata.domainName
        GrupoSeguranca  = $p.linkedEnvironmentMetadata.securityGroupId
        Managed         = $p.governanceConfiguration.protectionLevel
        Descricao       = $p.description
        CriadoEm        = $Amb.CreatedTime
    }
}

function Get-ListaDataverse([string]$Cmdlet, [string[]]$Locais) {
    <#
    [+] Idiomas ou moedas. Com a regiao (ex.: unitedstates) o servico responde "InvalidMacroRegion"
    neste tenant. O PAC CLI 2.15 (correcao da Microsoft para o mesmo erro) usa a API 2021-04-01 e
    as macro regioes (north-america, the-americas...). Tenta as combinacoes e diz qual funcionou.
    #>
    foreach ($local in $Locais) {
        foreach ($v in '2021-04-01', '2016-11-01') {
            $lista = @(& $Cmdlet -LocationName $local -ApiVersion $v -ErrorAction SilentlyContinue 2>$null)
            if ($lista.Count) {
                Write-Host "  (respondeu com $local e a API $v)" -ForegroundColor DarkGray
                Registrar 'Consulta' $Cmdlet $true "$local, API $v, $($lista.Count) itens"
                return $lista
            }
            Write-Host "  $local / API $($v): sem resultado" -ForegroundColor DarkGray
        }
    }
    Registrar 'Consulta' $Cmdlet $false "Nenhuma combinacao devolveu a lista ($($Locais -join ', '))"
    return @()
}

function Test-Guid([string]$Valor) {
    $g = [guid]::Empty
    return [guid]::TryParse($Valor, [ref]$g)
}

New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$script:Evid = Join-Path $PastaTrabalho "evidencias\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Force -Path $script:Evid | Out-Null
$LOG_TESTE = Join-Path $PastaTrabalho "teste-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -LiteralPath $LOG_TESTE -Force | Out-Null
$envId = $null

try {
    # ------------------------------------------------------------------
    Etapa 1 "Modulo $MODULO"
    Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Rode no Windows PowerShell 5.1 (powershell.exe), como pede o roteiro.' }
    if (-not (Get-Module -ListAvailable -Name $MODULO)) {
        Write-Host 'Falta o modulo. E instalado so para o seu usuario (Install-Module -Scope CurrentUser).' -ForegroundColor DarkGray
        if (-not (Confirmar 'Instalar agora?')) { throw 'Modulo nao instalado. Nada foi alterado.' }
        Install-Module -Name $MODULO -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    Import-Module $MODULO -WarningAction SilentlyContinue
    Write-Host "$MODULO $((Get-Module $MODULO).Version)" -ForegroundColor Green

    # ------------------------------------------------------------------
    Etapa 2 'Login'
    Write-Host "Tenant esperado: $TenantIdEsperado"
    Write-Host "Conta esperada:  $ContaEsperada"
    if (-not (Confirmar 'Estes sao os dados do tenant de DEMO?')) {
        $TenantIdEsperado = Read-Host 'Tenant ID do tenant de demo'
        $ContaEsperada = Read-Host 'Conta administradora (UPN)'
    }
    Write-Host "Vai abrir uma janela de login: entre com $ContaEsperada." -ForegroundColor Cyan
    Add-PowerAppsAccount -TenantID $TenantIdEsperado | Out-Null
    # O upn pode vir vazio no token; a conta do MSAL sempre tem o nome de login
    $conta = $global:currentSession.upn
    if (-not $conta -and $global:currentSession.msalAccount) { $conta = $global:currentSession.msalAccount.Username }
    $tenant = $global:currentSession.tenantId
    Write-Host "Conectado como $conta (tenant $tenant)."
    if ($conta -and $conta -ne $ContaEsperada) { throw "Login com outra conta ($conta). Nada foi alterado." }
    if ($tenant -and $tenant -ne $TenantIdEsperado) { throw "Login em outro tenant ($tenant). Nada foi alterado." }
    Registrar 'Login' 'Conectar' $true $conta

    # ------------------------------------------------------------------
    Etapa 3 'Consultar (somente leitura)'
    Write-Host '[+] Ambientes que ja existem:'
    $ambientes = @(Get-AdminPowerAppEnvironment | ForEach-Object { Resumir-Ambiente $_ })
    $ambientes | Select-Object DisplayName, Sku, Regiao, Managed, UrlDataverse | Format-Table -AutoSize | Out-Host
    Salvar 'ambientes-antes.csv' $ambientes
    Registrar 'Consulta' 'Ambientes' $true "$($ambientes.Count) ambientes"
    $jaExiste = @($ambientes | Where-Object { $_.DisplayName -eq $NOME_TESTE })
    if ($jaExiste.Count) { Write-Host "Ja existe um ambiente '$NOME_TESTE' (de um teste anterior)." -ForegroundColor Yellow }

    Write-Host '[+] Capacidade usada por ambiente (o Dataverse pede 1 GB livre de banco de dados para cada ambiente novo):'
    try {
        $cap = @(Get-AdminPowerAppEnvironment -Capacity | ForEach-Object {
                $amb = $_
                foreach ($c in @($amb.Internal.properties.capacity)) {
                    if ($c) { [pscustomobject]@{ Ambiente = $amb.DisplayName; Tipo = $c.capacityType; Usado = $c.actualConsumption; Unidade = $c.capacityUnit; AtualizadoEm = $c.updatedOn } }
                }
            })
        $cap | Format-Table -AutoSize | Out-Host
        Salvar 'capacidade-ambientes.csv' $cap
        Registrar 'Consulta' 'Capacidade usada' ($cap.Count -gt 0) "$($cap.Count) linhas"
    } catch {
        Registrar 'Consulta' 'Capacidade usada' $false $_.Exception.Message
    }
    Write-Host 'O total disponivel do tenant fica no admin center: Licencas > Capacidade (Dataverse). Confira antes de criar.' -ForegroundColor DarkGray

    Write-Host 'Regioes disponiveis:'
    $regioes = @(Get-AdminPowerAppEnvironmentLocations)
    $regioes | Select-Object LocationName, LocationDisplayName | Format-Table -AutoSize | Out-Host
    Salvar 'regioes.csv' $regioes
    Registrar 'Consulta' 'Regioes' ($regioes.Count -gt 0) "$($regioes.Count) regioes"

    # ------------------------------------------------------------------
    Etapa 4 'Regiao, macro regiao, idioma e moeda'
    # Padrao: a regiao do ambiente padrao do tenant
    $padraoRegiao = @($ambientes | Where-Object Sku -eq 'Default' | Select-Object -ExpandProperty Regiao)[0]
    if (-not $padraoRegiao) { $padraoRegiao = 'unitedstates' }
    $regiao = (Read-Host "LocationName da regiao (Enter = $padraoRegiao)").Trim()
    if (-not $regiao) { $regiao = $padraoRegiao }
    if (-not ($regioes | Where-Object LocationName -eq $regiao)) { throw "Regiao '$regiao' nao esta na lista." }

    # [+] Macro regiao: neste tenant a criacao exige (erro MacroRegionRequired). IDs conhecidos pelo
    # PAC CLI 2.15: asia-pacific, emea, eu-efta, europe-uk, north-america, the-americas.
    $mapa = @{ unitedstates = 'north-america'; canada = 'north-america'; southamerica = 'the-americas'; unitedkingdom = 'europe-uk'
        europe = 'emea'; france = 'emea'; germany = 'emea'; asia = 'asia-pacific'; australia = 'asia-pacific'; japan = 'asia-pacific'; india = 'asia-pacific'; korea = 'asia-pacific' }
    $padraoMacro = if ($mapa.ContainsKey($regiao)) { $mapa[$regiao] } else { '' }
    Write-Host 'Macro regioes conhecidas: north-america, the-americas, emea, europe-uk, eu-efta, asia-pacific' -ForegroundColor DarkGray
    $macro = (Read-Host "Macro regiao (Enter = $padraoMacro)").Trim()
    if (-not $macro) { $macro = $padraoMacro }
    if (-not $macro) { throw 'Informe a macro regiao.' }

    Write-Host "Idiomas suportados para Dataverse:"
    $idiomas = @(Get-ListaDataverse -Cmdlet 'Get-AdminPowerAppCdsDatabaseLanguages' -Locais @($macro, $regiao))
    $idiomas | Select-Object LanguageName, LanguageDisplayName, IsTenantDefault | Format-Table -AutoSize | Out-Host
    Salvar 'idiomas.csv' $idiomas
    Write-Host "Moedas suportadas para Dataverse:"
    $moedas = @(Get-ListaDataverse -Cmdlet 'Get-AdminPowerAppCdsDatabaseCurrencies' -Locais @($macro, $regiao))
    $moedas | Select-Object CurrencyName, CurrencyCode, CurrencySymbol, IsTenantDefault | Format-Table -AutoSize | Out-Host
    Salvar 'moedas.csv' $moedas

    $padraoIdioma = if ($idiomas | Where-Object LanguageName -eq '1046') { '1046' } else { '1033' }
    $idioma = (Read-Host "LanguageName (Enter = $padraoIdioma)").Trim()
    if (-not $idioma) { $idioma = $padraoIdioma }
    if ($idiomas.Count -and -not ($idiomas | Where-Object LanguageName -eq $idioma)) { throw "Idioma '$idioma' nao esta na lista." }
    $padraoMoeda = if ($moedas | Where-Object CurrencyName -eq 'BRL') { 'BRL' } else { 'USD' }
    $moeda = (Read-Host "CurrencyName (Enter = $padraoMoeda)").Trim()
    if (-not $moeda) { $moeda = $padraoMoeda }
    if ($moedas.Count -and -not ($moedas | Where-Object CurrencyName -eq $moeda)) { throw "Moeda '$moeda' nao esta na lista." }
    if (-not $idiomas.Count -or -not $moedas.Count) {
        Write-Host 'As listas nao vieram: o idioma e a moeda nao puderam ser conferidos antes de criar.' -ForegroundColor Yellow
        if (-not (Confirmar "Seguir com idioma $idioma e moeda $moeda mesmo assim?")) { throw 'Parado antes de criar. Nada foi criado.' }
    }

    # ------------------------------------------------------------------
    Etapa 5 'Resumo e criacao do ambiente de teste'
    $grupo = (Read-Host 'Object ID do Security Group (Enter = sem grupo)').Trim()
    if ($grupo -and -not (Test-Guid $grupo)) { throw "Object ID invalido: $grupo" }
    $managed = Confirmar 'O ambiente sera Managed Environment?'
    # [+] O New-AdminPowerAppEnvironment do roteiro foi recusado neste tenant com MacroRegionRequired.
    # A Microsoft orienta usar a API de provisionamento com macroRegion no corpo (o modulo antigo nao
    # tem esse parametro). Mesmos dados do roteiro, no formato da API.
    $corpo = [ordered]@{
        displayName               = $NOME_TESTE
        environmentSku            = 'Sandbox'
        description               = 'Teste do AUTO-10 (Readiness Deploy Accelerator). Pode ser removido.'
        macroRegion               = $macro
        databaseType              = 'CommonDataService'
        linkedEnvironmentMetadata = [ordered]@{ baseLanguageCode = [int]$idioma; currency = @{ code = $moeda } }
    }
    if ($grupo) { $corpo.linkedEnvironmentMetadata.securityGroupId = $grupo }
    Write-Host ''
    Write-Host '=== RESUMO ===' -ForegroundColor Cyan
    Write-Host "Camada: DEV"
    Write-Host "Nome: $NOME_TESTE"
    Write-Host "Localizacao: $regiao (macro regiao $macro)"
    Write-Host "SKU: Sandbox"
    Write-Host "Dataverse: SIM (idioma $idioma, moeda $moeda, dominio automatico)"
    Write-Host "Security Group: $(if ($grupo) { $grupo } else { '(nenhum)' })"
    Write-Host "Managed: $(if ($managed) { 'SIM' } else { 'NAO' })"
    ($corpo | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $script:Evid 'corpo-criacao.json') -Encoding UTF8

    $criar = $true
    if ($jaExiste.Count) {
        $criar = Confirmar "Ja existe '$NOME_TESTE'. Criar OUTRO mesmo assim? (N = usar o existente)"
        if (-not $criar) { $envId = $jaExiste[0].EnvironmentId }
    }
    if ($criar) {
        if ((Read-Host 'Confirma a criacao? Digite CRIAR') -cne 'CRIAR') { throw 'Provisionamento cancelado. Nada foi criado.' }
        Write-Host 'Pedindo a criacao...' -ForegroundColor Cyan
        $inicio = Get-Date
        $antesIds = @($ambientes.EnvironmentId)
        $resp = InvokeApiNoParseContent -Method POST -Route 'https://{powerPlatformEndpoint}/environmentmanagement/provisioning/environments?api-version={apiVersion}' -Body $corpo -ApiVersion '2024-10-01'
        # Em sucesso vem a resposta HTTP (StatusCode); em erro o modulo devolve Code/Error/Description
        $codigo = if ($resp.StatusCode) { [int]$resp.StatusCode } else { [int]$resp.Code }
        $texto = try { if ($resp.Content) { [string]$resp.Content } else { ($resp.Error | ConvertTo-Json -Depth 6 -Compress) } } catch { '' }
        @("StatusCode: $codigo", "Location: $($resp.Headers['Location'])", "Operation-Location: $($resp.Headers['Operation-Location'])", '', $texto) |
            Set-Content -Path (Join-Path $script:Evid 'retorno-criacao.txt') -Encoding UTF8
        Write-Host "Resposta: HTTP $codigo"
        if ($codigo -notin 200, 201, 202) { throw "A criacao foi recusada (HTTP $codigo): $texto $($resp.Error.message)" }

        # Acompanha pela lista de ambientes (o mesmo que o admin center mostra)
        Write-Host 'Criando (costuma levar de 5 a 20 minutos). Conferindo a cada 30 s...' -ForegroundColor Cyan
        $novo = $null
        while (((Get-Date) - $inicio).TotalMinutes -lt 90) {
            Start-Sleep -Seconds 30
            $novo = @(Get-AdminPowerAppEnvironment | Where-Object { $_.DisplayName -eq $NOME_TESTE -and $_.EnvironmentName -notin $antesIds })[0]
            $estado = if ($novo) { $novo.Internal.properties.provisioningState } else { 'ainda nao aparece' }
            $dv = if ($novo) { $novo.Internal.properties.linkedEnvironmentMetadata.instanceUrl } else { '' }
            Write-Host "  $([int]((Get-Date) - $inicio).TotalMinutes) min: $estado $dv" -ForegroundColor DarkGray
            if ($novo -and $estado -eq 'Succeeded' -and $dv) { break }
            if ($estado -match 'Failed') { break }
        }
        $minutos = [int]((Get-Date) - $inicio).TotalMinutes
        if (-not $novo) { throw "O ambiente nao apareceu em $minutos min. Confira no admin center." }
        $envId = $novo.EnvironmentName
        Write-Host "EnvironmentName: $envId"
        Registrar 'Criacao' 'API de provisionamento (macroRegion)' ((Test-Guid $envId) -and $novo.Internal.properties.provisioningState -eq 'Succeeded') "$minutos min; estado $($novo.Internal.properties.provisioningState)"
        if (-not (Test-Guid $envId)) { throw 'Nao foi possivel identificar o Environment ID (GUID).' }
    }

    # ------------------------------------------------------------------
    Etapa 6 'Managed Environment'
    if ($managed) {
        Write-Host "Environment ID: $envId"
        $GovernanceConfiguration = [pscustomobject]@{
            protectionLevel = 'Standard'
            settings        = [pscustomobject]@{ extendedSettings = @{} }
        }
        try {
            $r = Set-AdminPowerAppEnvironmentGovernanceConfiguration -EnvironmentName $envId -UpdatedGovernanceConfiguration $GovernanceConfiguration
            $r | Format-List * | Out-String | Set-Content -Path (Join-Path $script:Evid 'retorno-managed.txt') -Encoding UTF8
            Registrar 'Managed' 'Set-AdminPowerAppEnvironmentGovernanceConfiguration' $true "Code $($r.Code)"
        } catch { Registrar 'Managed' 'Set-AdminPowerAppEnvironmentGovernanceConfiguration' $false $_.Exception.Message }
    } else { Write-Host 'Pulado (resposta NAO).' -ForegroundColor DarkGray }

    # ------------------------------------------------------------------
    Etapa 7 'Validacao'
    $lido = $null
    for ($i = 1; $i -le 6; $i++) {
        $lido = Resumir-Ambiente (Get-AdminPowerAppEnvironment -EnvironmentName $envId)
        if (-not $managed -or $lido.Managed -eq 'Standard') { break }
        Write-Host "Managed ainda nao aparece (leitura $i de 6). Aguardando 20 s..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 20
    }
    $lido | Format-List | Out-Host
    Salvar 'ambiente-depois.csv' @($lido)
    Registrar 'Validacao' 'Nome e ID' ($lido.DisplayName -eq $NOME_TESTE -and $lido.EnvironmentId -eq $envId) "$($lido.DisplayName) / $($lido.EnvironmentId)"
    Registrar 'Validacao' 'Regiao e SKU' ($lido.Regiao -eq $regiao -and $lido.Sku -eq 'Sandbox') "$($lido.Regiao) / $($lido.Sku)"
    Registrar 'Validacao' 'Dataverse' ([bool]$lido.UrlDataverse) $lido.UrlDataverse
    if ($grupo) { Registrar 'Validacao' 'Security Group' ($lido.GrupoSeguranca -eq $grupo) $lido.GrupoSeguranca }
    Registrar 'Validacao' 'Managed Environment' ((-not $managed -and $lido.Managed -ne 'Standard') -or ($managed -and $lido.Managed -eq 'Standard')) "protectionLevel: $($lido.Managed)"
    Write-Host 'Confira tambem no admin center (Gerenciar > Ambientes) e abra o ambiente para criar uma solucao de teste, se quiser.' -ForegroundColor DarkGray

    # ------------------------------------------------------------------
    Etapa 8 'Remover o ambiente de teste (opcional)'
    Write-Host 'Em cliente o roteiro proibe excluir ambiente como rollback. Aqui e so a limpeza do laboratorio.' -ForegroundColor DarkGray
    $resp = Read-Host "Para REMOVER o ambiente '$NOME_TESTE' ($envId), digite REMOVER (Enter = manter)"
    if ($resp -ceq 'REMOVER') {
        try {
            $r = Remove-AdminPowerAppEnvironment -EnvironmentName $envId
            $r | Format-List * | Out-String | Set-Content -Path (Join-Path $script:Evid 'retorno-remocao.txt') -Encoding UTF8
            Start-Sleep -Seconds 15
            $resto = Get-AdminPowerAppEnvironment -EnvironmentName $envId -ErrorAction SilentlyContinue
            $estado = if ($resto -and $resto.EnvironmentName) { $resto.Internal.properties.provisioningState } else { 'nao encontrado' }
            Registrar 'Limpeza' 'Remove-AdminPowerAppEnvironment' ($r.Code -in 200, 202, 204 -or $estado -ne 'Succeeded') "Code $($r.Code); estado depois: $estado (ambientes removidos ficam 7 dias na lista de recuperacao)"
        } catch { Registrar 'Limpeza' 'Remove-AdminPowerAppEnvironment' $false $_.Exception.Message }
    } else { Write-Host "Mantido: $NOME_TESTE ($envId)." }
} catch {
    Write-Host ''
    Write-Host "PAROU: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Onde: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
} finally {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host ' RESUMO' -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    if ($resultados.Count) {
        $resultados | Format-Table -AutoSize -Wrap | Out-Host
        $resultados | Export-Csv -Path (Join-Path $script:Evid 'resumo.csv') -NoTypeInformation -Encoding UTF8
    } else { Write-Host 'Nada foi executado.' }
    if ($envId) { Write-Host "Environment ID: $envId" }
    Write-Host "Evidencias: $script:Evid" -ForegroundColor DarkGray
    Write-Host "Log completo do teste: $LOG_TESTE" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
}
