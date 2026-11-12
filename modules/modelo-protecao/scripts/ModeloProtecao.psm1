# Funcoes do AUTO-20 (DLP da Power Platform, Acesso Condicional, DLP do Microsoft Purview e rotulo
# de sensibilidade como modelo), trazidas do script validado no laboratorio
# (testes-manuais/originais/20-dlp-ca-rotulos.ps1, teste de 12/11/2026).
# Diferencas:
#   - roda no PowerShell 7 (o original exige o Windows PowerShell 5.1 por causa do modulo da Power
#     Platform). A DLP da Power Platform vai direto pela mesma API que o modulo usa
#     (api.bap.microsoft.com/providers/PowerPlatform.Governance/v1/policies, api-version 2016-11-01),
#     com o login do instalador. O Acesso Condicional vai pela API do Graph, tambem com o login do
#     instalador; o Purview, por Connect-IPPSSession -AccessToken. Assim nao ha o conflito entre o
#     Graph 2.39 e o Exchange 3.11 visto no teste;
#   - no lugar do prefixo fixo LAB-AUTO20, os nomes usam um prefixo escolhido na tela. Os objetos do
#     Purview levam a marca "Criada pelo Readiness Deploy Accelerator" no comentario;
#   - listas vazias sao aceitas (no original, Get-Auto20State parava com lista vazia);
#   - habilitar com o rotulo ja publicado conta como sucesso (no teste, o original marcou falha
#     com "already published"); se a politica de rotulos sumir (no teste, sumiu depois de ficar
#     sem rotulos), habilitar cria de novo;
#   - sem licenca Microsoft Entra ID P1/P2, o Acesso Condicional fica "Bloqueado" em vez de falhar.

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'Modelo-Protecao'
$script:VERSAO_MINIMA_EXO = [version]'3.8.0'
$script:MARCA = 'Criada pelo Readiness Deploy Accelerator'
$script:ESCOPOS_GRAPH = @('Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'User.Read.All', 'Organization.Read.All', 'RoleManagement.Read.Directory')
$script:URL_DLP_PP = 'https://api.bap.microsoft.com/providers/PowerPlatform.Governance/v1/policies'
$script:API_DLP_PP = '2016-11-01'

# ---------------------------------------------------------------- utilitarios

function Get-SafeProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-TextEquals {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected)
    return [string]::Equals([string]$Actual, [string]$Expected, [StringComparison]::OrdinalIgnoreCase)
}

function Find-ByName {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][string]$ExpectedName, [string[]]$Properties = @('Name', 'DisplayName'))
    foreach ($i in @($Items)) {
        foreach ($p in $Properties) { if (Test-TextEquals (Get-SafeProperty $i $p) $ExpectedName) { return $i } }
    }
    return $null
}

function Invoke-Api {
    <# Chamada REST com token; segue @odata.nextLink nas listas (GET com -Lista). #>
    param(
        [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Url,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Metodo = 'GET', [object]$Corpo, [switch]$Lista
    )
    $cab = @{ Authorization = "Bearer $Token" }
    if ($Lista) {
        $itens = [System.Collections.Generic.List[object]]::new()
        $proxima = $Url
        while ($proxima) {
            $r = Invoke-RestMethod -Method GET -Uri $proxima -Headers $cab -ErrorAction Stop
            foreach ($v in @($r.value)) { if ($null -ne $v) { $itens.Add($v) } }
            $proxima = [string](Get-SafeProperty $r '@odata.nextLink')
        }
        return , $itens.ToArray()
    }
    $p = @{ Method = $Metodo; Uri = $Url; Headers = $cab; ErrorAction = 'Stop' }
    if ($null -ne $Corpo) { $p.Body = ($Corpo | ConvertTo-Json -Depth 20); $p.ContentType = 'application/json' }
    return Invoke-RestMethod @p
}

function Get-MensagemErro {
    <# Mensagem util de um erro REST (corpo JSON da resposta, quando houver). #>
    param([Parameter(Mandatory)][object]$Erro)
    $texto = [string]$Erro.ErrorDetails.Message
    if ($texto) {
        try {
            $j = $texto | ConvertFrom-Json -ErrorAction Stop
            $m = Get-SafeProperty (Get-SafeProperty $j 'error') 'message'
            if ($m) { return [string]$m }
        } catch { }
        return $texto
    }
    return [string]$Erro.Exception.Message
}

function Get-NomesModelo {
    param([Parameter(Mandatory)][string]$Prefixo)
    if ($Prefixo -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{1,30}$') {
        throw 'Prefixo inválido: use de 2 a 31 letras sem acento, números ou hífen, começando por letra ou número.'
    }
    return [ordered]@{
        DlpPowerPlatform = "$Prefixo-DLP-Agentes"
        AcessoCondicional = "$Prefixo-CA-MFA-Admin"
        DlpPurview = "$Prefixo-DLP-Copilot"
        Rotulo = "$Prefixo-Confidencial"
        PoliticaRotulos = "$Prefixo-Politica-Rotulos"
    }
}

# ---------------------------------------------------------------- conexao e contexto

function Import-ExchangeModulo {
    $m = Get-Module -ListAvailable -Name ExchangeOnlineManagement | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $m) { throw 'O módulo ExchangeOnlineManagement não está instalado. Instale-o pela tela de pré-requisitos.' }
    if ($m.Version -lt $script:VERSAO_MINIMA_EXO) {
        throw "O módulo ExchangeOnlineManagement está na versão $($m.Version); é preciso $($script:VERSAO_MINIMA_EXO) ou superior."
    }
    Import-Module -Name $m.Path -Force -Global -ErrorAction Stop -WarningAction SilentlyContinue 3>$null | Out-Null
    return $m
}

