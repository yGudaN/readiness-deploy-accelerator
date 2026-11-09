# Funcoes do AUTO-33 (politica de Acesso Condicional "MFA Copilot" para os grupos Copilot-Premium
# e Copilot-Geral), trazidas do script validado no laboratorio
# (testes-manuais/originais/33-mfa-copilot.ps1). A logica de consulta, desenho da politica,
# idempotencia e validacao posterior e a mesma; as diferencas sao:
#   - a conexao usa o token do login do instalador (BizappGraph.psm1), sem codigo de dispositivo;
#   - a referencia local do ID da politica fica por tenant (um arquivo por tenant), entao trocar
#     de tenant nao bloqueia a execucao;
#   - a avaliacao da politica devolve tambem o motivo de cada divergencia, para a tela.

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappGraph.psm1')

$script:ITEM = 'MFA-Copilot'
$script:NOME_POLITICA = 'MFA Copilot'
$script:RECURSO_ALVO = 'Office365'
$script:GRUPOS = @('Copilot-Premium', 'Copilot-Geral')
$script:ESTADO_RELATORIO = 'enabledForReportingButNotEnforced'

$script:MODULOS_GRAPH = @('Microsoft.Graph.Users', 'Microsoft.Graph.Groups', 'Microsoft.Graph.Identity.SignIns')
$script:ESCOPOS_CONSULTA = @('Policy.Read.All', 'Group.Read.All', 'User.Read.All', 'Organization.Read.All')
$script:ESCOPOS_ALTERACAO = @('Policy.ReadWrite.ConditionalAccess')

function Get-TextoEstado {
    <# Estado da politica em linguagem do usuario. #>
    param([AllowNull()][AllowEmptyString()][string]$Estado)
    switch ($Estado) {
        'enabledForReportingButNotEnforced' { 'Modo de relatório (não exige MFA, só registra)' }
        'enabled' { 'Ligada (exige MFA)' }
        'disabled' { 'Desligada' }
        '' { 'Não existe' }
        $null { 'Não existe' }
        default { $Estado }
    }
}