function Connect-ModeloProtecao {
    <#
    Confere conta, funcoes e licencas (Graph, token do instalador), confere o login da Power Platform
    e tenta conectar o Purview. Sem Purview, os componentes dele ficam "Bloqueado" (como no original)
    e o resto continua.
    #>
    param([Parameter(Mandatory)][hashtable]$Entrada)

    $tokenGraph = Get-BizappToken -Entrada $Entrada -Nome Graph
    $id = Assert-BizappContexto -Token $tokenGraph -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta
    $faltando = @($script:ESCOPOS_GRAPH | Where-Object { $_ -notin $id.Escopos })
    if ($faltando) { throw "O login não tem as permissões necessárias: $($faltando -join ', ')." }
    $tokenPp = Get-BizappToken -Entrada $Entrada -Nome PowerPlatform
    $null = Assert-BizappContexto -Token $tokenPp -TenantEsperado $id.TenantId -ContaEsperada $id.Conta

    $usuario = Invoke-Api -Token $tokenGraph -Url "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($id.Conta))?`$select=id,displayName,userPrincipalName,accountEnabled"
    if ($usuario.accountEnabled -ne $true) { throw "A conta $($id.Conta) está desabilitada." }

    $atribuicoes = Invoke-Api -Token $tokenGraph -Lista -Url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20%27$($usuario.id)%27"
    $definicoes = @{}
    foreach ($d in (Invoke-Api -Token $tokenGraph -Lista -Url 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?$select=id,displayName')) { $definicoes[[string]$d.id] = $d }
    $funcoes = @(foreach ($a in $atribuicoes) {
            $d = $definicoes[[string]$a.roleDefinitionId]
            [pscustomobject]@{ Conta = $id.Conta; PrincipalId = $usuario.id; Funcao = $(if ($d) { $d.displayName } else { 'Definição não localizada' })
                RoleDefinitionId = $a.roleDefinitionId; RoleAssignmentId = $a.id; DirectoryScopeId = $a.directoryScopeId }
        })

    $skus = Invoke-Api -Token $tokenGraph -Lista -Url 'https://graph.microsoft.com/v1.0/subscribedSkus'
    $licencas = @(foreach ($s in $skus) {
            [pscustomobject]@{ SkuPartNumber = $s.skuPartNumber; SkuId = $s.skuId; Capacidade = $s.capabilityStatus
                UnidadesAtivas = $(if ($s.prepaidUnits) { $s.prepaidUnits.enabled } else { 0 }); UnidadesUsadas = $s.consumedUnits
                Planos = (@($s.servicePlans.servicePlanName) -join '; ') }
        })
    $temP1 = @($skus | Where-Object { $_.capabilityStatus -eq 'Enabled' -and @($_.servicePlans.servicePlanName) -match '^AAD_PREMIUM' }).Count -gt 0

    # Purview: falha aqui nao interrompe (componentes ficam "Bloqueado")
    $purview = $false; $motivo = ''; $conexao = $null; $versaoExo = ''
    try {
        $m = Import-ExchangeModulo
        $versaoExo = [string]$m.Version
        $tokenScc = Get-BizappToken -Entrada $Entrada -Nome Purview
        $tokenExo = Get-BizappToken -Entrada $Entrada -Nome Exchange
        Write-BizappLog 'Conectando ao Microsoft Purview...'
        try {
            Connect-IPPSSession -AccessToken $tokenScc -UserPrincipalName $id.Conta -ShowBanner:$false -ErrorAction Stop 3>$null | Out-Null
        } catch {
            Write-BizappLog "Nova tentativa com o login do Exchange Online ($($_.Exception.Message))." -Nivel discreto
            Connect-IPPSSession -AccessToken $tokenExo -UserPrincipalName $id.Conta -ShowBanner:$false -ErrorAction Stop 3>$null | Out-Null
        }
        $conexao = @(Get-ConnectionInformation) | Where-Object { $_.State -eq 'Connected' -and $_.IsEopSession -eq $true } | Select-Object -Last 1
        if (-not $conexao) { throw 'Nenhuma sessão do Security & Compliance foi identificada.' }
        if (-not (Test-TextEquals $conexao.TenantID $id.TenantId)) { throw "Sessão do Purview em outro tenant ($($conexao.TenantID))." }
        if ($conexao.UserPrincipalName -and -not (Test-TextEquals $conexao.UserPrincipalName $id.Conta)) { throw "Sessão do Purview com outra conta ($($conexao.UserPrincipalName))." }
        $comandos = 'Get-DlpCompliancePolicy', 'New-DlpCompliancePolicy', 'Set-DlpCompliancePolicy', 'Remove-DlpCompliancePolicy',
        'Get-Label', 'New-Label', 'Remove-Label', 'Get-LabelPolicy', 'New-LabelPolicy', 'Set-LabelPolicy', 'Remove-LabelPolicy'
        $sem = @($comandos | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
        if ($sem) { throw "Comandos do Purview indisponíveis para a conta: $($sem -join ', ')." }
        $purview = $true
        Write-BizappLog 'Microsoft Purview conectado.' -Nivel sucesso
    } catch {
        $motivo = "Microsoft Purview não disponível (acesso, permissão ou licença). Detalhe: $($_.Exception.Message)"
        Write-BizappLog $motivo -Nivel aviso
    }

    return [pscustomobject]@{
        Identidade = $id; UsuarioId = [string]$usuario.id; Funcoes = $funcoes; Licencas = $licencas; TemP1 = $temP1
        TokenGraph = $tokenGraph; TokenPp = $tokenPp
        Purview = $purview; PurviewMotivo = $motivo; PurviewConexao = $conexao; VersaoExo = $versaoExo
    }
}

function Disconnect-ModeloProtecao {
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue 3>$null | Out-Null } catch { }
}

# ---------------------------------------------------------------- leitura do estado

function Read-EstadoModelo {
    <# Le os 5 tipos de objeto e localiza os do modelo (equivale a Read-AllAuto20Configuration). #>
    param([Parameter(Mandatory)][object]$Ctx, [Parameter(Mandatory)][System.Collections.IDictionary]$Nomes)
    $resp = Invoke-Api -Token $Ctx.TokenPp -Url "$($script:URL_DLP_PP)?`$top=50&api-version=$($script:API_DLP_PP)"
    $pp = @(@(Get-SafeProperty $resp 'value') | Where-Object { $null -ne $_ })
    $ca = @(Invoke-Api -Token $Ctx.TokenGraph -Lista -Url 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies')
    $dlp = @(); $rotulos = @(); $politicas = @()
    if ($Ctx.Purview) {
        $dlp = @(Get-DlpCompliancePolicy -ErrorAction Stop)
        $rotulos = @(Get-Label -ErrorAction Stop)
        $politicas = @(Get-LabelPolicy -ErrorAction Stop)
    }
    return [ordered]@{
        PowerPlatformPolicies = $pp; ConditionalAccessPolicies = $ca; PurviewDlpPolicies = $dlp; Labels = $rotulos; LabelPolicies = $politicas
        Model = [ordered]@{
            PowerPlatformDlp = Find-ByName -Items $pp -ExpectedName $Nomes.DlpPowerPlatform -Properties @('displayName', 'DisplayName', 'name')
            ConditionalAccess = Find-ByName -Items $ca -ExpectedName $Nomes.AcessoCondicional -Properties @('displayName')
            PurviewDlp = Find-ByName -Items $dlp -ExpectedName $Nomes.DlpPurview -Properties @('Name', 'DisplayName')
            SensitivityLabel = Find-ByName -Items $rotulos -ExpectedName $Nomes.Rotulo -Properties @('Name', 'DisplayName')
            LabelPolicy = Find-ByName -Items $politicas -ExpectedName $Nomes.PoliticaRotulos -Properties @('Name')
        }
    }
}

function Get-TextosEstado {
    <# Situacao de cada componente para a tela. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Estado, [Parameter(Mandatory)][object]$Ctx)
    $m = $Estado.Model
    $semPurview = 'Indisponível (Microsoft Purview não conectado)'
    $ca = if (-not $m.ConditionalAccess) { 'Não existe' } else {
        switch ([string]$m.ConditionalAccess.state) {
            'enabled' { 'Ligada (exige MFA da conta admin)' }
            'disabled' { 'Desligada' }
            'enabledForReportingButNotEnforced' { 'Modo de relatório (não exige MFA)' }
            default { [string]$m.ConditionalAccess.state }
        }
    }
    $dlp = if (-not $Ctx.Purview) { $semPurview } elseif (-not $m.PurviewDlp) { 'Não existe' } else {
        switch ([string]$m.PurviewDlp.Mode) {
            'Enable' { 'Ligada' }
            'Disable' { 'Desligada' }
            'TestWithoutNotifications' { 'Em teste (sem notificações)' }
            'TestWithNotifications' { 'Em teste (com notificações)' }
            default { [string]$m.PurviewDlp.Mode }
        }
    }
    $rotulo = if (-not $Ctx.Purview) { $semPurview } elseif (-not $m.SensitivityLabel) { 'Não existe' } else {
        $publicado = $m.LabelPolicy -and (@($m.LabelPolicy.Labels) | Where-Object { [string]$_ -match [regex]::Escape([string]$m.SensitivityLabel.Name) -or [string]$_ -match [regex]::Escape([string]$m.SensitivityLabel.Guid) })
        if ($publicado) { 'Criado e publicado para a conta admin' } else { 'Criado, não publicado' }
    }
    return [ordered]@{
        EstadoDlpPowerPlatform = $(if ($m.PowerPlatformDlp) { 'Existe (todos os ambientes)' } else { 'Não existe' })
        EstadoAcessoCondicional = $ca
        EstadoDlpPurview = $dlp
        EstadoRotulo = $rotulo
    }
}

function Write-EstadoSaidas {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Estado, [Parameter(Mandatory)][object]$Ctx)
    $t = Get-TextosEstado -Estado $Estado -Ctx $Ctx
    # Nomes escritos por extenso: o validador dos manifestos procura as saidas assim
    Set-BizappSaida -Nome 'EstadoDlpPowerPlatform' -Valor $t.EstadoDlpPowerPlatform
    Set-BizappSaida -Nome 'EstadoAcessoCondicional' -Valor $t.EstadoAcessoCondicional
    Set-BizappSaida -Nome 'EstadoDlpPurview' -Valor $t.EstadoDlpPurview
    Set-BizappSaida -Nome 'EstadoRotulo' -Valor $t.EstadoRotulo
    return $t
}

function Get-ObjetoDoItem {
    <# Objetos do Purview so sao alterados se tiverem a marca no comentario. #>
    param([AllowNull()][object]$Objeto)
    if ($null -eq $Objeto) { return $false }
    return ([string](Get-SafeProperty $Objeto 'Comment')) -like "*$($script:MARCA)*"
}

# ---------------------------------------------------------------- acoes por componente

function Add-Acao {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Lista, [string]$Componente, [string]$Operacao,
        [ValidateSet('Sucesso', 'Falha', 'Bloqueado', 'Ignorado', 'Não aplicável')][string]$Status, [string]$Detalhe = '')
    $Lista.Add([pscustomobject]@{ DataHora = Get-Date; Componente = $Componente; Operacao = $Operacao; Status = $Status; Detalhe = $Detalhe })
    $nivel = switch ($Status) { 'Sucesso' { 'sucesso' } 'Falha' { 'erro' } 'Bloqueado' { 'aviso' } default { 'info' } }
    Write-BizappLog "${Componente} · ${Operacao}: ${Status}$(if ($Detalhe) { " — $Detalhe" })" -Nivel $nivel
}

function New-ModeloProtecao {
    <# CriarModelo: cria o que falta, cada componente independente (como o original). #>
    param([object]$Ctx, [System.Collections.IDictionary]$Nomes, [System.Collections.IDictionary]$Estado, [System.Collections.Generic.List[object]]$Acoes, [string]$Justificativa)
    $m = $Estado.Model
    $comentario = "$($script:MARCA). $Justificativa"

    if ($m.PowerPlatformDlp) { Add-Acao $Acoes 'DLP da Power Platform' 'Criar' 'Ignorado' 'Já existe.' }
    else {
        try {
            $corpo = [ordered]@{ displayName = $Nomes.DlpPowerPlatform; defaultConnectorsClassification = 'General'; connectorGroups = @()
                environmentType = 'AllEnvironments'; environments = @(); etag = $null }
            $null = Invoke-Api -Token $Ctx.TokenPp -Metodo POST -Url "$($script:URL_DLP_PP)?api-version=$($script:API_DLP_PP)" -Corpo $corpo
            Add-Acao $Acoes 'DLP da Power Platform' 'Criar' 'Sucesso' 'Todos os ambientes; conectores no grupo padrão (não bloqueia nada).'
        } catch { Add-Acao $Acoes 'DLP da Power Platform' 'Criar' 'Falha' (Get-MensagemErro $_) }
    }

    if ($m.ConditionalAccess) { Add-Acao $Acoes 'Acesso Condicional' 'Criar' 'Ignorado' 'Já existe.' }
    elseif (-not $Ctx.TemP1) { Add-Acao $Acoes 'Acesso Condicional' 'Criar' 'Bloqueado' 'O tenant não tem licença Microsoft Entra ID P1 ou P2.' }
    else {
        try {
            $corpo = @{
                displayName = $Nomes.AcessoCondicional; state = 'enabledForReportingButNotEnforced'
                conditions = @{ users = @{ includeUsers = @($Ctx.UsuarioId) }; applications = @{ includeApplications = @('All') }; clientAppTypes = @('all') }
                grantControls = @{ operator = 'OR'; builtInControls = @('mfa') }
            }
            $null = Invoke-Api -Token $Ctx.TokenGraph -Metodo POST -Url 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies' -Corpo $corpo
            Add-Acao $Acoes 'Acesso Condicional' 'Criar em modo de relatório' 'Sucesso' "Só para a conta $($Ctx.Identidade.Conta)."
        } catch { Add-Acao $Acoes 'Acesso Condicional' 'Criar em modo de relatório' 'Falha' (Get-MensagemErro $_) }
    }

    if (-not $Ctx.Purview) {
        foreach ($c in 'DLP do Microsoft Purview', 'Rótulo de sensibilidade', 'Política de rótulos') { Add-Acao $Acoes $c 'Criar' 'Bloqueado' $Ctx.PurviewMotivo }
        return
    }
    if ($m.PurviewDlp) { Add-Acao $Acoes 'DLP do Microsoft Purview' 'Criar' 'Ignorado' 'Já existe.' }
    else {
        try {
            New-DlpCompliancePolicy -Name $Nomes.DlpPurview -Comment $comentario -ExchangeLocation All -Mode TestWithoutNotifications -ErrorAction Stop 3>$null | Out-Null
            Add-Acao $Acoes 'DLP do Microsoft Purview' 'Criar em teste' 'Sucesso' 'Exchange, sem regras, em teste sem notificações.'
        } catch { Add-Acao $Acoes 'DLP do Microsoft Purview' 'Criar em teste' 'Falha' $_.Exception.Message }
    }
    if ($m.SensitivityLabel) { Add-Acao $Acoes 'Rótulo de sensibilidade' 'Criar' 'Ignorado' 'Já existe.' }
    else {
        try {
            New-Label -Name $Nomes.Rotulo -DisplayName "$($Nomes.Rotulo -replace '-Confidencial$', '') - Confidencial" -Tooltip 'Uso interno: conteúdo confidencial da organização' `
                -Comment $comentario -ErrorAction Stop 3>$null | Out-Null
            Add-Acao $Acoes 'Rótulo de sensibilidade' 'Criar' 'Sucesso' 'Rótulo sem criptografia.'
        } catch { Add-Acao $Acoes 'Rótulo de sensibilidade' 'Criar' 'Falha' $_.Exception.Message }
    }
    $rotulo = Find-ByName -Items @(Get-Label -ErrorAction Stop) -ExpectedName $Nomes.Rotulo
    $politica = Find-ByName -Items @(Get-LabelPolicy -ErrorAction Stop) -ExpectedName $Nomes.PoliticaRotulos -Properties @('Name')
    if ($politica) { Add-Acao $Acoes 'Política de rótulos' 'Criar' 'Ignorado' 'Já existe.' }
    elseif (-not $rotulo) { Add-Acao $Acoes 'Política de rótulos' 'Criar' 'Falha' 'O rótulo não ficou disponível.' }
    else {
        try {
            New-LabelPolicy -Name $Nomes.PoliticaRotulos -Labels $rotulo.Name -ExchangeLocation $Ctx.Identidade.Conta -Comment $comentario -ErrorAction Stop 3>$null | Out-Null
            Add-Acao $Acoes 'Política de rótulos' 'Criar e publicar' 'Sucesso' "Publicado só para a conta $($Ctx.Identidade.Conta)."
        } catch { Add-Acao $Acoes 'Política de rótulos' 'Criar e publicar' 'Falha' $_.Exception.Message }
    }
}

function Set-EstadoModelo {
    <# HabilitarModelo / DesabilitarModelo. #>
    param([object]$Ctx, [System.Collections.IDictionary]$Nomes, [System.Collections.IDictionary]$Estado, [System.Collections.Generic.List[object]]$Acoes,
        [bool]$Ligar, [string]$Justificativa)
    $m = $Estado.Model
    $op = if ($Ligar) { 'Ligar' } else { 'Desligar' }

    if ($m.ConditionalAccess) {
        $alvo = if ($Ligar) { 'enabled' } else { 'disabled' }
        try {
            $null = Invoke-Api -Token $Ctx.TokenGraph -Metodo PATCH -Url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$($m.ConditionalAccess.id)" -Corpo @{ state = $alvo }
            Add-Acao $Acoes 'Acesso Condicional' $op 'Sucesso' "Estado: $alvo."
        } catch { Add-Acao $Acoes 'Acesso Condicional' $op 'Falha' (Get-MensagemErro $_) }
    } else { Add-Acao $Acoes 'Acesso Condicional' $op 'Ignorado' 'Crie o modelo antes.' }

    if (-not $Ctx.Purview) {
        foreach ($c in 'DLP do Microsoft Purview', 'Política de rótulos') { Add-Acao $Acoes $c $op 'Bloqueado' $Ctx.PurviewMotivo }
    } else {
        if (-not $m.PurviewDlp) { Add-Acao $Acoes 'DLP do Microsoft Purview' $op 'Ignorado' 'Crie o modelo antes.' }
        elseif (-not (Get-ObjetoDoItem $m.PurviewDlp)) { Add-Acao $Acoes 'DLP do Microsoft Purview' $op 'Bloqueado' 'A política com este nome não foi criada por este item; não foi alterada.' }
        else {
            $modo = if ($Ligar) { 'Enable' } else { 'Disable' }
            try {
                Set-DlpCompliancePolicy -Identity $m.PurviewDlp.Name -Mode $modo -Comment "$($script:MARCA). $Justificativa" -ErrorAction Stop 3>$null | Out-Null
                Add-Acao $Acoes 'DLP do Microsoft Purview' $op 'Sucesso' "Modo: $modo."
            } catch { Add-Acao $Acoes 'DLP do Microsoft Purview' $op 'Falha' $_.Exception.Message }
        }

        if (-not $m.SensitivityLabel) { Add-Acao $Acoes 'Política de rótulos' $op 'Ignorado' 'Rótulo não localizado; crie o modelo antes.' }
        elseif ($Ligar) {
            try {
                if (-not $m.LabelPolicy) {
                    # No teste, a politica sumiu depois de ficar sem rotulos: cria de novo
                    New-LabelPolicy -Name $Nomes.PoliticaRotulos -Labels $m.SensitivityLabel.Name -ExchangeLocation $Ctx.Identidade.Conta `
                        -Comment "$($script:MARCA). $Justificativa" -ErrorAction Stop 3>$null | Out-Null
                    Add-Acao $Acoes 'Política de rótulos' $op 'Sucesso' 'Política recriada e rótulo publicado.'
                } else {
                    Set-LabelPolicy -Identity $m.LabelPolicy.Name -AddLabels $m.SensitivityLabel.Name -ErrorAction Stop 3>$null | Out-Null
                    Add-Acao $Acoes 'Política de rótulos' $op 'Sucesso' 'Rótulo publicado.'
                }
            } catch {
                if ($_.Exception.Message -match 'already published|LabelAlreadyPublished') { Add-Acao $Acoes 'Política de rótulos' $op 'Sucesso' 'O rótulo já estava publicado.' }
                else { Add-Acao $Acoes 'Política de rótulos' $op 'Falha' $_.Exception.Message }
            }
        } elseif (-not $m.LabelPolicy) { Add-Acao $Acoes 'Política de rótulos' $op 'Ignorado' 'Política não localizada; o rótulo já não está publicado.' }
        else {
            try {
                Set-LabelPolicy -Identity $m.LabelPolicy.Name -RemoveLabels $m.SensitivityLabel.Name -ErrorAction Stop 3>$null | Out-Null
                Add-Acao $Acoes 'Política de rótulos' $op 'Sucesso' 'Rótulo tirado da política.'
            } catch { Add-Acao $Acoes 'Política de rótulos' $op 'Falha' $_.Exception.Message }
        }
    }
    Add-Acao $Acoes 'DLP da Power Platform' $op 'Não aplicável' 'A DLP da Power Platform não tem estado ligado/desligado; use criar ou remover.'
}

function Remove-ModeloProtecao {
    <# ReverterModelo: remove so os objetos do modelo, na ordem do original. #>
    param([object]$Ctx, [System.Collections.IDictionary]$Estado, [System.Collections.Generic.List[object]]$Acoes)
    $m = $Estado.Model
    if (-not $Ctx.Purview) {
        foreach ($c in 'Política de rótulos', 'Rótulo de sensibilidade', 'DLP do Microsoft Purview') { Add-Acao $Acoes $c 'Remover' 'Bloqueado' $Ctx.PurviewMotivo }
    } else {
        foreach ($par in @(
                @{ C = 'Política de rótulos'; O = $m.LabelPolicy; R = { param($o) Remove-LabelPolicy -Identity $o.Name -Confirm:$false -ErrorAction Stop 3>$null | Out-Null } },
                @{ C = 'Rótulo de sensibilidade'; O = $m.SensitivityLabel; R = { param($o) Start-Sleep -Seconds 5; Remove-Label -Identity $o.Name -Confirm:$false -ErrorAction Stop 3>$null | Out-Null } },
                @{ C = 'DLP do Microsoft Purview'; O = $m.PurviewDlp; R = { param($o) Remove-DlpCompliancePolicy -Identity $o.Name -Confirm:$false -ErrorAction Stop 3>$null | Out-Null } })) {
            if (-not $par.O) { Add-Acao $Acoes $par.C 'Remover' 'Ignorado' 'Não existe.'; continue }
            if (-not (Get-ObjetoDoItem $par.O)) { Add-Acao $Acoes $par.C 'Remover' 'Bloqueado' 'O objeto com este nome não foi criado por este item; não foi removido.'; continue }
            try { & $par.R $par.O; Add-Acao $Acoes $par.C 'Remover' 'Sucesso' 'Removido (o Purview pode levar alguns minutos para concluir).' }
            catch { Add-Acao $Acoes $par.C 'Remover' 'Falha' $_.Exception.Message }
        }
    }
    if ($m.ConditionalAccess) {
        try {
            $null = Invoke-Api -Token $Ctx.TokenGraph -Metodo DELETE -Url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$($m.ConditionalAccess.id)"
            Add-Acao $Acoes 'Acesso Condicional' 'Remover' 'Sucesso' 'Removida.'
        } catch { Add-Acao $Acoes 'Acesso Condicional' 'Remover' 'Falha' (Get-MensagemErro $_) }
    } else { Add-Acao $Acoes 'Acesso Condicional' 'Remover' 'Ignorado' 'Não existe.' }
    if ($m.PowerPlatformDlp) {
        try {
            $nome = [string](Get-SafeProperty $m.PowerPlatformDlp 'name')
            if (-not $nome) { throw 'O identificador da política não foi retornado.' }
            $null = Invoke-Api -Token $Ctx.TokenPp -Metodo DELETE -Url "$($script:URL_DLP_PP)/$([uri]::EscapeDataString($nome))?api-version=$($script:API_DLP_PP)"
            Add-Acao $Acoes 'DLP da Power Platform' 'Remover' 'Sucesso' 'Removida.'
        } catch { Add-Acao $Acoes 'DLP da Power Platform' 'Remover' 'Falha' (Get-MensagemErro $_) }
    } else { Add-Acao $Acoes 'DLP da Power Platform' 'Remover' 'Ignorado' 'Não existe.' }
}