function ConvertTo-ListaContas {
    <# "a@x.com; b@x.com" -> lista unica, sem vazios. #>
    param([AllowNull()][AllowEmptyString()][string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return @() }
    $lista = @($Texto -split '[;,\s]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Select-Object -Unique)
    foreach ($c in $lista) {
        if ($c -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw "Conta de emergência inválida: $c" }
    }
    return $lista
}

function Connect-MfaCopilot {
    <# Prepara modulos, conecta o Graph com o token e confere tenant, conta e escopos. #>
    param([Parameter(Mandatory)][hashtable]$Entrada, [switch]$Alteracao)
    Import-BizappModulosGraph -Modulos $script:MODULOS_GRAPH
    $escopos = $script:ESCOPOS_CONSULTA + $(if ($Alteracao) { $script:ESCOPOS_ALTERACAO } else { @() })
    return Connect-BizappGraph -Token (Get-BizappToken -Entrada $Entrada -Nome Graph) -EscoposNecessarios $escopos `
        -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta
}

function Get-UsuarioEstrito {
    param([Parameter(Mandatory)][string]$Upn)
    try {
        return Get-MgUser -UserId $Upn -Property @('id', 'displayName', 'userPrincipalName', 'accountEnabled') -ErrorAction Stop
    } catch {
        throw "Usuário não localizado: $Upn. $($_.Exception.Message)"
    }
}

function Get-PreCondicoesTenant {
    <#
    Licenca Entra ID P1/P2 e "padroes de seguranca" (security defaults). Nao estavam no script
    original; foram verificados na pre-checagem do teste manual e passam a ser lidos aqui.
    #>
    $skus = @((Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' -ErrorAction Stop).value)
    $planos = @(foreach ($s in $skus) {
        foreach ($p in $s.servicePlans) {
            if ($p.servicePlanName -in 'AAD_PREMIUM', 'AAD_PREMIUM_P2' -and $p.provisioningStatus -eq 'Success' -and $s.capabilityStatus -eq 'Enabled') {
                [pscustomobject]@{ SkuPartNumber = $s.skuPartNumber; Plano = $p.servicePlanName; UnidadesAtivas = $s.prepaidUnits.enabled }
            }
        }
    })
    $sd = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy' -ErrorAction Stop
    return [pscustomobject]@{
        TemLicenca         = ($planos.Count -gt 0)
        Licencas           = (@($planos | ForEach-Object { "$($_.SkuPartNumber) ($($_.Plano))" } | Select-Object -Unique) -join ', ')
        PadroesSeguranca   = [bool]$sd.isEnabled
    }
}

function Get-GruposMfa {
    <# Grupos-alvo por nome exato. Mesma logica do original: ausencia so depois de consulta concluida. #>
    $resultado = @()
    foreach ($nome in $script:GRUPOS) {
        $escapado = $nome.Replace("'", "''")
        try {
            $encontrados = @(Get-MgGroup -Filter "displayName eq '$escapado'" -Property @(
                    'id', 'displayName', 'description', 'groupTypes', 'mail', 'mailEnabled', 'securityEnabled',
                    'membershipRule', 'membershipRuleProcessingState', 'createdDateTime') -All -ErrorAction Stop)
        } catch {
            throw "Falha ao consultar '$nome'. $($_.Exception.Message)"
        }
        if ($encontrados.Count -eq 0) {
            $resultado += [pscustomobject]@{ NomeConsultado = $nome; StatusConsulta = 'Não encontrado'; ConsultaConcluida = $true
                QuantidadeCorrespondencias = 0; CorrespondenciaUnica = $false; Id = $null; DisplayName = $null; Description = $null
                GroupTypes = $null; Mail = $null; MailEnabled = $null; SecurityEnabled = $null; MembershipRule = $null
                MembershipRuleProcessingState = $null; CreatedDateTime = $null; Observacao = 'Ausência confirmada.' }
            continue
        }
        foreach ($g in $encontrados) {
            $unico = $encontrados.Count -eq 1
            $resultado += [pscustomobject]@{ NomeConsultado = $nome; StatusConsulta = $(if ($unico) { 'Encontrado único' } else { 'Duplicidade' })
                ConsultaConcluida = $true; QuantidadeCorrespondencias = $encontrados.Count; CorrespondenciaUnica = $unico
                Id = [string]$g.Id; DisplayName = [string]$g.DisplayName; Description = [string]$g.Description
                GroupTypes = (@($g.GroupTypes) -join '; '); Mail = [string]$g.Mail; MailEnabled = $g.MailEnabled
                SecurityEnabled = $g.SecurityEnabled; MembershipRule = [string]$g.MembershipRule
                MembershipRuleProcessingState = [string]$g.MembershipRuleProcessingState; CreatedDateTime = $g.CreatedDateTime
                Observacao = $(if ($unico) { 'Objeto identificado sem alterações.' } else { 'Alterações bloqueadas por duplicidade.' }) }
        }
    }
    return @($resultado)
}

function Get-IdsGruposEsperados {
    <# IDs dos dois grupos; falha com orientacao se algum faltar ou estiver duplicado. #>
    param([Parameter(Mandatory)][object[]]$Grupos)
    foreach ($nome in $script:GRUPOS) {
        $linhas = @($Grupos | Where-Object NomeConsultado -eq $nome)
        if ($linhas.Count -eq 1 -and $linhas[0].CorrespondenciaUnica) { [string]$linhas[0].Id; continue }
        if (-not ($linhas | Where-Object Id)) {
            throw "O grupo $nome não existe neste tenant. Instale antes o item ""Grupos Copilot-Premium e Copilot-Geral"" do catálogo."
        }
        throw "Existe mais de um grupo com o nome $nome. Revise no Entra ID antes de continuar: nada foi alterado."
    }
}

# ---------------- Referencia local do ID da politica (uma por tenant) ----------------

function Get-CaminhoReferencia {
    param([Parameter(Mandatory)][string]$TenantId)
    $raiz = Get-BizappPastaEvidencias -Item $script:ITEM
    New-Item -ItemType Directory -Force -Path $raiz | Out-Null
    return Join-Path $raiz "referencia-politica-$TenantId.json"
}

function Save-ReferenciaPolitica {
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$PolicyId)
    [ordered]@{ DisplayName = $script:NOME_POLITICA; PolicyId = $PolicyId; TenantId = $TenantId; DataHora = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath (Get-CaminhoReferencia -TenantId $TenantId) -Encoding utf8
}

function Get-ReferenciaPolitica {
    param([Parameter(Mandatory)][string]$TenantId)
    $caminho = Get-CaminhoReferencia -TenantId $TenantId
    if (-not (Test-Path -LiteralPath $caminho)) { return $null }
    try {
        $ref = Get-Content -LiteralPath $caminho -Raw -Encoding utf8 | ConvertFrom-Json
        if ($ref.TenantId -ne $TenantId -or $ref.DisplayName -ne $script:NOME_POLITICA) { throw 'A referência pertence a outro tenant ou a outra política.' }
        return [string]$ref.PolicyId
    } catch {
        throw "A referência local da política não pôde ser validada ($caminho). $($_.Exception.Message)"
    }
}

function Remove-ReferenciaPolitica {
    param([Parameter(Mandatory)][string]$TenantId)
    $caminho = Get-CaminhoReferencia -TenantId $TenantId
    if (Test-Path -LiteralPath $caminho) { Remove-Item -LiteralPath $caminho -Force }
}

# ---------------- Politica ----------------

function Get-PoliticasPorNome {
    try {
        return @(Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop | Where-Object { $_.DisplayName -eq $script:NOME_POLITICA })
    } catch {
        throw "Falha ao listar as políticas de Acesso Condicional. $($_.Exception.Message)"
    }
}

function Get-PoliticaPorIdSegura {
    param([Parameter(Mandatory)][string]$PolicyId)
    try {
        $p = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $PolicyId -ErrorAction Stop
        if ($p.DisplayName -ne $script:NOME_POLITICA) { return $null }
        return $p
    } catch {
        return $null
    }
}

function Resolve-PoliticasMfa {
    <# Por nome; se nao achar, consulta direto pelo ID conhecido antes de considerar ausente. #>
    param([AllowNull()][AllowEmptyString()][string]$IdPreferido)
    $porNome = @(Get-PoliticasPorNome)
    if ($porNome.Count -gt 0) { return $porNome }
    if (-not [string]::IsNullOrWhiteSpace($IdPreferido)) {
        $porId = Get-PoliticaPorIdSegura -PolicyId $IdPreferido
        if ($null -ne $porId) { return @($porId) }
    }
    return @()
}

function Wait-PoliticaMfa {
    <# Revalida o estado posterior com retentativas (replicacao do Entra). #>
    param([bool]$DeveExistir, [AllowNull()][AllowEmptyString()][string]$IdPreferido, [AllowNull()][AllowEmptyString()][string]$EstadoEsperado, [int]$TempoMaximoSegundos = 90)
    $limite = (Get-Date).AddSeconds($TempoMaximoSegundos)
    do {
        $politicas = @(Resolve-PoliticasMfa -IdPreferido $IdPreferido)
        if (-not $DeveExistir) { if ($politicas.Count -eq 0) { return @() } }
        elseif ($politicas.Count -eq 1 -and ([string]::IsNullOrWhiteSpace($EstadoEsperado) -or [string]$politicas[0].State -eq $EstadoEsperado)) {
            return $politicas
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $limite)
    return @(Resolve-PoliticasMfa -IdPreferido $IdPreferido)
}

function ConvertTo-EvidenciaPolitica {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Politicas)
    $juntar = { param($v) (@($v | ForEach-Object { [string]$_ }) -join '; ') }
    if ($Politicas.Count -eq 0) {
        return @([pscustomobject]@{ StatusConsulta = 'Não encontrada'; ConsultaConcluida = $true; QuantidadeCorrespondencias = 0
                PolicyId = $null; DisplayName = $script:NOME_POLITICA; State = $null; CreatedDateTime = $null; ModifiedDateTime = $null
                IncludeGroups = $null; ExcludeGroups = $null; IncludeUsers = $null; ExcludeUsers = $null; IncludeApplications = $null
                ExcludeApplications = $null; ClientAppTypes = $null; GrantOperator = $null; BuiltInControls = $null; Observacao = 'Ausência confirmada.' })
    }
    foreach ($p in $Politicas) {
        [pscustomobject]@{
            StatusConsulta = $(if ($Politicas.Count -eq 1) { 'Encontrada única' } else { 'Duplicidade' }); ConsultaConcluida = $true
            QuantidadeCorrespondencias = $Politicas.Count; PolicyId = [string]$p.Id; DisplayName = [string]$p.DisplayName; State = [string]$p.State
            CreatedDateTime = $p.CreatedDateTime; ModifiedDateTime = $p.ModifiedDateTime
            IncludeGroups = (& $juntar $p.Conditions.Users.IncludeGroups); ExcludeGroups = (& $juntar $p.Conditions.Users.ExcludeGroups)
            IncludeUsers = (& $juntar $p.Conditions.Users.IncludeUsers); ExcludeUsers = (& $juntar $p.Conditions.Users.ExcludeUsers)
            IncludeApplications = (& $juntar $p.Conditions.Applications.IncludeApplications)
            ExcludeApplications = (& $juntar $p.Conditions.Applications.ExcludeApplications)
            ClientAppTypes = (& $juntar $p.Conditions.ClientAppTypes); GrantOperator = [string]$p.GrantControls.Operator
            BuiltInControls = (& $juntar $p.GrantControls.BuiltInControls)
            Observacao = $(if ($Politicas.Count -eq 1) { 'Política identificada.' } else { 'Alterações bloqueadas por duplicidade.' })
        }
    }
}

function Test-PoliticaMfa {
    <# Mesmos criterios do original (CoreConfigurationValid) + lista de divergencias legivel. #>
    param([AllowNull()][object]$Politica, [Parameter(Mandatory)][string[]]$IdsGrupos, [Parameter(Mandatory)][string[]]$IdsExcluidosObrigatorios)
    if ($null -eq $Politica) {
        return [pscustomobject]@{ Exists = $false; CoreConfigurationValid = $false; State = $null; Divergencias = @() }
    }
    $lista = { param($v) @($v | ForEach-Object { [string]$_ }) }
    $incluiGrupos = & $lista $Politica.Conditions.Users.IncludeGroups
    $excluiUsuarios = & $lista $Politica.Conditions.Users.ExcludeUsers
    $apps = & $lista $Politica.Conditions.Applications.IncludeApplications
    $clientes = & $lista $Politica.Conditions.ClientAppTypes
    $controles = & $lista $Politica.GrantControls.BuiltInControls

    $div = [System.Collections.Generic.List[string]]::new()
    if ($controles -notcontains 'mfa') { $div.Add('não exige MFA') }
    if ($apps -notcontains $script:RECURSO_ALVO) { $div.Add('não se aplica ao Office 365') }
    if ($clientes -notcontains 'all') { $div.Add('não cobre todos os tipos de aplicativo cliente') }
    if (@($IdsGrupos | Where-Object { $_ -notin $incluiGrupos }).Count) { $div.Add('não inclui os dois grupos') }
    if (@($incluiGrupos | Where-Object { $_ -notin $IdsGrupos }).Count) { $div.Add('inclui outros grupos além dos dois') }
    if (@($IdsExcluidosObrigatorios | Where-Object { $_ -notin $excluiUsuarios }).Count) {
        $div.Add('não exclui a conta administrativa e todas as contas de emergência informadas')
    }
    return [pscustomobject]@{ Exists = $true; CoreConfigurationValid = ($div.Count -eq 0); State = [string]$Politica.State; Divergencias = @($div) }
}

function Get-CorpoPolitica {
    <# Desenho da politica: so cria em modo de relatorio. #>
    param([Parameter(Mandatory)][string[]]$IdsGrupos, [Parameter(Mandatory)][string[]]$IdsExcluidos)
    @{
        DisplayName   = $script:NOME_POLITICA
        State         = $script:ESTADO_RELATORIO
        Conditions    = @{
            Users          = @{ IncludeGroups = @($IdsGrupos); ExcludeUsers = @($IdsExcluidos) }
            Applications   = @{ IncludeApplications = @($script:RECURSO_ALVO) }
            ClientAppTypes = @('all')
        }
        GrantControls = @{ Operator = 'OR'; BuiltInControls = @('mfa') }
    }
}

function Get-ContextoMfa {
    <#
    Linha de base comum a todas as etapas: conta administrativa, contas de emergencia, grupos,
    politica (por nome ou pelo ID conhecido) e avaliacao. Grava as evidencias "antes".
    #>
    param([Parameter(Mandatory)][object]$Identidade, [AllowNull()][AllowEmptyString()][string]$ContasEmergencia, [Parameter(Mandatory)][string]$Pasta, [string]$Acao)
    $admin = Get-UsuarioEstrito -Upn $Identidade.Conta
    $emergencia = @(ConvertTo-ListaContas -Texto $ContasEmergencia)
    if ($emergencia -contains $Identidade.Conta.ToLowerInvariant()) {
        throw 'A conta de emergência deve ser diferente da conta administrativa usada no login.'
    }
    $usuariosEmergencia = @($emergencia | ForEach-Object { Get-UsuarioEstrito -Upn $_ })
    $idsExcluidos = @(@([string]$admin.Id) + @($usuariosEmergencia | ForEach-Object { [string]$_.Id }) | Select-Object -Unique)

    $idReferencia = Get-ReferenciaPolitica -TenantId $Identidade.TenantId
    $grupos = @(Get-GruposMfa)
    $politicas = @(Resolve-PoliticasMfa -IdPreferido $idReferencia)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'grupos-antes.csv' -Dados $grupos
    Export-BizappEvidencia -Pasta $Pasta -Nome 'politica-antes.csv' -Dados @(ConvertTo-EvidenciaPolitica -Politicas $politicas)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'contexto.csv' -Dados ([pscustomobject]@{
            DataInicio = (Get-Date).ToString('o'); Acao = $Acao; TenantId = $Identidade.TenantId; Conta = $Identidade.Conta
            ContaAdministrativaId = $admin.Id; ContasEmergencia = ($emergencia -join '; '); ContasExcluidasIds = ($idsExcluidos -join '; ')
            PolicyIdReferenciaLocal = $idReferencia; EscoposAtivos = ($Identidade.Escopos -join '; '); PastaEvidencias = $Pasta })

    if ($politicas.Count -gt 1) { throw "Existe mais de uma política chamada ""$($script:NOME_POLITICA)"". Revise no Entra ID: nada foi alterado." }
    $politica = if ($politicas.Count -eq 1) { $politicas[0] } else { $null }
    if ($politica) { Save-ReferenciaPolitica -TenantId $Identidade.TenantId -PolicyId ([string]$politica.Id) }

    return [pscustomobject]@{
        Admin = $admin; Emergencia = $emergencia; IdsExcluidos = $idsExcluidos; IdReferencia = $idReferencia
        Grupos = $grupos; Politica = $politica; QuantidadePoliticas = $politicas.Count
    }
}

function Write-EstadoPolitica {
    <# Log + saida EstadoPolitica (usada nos avisos das etapas e no resumo final). #>
    param([AllowNull()][object]$Politica, [AllowNull()][object]$Avaliacao)
    $texto = Get-TextoEstado -Estado $(if ($Politica) { [string]$Politica.State } else { '' })
    if ($Avaliacao -and $Avaliacao.Exists -and -not $Avaliacao.CoreConfigurationValid) {
        $texto += " · diverge do desenho: $($Avaliacao.Divergencias -join '; ')"
    }
    Write-BizappLog "Política ""$($script:NOME_POLITICA)"": $texto" -Nivel $(if ($Avaliacao -and $Avaliacao.Exists -and -not $Avaliacao.CoreConfigurationValid) { 'aviso' } else { 'info' })
    Set-BizappSaida -Nome 'EstadoPolitica' -Valor $texto
    Set-BizappSaida -Nome 'PolicyId' -Valor $(if ($Politica) { [string]$Politica.Id } else { '' })
}

function Write-ResumoMfa {
    <# Grava acoes.csv, as evidencias "depois" e resumo.csv; interrompe se a validacao falhou. #>
    param([string]$Pasta, [string]$Acao, [object]$Identidade, [object[]]$Acoes, [object[]]$PoliticasDepois, [object]$AvaliacaoAntes,
        [object]$AvaliacaoDepois, [bool]$Alterou, [bool]$Aprovada, [string]$Nota = '', [datetime]$Inicio)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'acoes.csv' -Dados @($Acoes)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'grupos-depois.csv' -Dados @(Get-GruposMfa)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'politica-depois.csv' -Dados @(ConvertTo-EvidenciaPolitica -Politicas @($PoliticasDepois))
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject]@{
            AutomationId = 'AUTO-33'; AutomationName = 'MFA para o Copilot'; DataInicio = $Inicio.ToString('o'); DataFim = (Get-Date).ToString('o')
            Tenant = $Identidade.TenantId; Conta = $Identidade.Conta; Acao = $Acao
            PolicyIdEfetivo = $(if (@($PoliticasDepois).Count -eq 1) { [string]$PoliticasDepois[0].Id } else { '' })
            PolicyStateBefore = $AvaliacaoAntes.State; PolicyCountAfter = @($PoliticasDepois).Count; PolicyStateAfter = $AvaliacaoDepois.State
            CoreConfigurationValidAfter = $AvaliacaoDepois.CoreConfigurationValid; Divergencias = ($AvaliacaoDepois.Divergencias -join '; ')
            AlteracaoExecutada = $Alterou; ValidacaoAprovada = $Aprovada; QualityGate = $(if ($Aprovada) { 'Aprovado' } else { 'Reprovado' })
            Observacao = $Nota; PastaEvidencias = $Pasta })
    if (-not $Aprovada) { throw "A validação final não foi aprovada. $Nota".Trim() }
    Write-BizappLog 'Validação aprovada.' -Nivel sucesso
}

function New-RegistroAcao {
    param([string]$Acao, [string]$Status, [string]$Detalhe)
    [pscustomobject]@{ DataHora = (Get-Date).ToString('o'); AcaoSolicitada = $Acao; Operacao = $Acao; Status = $Status; Detalhe = $Detalhe }
}

Export-ModuleMember -Variable ITEM, NOME_POLITICA, ESTADO_RELATORIO -Function Get-TextoEstado, ConvertTo-ListaContas, Connect-MfaCopilot, `
    Get-PreCondicoesTenant, Get-GruposMfa, Get-IdsGruposEsperados, Save-ReferenciaPolitica, Remove-ReferenciaPolitica, Resolve-PoliticasMfa, `
    Wait-PoliticaMfa, ConvertTo-EvidenciaPolitica, Test-PoliticaMfa, Get-CorpoPolitica, Get-ContextoMfa, Write-EstadoPolitica, Write-ResumoMfa, `
    New-RegistroAcao, Get-UsuarioEstrito