# ---------------------------------------------------------------- evidencias

function Write-EvidenciasModelo {
    <# contexto, funcoes, licencas e configuracao (json), nos nomes do original. #>
    param([string]$Pasta, [object]$Ctx, [string]$Acao, [string]$Justificativa, [System.Collections.IDictionary]$Nomes)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'funcoes-administrativas.csv' -Dados @($(if ($Ctx.Funcoes) { $Ctx.Funcoes } else { [pscustomobject]@{ Resultado = 'Nenhuma função localizada.' } }))
    Export-BizappEvidencia -Pasta $Pasta -Nome 'licencas-tenant.csv' -Dados @($Ctx.Licencas)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'contexto.csv' -Dados ([pscustomobject][ordered]@{
            DataHora = Get-Date; Item = 'AUTO-20'; Acao = $Acao; TenantId = $Ctx.Identidade.TenantId; Conta = $Ctx.Identidade.Conta
            EscoposGraph = ($Ctx.Identidade.Escopos -join '; '); FuncoesAtivas = (@($Ctx.Funcoes.Funcao) -join '; ')
            LicencaEntraP1 = $Ctx.TemP1; PowerShellVersion = [string]$PSVersionTable.PSVersion; VersaoModuloExchange = $Ctx.VersaoExo
            PurviewDisponivel = $Ctx.Purview; PurviewTenant = $(if ($Ctx.PurviewConexao) { $Ctx.PurviewConexao.TenantID }); PurviewBloqueio = $Ctx.PurviewMotivo
            Justificativa = $Justificativa; Objetos = (($Nomes.Values) -join '; ') })
}

function Save-EstadoJson {
    param([string]$Pasta, [string]$Nome, [System.Collections.IDictionary]$Estado)
    $Estado | ConvertTo-Json -Depth 30 -WarningAction SilentlyContinue | Set-Content -LiteralPath (Join-Path $Pasta $Nome) -Encoding utf8
}

function Write-ResumoModelo {
    <# acoes.csv, resumo.json e resumo.csv; falha tecnica interrompe a etapa, bloqueio so avisa. #>
    param([string]$Pasta, [string]$Acao, [object]$Ctx, [System.Collections.Generic.List[object]]$Acoes, [string]$Justificativa, [string]$ResultadoEsperado)
    if ($Acoes.Count) { Export-BizappEvidencia -Pasta $Pasta -Nome 'acoes.csv' -Dados $Acoes.ToArray() }
    $falhas = @($Acoes | Where-Object Status -eq 'Falha')
    $bloqueios = @($Acoes | Where-Object Status -eq 'Bloqueado')
    $gate = if ($falhas) { 'Parcial - falha técnica' } elseif ($bloqueios) { 'Parcial - dependência de licença ou acesso' } else { 'Aprovado' }
    $resumo = [ordered]@{
        AutomationId = 'AUTO-20'; AutomationName = 'DLP, acesso condicional e rótulo de sensibilidade como modelo'; DataFim = Get-Date
        Tenant = $Ctx.Identidade.TenantId; Conta = $Ctx.Identidade.Conta; Acao = $Acao; Justificativa = $Justificativa
        PurviewDisponivel = $Ctx.Purview; PurviewBloqueio = $Ctx.PurviewMotivo; ResultadoEsperado = $ResultadoEsperado; QualityGate = $gate
        Falhas = $falhas; DependenciasBloqueadas = $bloqueios; Acoes = $Acoes.ToArray(); PastaEvidencias = $Pasta
    }
    [pscustomobject]$resumo | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Pasta 'resumo.json') -Encoding utf8
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject][ordered]@{
            Item = 'AUTO-20'; Acao = $Acao; Conta = $Ctx.Identidade.Conta; QualityGate = $gate; Falhas = $falhas.Count; Bloqueios = $bloqueios.Count
            PurviewDisponivel = $Ctx.Purview; PastaEvidencias = $Pasta })
    if ($falhas) { throw "$($falhas.Count) componente(s) falharam: $(($falhas | ForEach-Object { $_.Componente }) -join ', '). Veja o log acima." }
    Write-BizappLog "Validação: $gate" -Nivel $(if ($bloqueios) { 'aviso' } else { 'sucesso' })
}

Export-ModuleMember -Variable ITEM, MARCA -Function Get-NomesModelo, Connect-ModeloProtecao, Disconnect-ModeloProtecao, Read-EstadoModelo, `
    Get-TextosEstado, Write-EstadoSaidas, New-ModeloProtecao, Set-EstadoModelo, Remove-ModeloProtecao, Write-EvidenciasModelo, Save-EstadoJson, `
    Write-ResumoModelo, Find-ByName, Get-SafeProperty
