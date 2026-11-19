#Requires -Version 7.0
<#
.SYNOPSIS
    Teste manual do AUTO-26 (Edge com pagina inicial e nova guia no Microsoft 365 Copilot, via
    Intune Settings Catalog) no tenant de demo, MONTADO A PARTIR DO RELATORIO
    (originais/26-navegadores-relatorio.docx). O script validado no relatorio
    (26-navegadores-m365-copilot.ps1 v8) nao estava disponivel.

.DESCRIPTION
    Segue o que o relatorio descreve:
      - Microsoft Graph PowerShell (Connect-MgGraph + Invoke-MgGraphRequest) nos endpoints beta
        /deviceManagement/configurationPolicies e /deviceManagement/configurationSettings/{id};
      - politica LAB-AUTO26-Edge-M365-Copilot, windows10 / mdm, com HomepageLocation e
        NewTabPageLocation = URL do Copilot, criada SEM atribuicao;
      - acoes Consultar, Previsualizar, CriarPiloto (idempotente), AtribuirPiloto, Desabilitar
        (remove atribuicoes, mantem a politica) e Reverter (exclui so a politica controlada);
      - guardrails: prefixo LAB-AUTO26, confirmacao e justificativa, frase de risco para atribuir e
        reverter, bloqueio de duplicidade, ID da politica guardado em referencia-politica.json.

    O que precisa ser confirmado neste teste (nao vem do script validado):
      - os IDs das definicoes do Edge sao descobertos no catalogo do tenant (pesquisa pelo nome) e
        mostrados antes de criar; o corpo proposto fica em corpo-proposto.json;
      - a leitura depois da criacao confere os dois valores.

    Ordem: 1 modulo e login · 2 contexto (funcao e licenca) · 3 consultar · 4 definicoes ·
    5 previsualizar · 6 criar (CRIAR) · 7 criar de novo (idempotencia) · 8 atribuir piloto
    (opcional) · 9 desabilitar (opcional) · 10 reverter (opcional).

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Teste-AUTO26.ps1
#>
param(
    [string]$TenantIdEsperado = '6a1a0a9c-5bbb-4060-8231-08f2ad74171e',
    [string]$ContaEsperada = 'admin@crm332072.onmicrosoft.com',
    [string]$CopilotUrl = 'https://copilot.cloud.microsoft/',
    [string]$NomePolitica = 'LAB-AUTO26-Edge-M365-Copilot',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO26-Teste')
)

$ErrorActionPreference = 'Stop'
$PREFIXO = 'LAB-AUTO26'
$ESCOPOS = @('DeviceManagementConfiguration.ReadWrite.All', 'Organization.Read.All', 'User.Read', 'RoleManagement.Read.Directory', 'Group.Read.All')
$PAPEIS_ACEITOS = @{ '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'; '3a2c62db-5318-420d-8d74-23affee5d9d5' = 'Intune Administrator' }
$AJUSTES = @('HomepageLocation', 'NewTabPageLocation')

function Etapa([string]$Numero, [string]$Titulo) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host " ETAPA $Numero - $Titulo" -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
}
function Confirmar([string]$Pergunta) { return (Read-Host "$Pergunta (S/N)") -match '^[sS]' }

$resultados = [System.Collections.Generic.List[object]]::new()
function Registrar([string]$Parte, [string]$Acao, [bool]$Ok, [string]$Detalhe = '') {
    $script:resultados.Add([pscustomobject]@{ Parte = $Parte; Acao = $Acao; Sucesso = $Ok; Detalhe = $Detalhe })
    Write-Host "  $(if ($Ok) { 'OK' } else { 'FALHOU' }) - $Parte / ${Acao}$(if ($Detalhe) { ": $Detalhe" })" -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}
function Salvar([string]$Nome, $Dados) {
    $arq = Join-Path $script:Evid $Nome
    if ($Nome -like '*.json') { $Dados | ConvertTo-Json -Depth 20 | Set-Content -Path $arq -Encoding utf8; return }
    if (@($Dados).Count) { @($Dados) | Export-Csv -Path $arq -NoTypeInformation -Encoding utf8 }
    else { [pscustomobject]@{ Resultado = 'Sem registros' } | Export-Csv -Path $arq -NoTypeInformation -Encoding utf8 }
}
function Graph([string]$Metodo = 'GET', [string]$Uri, $Corpo) {
    $p = @{ Method = $Metodo; Uri = $Uri; OutputType = 'PSObject' }
    if ($null -ne $Corpo) { $p.Body = ($Corpo | ConvertTo-Json -Depth 20); $p.ContentType = 'application/json' }
    Invoke-MgGraphRequest @p
}
function Lista([string]$Uri) {
    $itens = [System.Collections.Generic.List[object]]::new()
    while ($Uri) { $r = Graph -Uri $Uri; foreach ($v in @($r.value)) { if ($v) { $itens.Add($v) } }; $Uri = [string]$r.'@odata.nextLink' }
    return , $itens.ToArray()
}

function Find-Politica {
    <# Politica controlada: pelo ID guardado (se ainda existir) ou pelo nome exato com o prefixo. #>
    $ref = Join-Path $PastaTrabalho 'referencia-politica.json'
    if (Test-Path $ref) {
        $id = (Get-Content $ref -Raw | ConvertFrom-Json).PolicyId
        try { return Graph -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$id" } catch { }
    }
    $todas = Lista "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$select=id,name,platforms,technologies,isAssigned,lastModifiedDateTime"
    $mesmas = @($todas | Where-Object { $_.name -eq $NomePolitica })
    if ($mesmas.Count -gt 1) { throw "Ha $($mesmas.Count) politicas chamadas '$NomePolitica'. Resolva a duplicidade antes de continuar." }
    return $mesmas | Select-Object -First 1
}

function Get-Definicao([string]$Ajuste) {
    <#
    Definicao principal (escolha Habilitado/Desabilitado) do Edge para o ajuste. Como o relatorio,
    tenta primeiro o ID direto em /configurationSettings/{id} (politicas de Startup do Edge,
    escopo de dispositivo); se nao existir, pesquisa no catalogo do tenant.
    #>
    $direto = "device_vendor_msft_policy_config_microsoft_edge~policy~microsoft_edge~startup_$($Ajuste.ToLower())"
    try {
        $d = Graph -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationSettings/$direto"
        Write-Host "  $Ajuste resolvido direto: $direto" -ForegroundColor DarkGray
        return , @($d)
    } catch { Write-Host "  $Ajuste nao achado pelo ID direto ($direto); pesquisando no catalogo..." -ForegroundColor DarkGray }
    $filtro = [uri]::EscapeDataString("contains(id,'microsoft_edge') and contains(id,'$($Ajuste.ToLower())')")
    $cands = Lista "https://graph.microsoft.com/beta/deviceManagement/configurationSettings?`$filter=$filtro"
    # Preferir a definicao de dispositivo (device_vendor_...), obrigatoria (nao recommended), sem sufixo de filho
    $principais = @($cands | Where-Object { $_.id -like 'device_vendor_msft_policy_config_microsoft_edge*' -and $_.id -notlike '*recommended*' -and $_.id -like "*_$($Ajuste.ToLower())" })
    return , @($principais)
}

function Get-Valores([string]$PolicyId) {
    <# Le os ajustes da politica e devolve cada principal com o valor do filho. #>
    $s = Lista "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$PolicyId/settings"
    return , @(foreach ($x in $s) {
            $inst = $x.settingInstance
            $filho = @($inst.choiceSettingValue.children)[0]
            [pscustomobject]@{ Definicao = $inst.settingDefinitionId; Opcao = $inst.choiceSettingValue.value; Valor = $filho.simpleSettingValue.value }
        })
}

New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$script:Evid = Join-Path $PastaTrabalho "evidencias\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Force -Path $script:Evid | Out-Null
$LOG_TESTE = Join-Path $PastaTrabalho "teste-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -LiteralPath $LOG_TESTE -Force | Out-Null
$acoes = [System.Collections.Generic.List[object]]::new()

try {
    if (-not $NomePolitica.StartsWith($PREFIXO)) { throw "O nome da politica precisa comecar com $PREFIXO (guardrail)." }

    # ------------------------------------------------------------------
    Etapa 1 'Modulo e login (Microsoft Graph PowerShell)'
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        if (-not (Confirmar 'Falta o Microsoft.Graph.Authentication. Instalar para o seu usuario?')) { throw 'Modulo nao instalado.' }
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
    }
    Import-Module Microsoft.Graph.Authentication
    Write-Host "Microsoft.Graph.Authentication $((Get-Module Microsoft.Graph.Authentication).Version)" -ForegroundColor Green
    Write-Host "Tenant esperado: $TenantIdEsperado"
    Write-Host "Conta esperada:  $ContaEsperada"
    if (-not (Confirmar 'Estes sao os dados do tenant de DEMO?')) {
        $TenantIdEsperado = Read-Host 'Tenant ID do tenant de demo'
        $ContaEsperada = Read-Host 'Conta administradora (UPN)'
    }
    Connect-MgGraph -TenantId $TenantIdEsperado -Scopes $ESCOPOS -NoWelcome -ContextScope Process
    $ctx = Get-MgContext
    if ($ctx.TenantId -ne $TenantIdEsperado) { throw "Login em outro tenant ($($ctx.TenantId)). Nada foi alterado." }
    if ($ctx.Account -ne $ContaEsperada) { throw "Login com outra conta ($($ctx.Account)). Nada foi alterado." }
    $faltam = @($ESCOPOS | Where-Object { $_ -notin $ctx.Scopes })
    Registrar 'Contexto' 'Tenant, conta e escopos' (-not $faltam) $(if ($faltam) { "Faltam: $($faltam -join ', ')" } else { "$($ctx.Account)" })
    Salvar 'contexto.csv' ([pscustomobject]@{ TenantId = $ctx.TenantId; Conta = $ctx.Account; Escopos = ($ctx.Scopes -join '; '); Url = $CopilotUrl; Politica = $NomePolitica })

    # ------------------------------------------------------------------
    Etapa 2 'Funcao administrativa e licenca do Intune'
    $papeis = Lista "https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?`$select=displayName,roleTemplateId"
    Salvar 'funcoes-administrativas.csv' @($papeis | Select-Object displayName, roleTemplateId)
    $aceito = @($papeis | Where-Object { $PAPEIS_ACEITOS.ContainsKey($_.roleTemplateId) })
    Registrar 'Contexto' 'Funcao Global Administrator ou Intune Administrator' ([bool]$aceito) (($aceito.displayName) -join ', ')
    $skus = Lista 'https://graph.microsoft.com/v1.0/subscribedSkus'
    $planos = @(foreach ($s in $skus) { foreach ($p in @($s.servicePlans)) { if ($p.servicePlanName -match 'INTUNE') { [pscustomobject]@{ Sku = $s.skuPartNumber; Plano = $p.servicePlanName; Status = $p.provisioningStatus } } } })
    Salvar 'licencas-intune.csv' $planos
    Registrar 'Contexto' 'Licenca com Intune' ([bool]($planos | Where-Object Status -eq 'Success')) (($planos | Select-Object -ExpandProperty Plano -Unique) -join ', ')

    # ------------------------------------------------------------------
    Etapa 3 'Consultar (somente leitura)'
    $atual = Find-Politica
    Registrar 'Consultar' 'configurationPolicies respondeu' $true $(if ($atual) { "Politica ja existe: $($atual.id)" } else { 'Politica nao localizada (baseline)' })
    if ($atual) {
        Salvar 'configuracao-antes.csv' (Get-Valores $atual.id)
        Salvar 'atribuicoes-antes.json' (Lista "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($atual.id)/assignments")
    } else { Salvar 'configuracao-antes.csv' @() }

    # ------------------------------------------------------------------
    Etapa 4 '[+] Descobrir as definicoes do Edge no catalogo'
    $defs = [ordered]@{}
    foreach ($a in $AJUSTES) {
        $cands = Get-Definicao $a
        foreach ($c in $cands) { Write-Host "  candidato $a : $($c.id)  ($($c.displayName))" -ForegroundColor DarkGray }
        if ($cands.Count -ne 1) { throw "Esperava 1 definicao principal para $a e encontrei $($cands.Count). Veja definicoes-configuracao.csv." }
        $pai = $cands[0]
        $ligado = @($pai.options) | Where-Object { $_.itemId -like '*_1' -or $_.displayName -match 'Enabled|Habilitado' } | Select-Object -First 1
        $filhoId = @($ligado.dependedOnBy.dependedOnBy) | Select-Object -First 1
        if (-not $filhoId) { $filhoId = "$($pai.id)_$($a.ToLower())" }
        $filho = Graph -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationSettings/$filhoId"
        $defs[$a] = [pscustomobject]@{ Ajuste = $a; Principal = $pai.id; Nome = $pai.displayName; OpcaoHabilitado = $ligado.itemId; Filho = $filho.id; NomeFilho = $filho.displayName }
    }
    Salvar 'definicoes-configuracao.csv' @($defs.Values)
    $defs.Values | Format-List | Out-Host
    Registrar 'Definicoes' 'HomepageLocation e NewTabPageLocation resolvidas' $true '2 principais e 2 filhas'

    # ------------------------------------------------------------------
    Etapa 5 'Previsualizar (sem alteracao)'
    $settings = @(foreach ($d in $defs.Values) {
            @{
                '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
                settingInstance = @{
                    '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
                    settingDefinitionId = $d.Principal
                    choiceSettingValue  = @{
                        value    = $d.OpcaoHabilitado
                        children = @(@{
                                '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
                                settingDefinitionId = $d.Filho
                                simpleSettingValue  = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'; value = $CopilotUrl }
                            })
                    }
                }
            }
        })
    $corpo = [ordered]@{
        name = $NomePolitica; description = "AUTO-26: pagina inicial e nova guia do Edge no Microsoft 365 Copilot ($CopilotUrl). Readiness Deploy Accelerator."
        platforms = 'windows10'; technologies = 'mdm'; roleScopeTagIds = @('0'); settings = $settings
    }
    Salvar 'corpo-proposto.json' $corpo
    Write-Host "Corpo proposto salvo em corpo-proposto.json ($($settings.Count) ajustes, URL $CopilotUrl)."
    Registrar 'Previsualizar' 'Corpo proposto gerado' $true 'Nenhuma alteracao executada'

    # ------------------------------------------------------------------
    Etapa 6 'CriarPiloto (sem atribuicao)'
    if ($atual) {
        Write-Host "A politica ja existe ($($atual.id)): nova criacao ignorada (idempotencia)." -ForegroundColor Green
        Registrar 'CriarPiloto' 'Idempotencia' $true 'Politica existente; criacao ignorada'
        $politica = $atual
    } elseif ((Read-Host 'Criar a politica sem atribuicao? Digite CRIAR') -ceq 'CRIAR') {
        $just = Read-Host 'Justificativa (registrada nas evidencias)'
        $politica = Graph -Metodo POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' -Corpo $corpo
        @{ PolicyId = $politica.id; Nome = $NomePolitica; CriadaEm = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $PastaTrabalho 'referencia-politica.json') -Encoding utf8
        $acoes.Add([pscustomobject]@{ Acao = 'CriarPiloto'; PolicyId = $politica.id; Justificativa = $just; DataHora = (Get-Date).ToString('o') })
        Registrar 'CriarPiloto' 'Politica criada' ([bool]$politica.id) $politica.id
    } else { Write-Host 'Criacao nao confirmada.' -ForegroundColor Yellow }

    if ($politica) {
        $valores = Get-Valores $politica.id
        Salvar 'configuracao-depois.csv' $valores
        $valores | Format-Table -AutoSize | Out-Host
        foreach ($d in $defs.Values) {
            $v = $valores | Where-Object Definicao -eq $d.Principal | Select-Object -First 1
            Registrar 'Leitura posterior' $d.Ajuste ($v -and $v.Opcao -eq $d.OpcaoHabilitado -and $v.Valor -eq $CopilotUrl) "$($v.Opcao) / $($v.Valor)"
        }
        $atrib = Lista "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($politica.id)/assignments"
        Salvar 'atribuicoes-depois.json' $atrib
        Registrar 'Leitura posterior' 'Atribuicoes' $true "$($atrib.Count)"

        # --------------------------------------------------------------
        Etapa 7 'CriarPiloto de novo (idempotencia)'
        $denovo = Find-Politica
        Registrar 'CriarPiloto' 'Segunda execucao localiza a existente' ($denovo -and $denovo.id -eq $politica.id) 'Nova criacao ignorada'

        # --------------------------------------------------------------
        Etapa 8 'AtribuirPiloto (opcional)'
        Write-Host 'Atribui a um grupo de seguranca de TESTE: os dispositivos do grupo recebem a politica.' -ForegroundColor DarkGray
        $grupo = (Read-Host 'Object ID do grupo piloto (Enter para pular)').Trim()
        if ($grupo) {
            $g = Graph -Uri "https://graph.microsoft.com/v1.0/groups/$grupo`?`$select=id,displayName,securityEnabled"
            if ((Read-Host "Atribuir a '$($g.displayName)'? Digite EU ENTENDO O RISCO") -ceq 'EU ENTENDO O RISCO') {
                $null = Graph -Metodo POST -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($politica.id)/assign" -Corpo @{
                    assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $grupo } }) }
                $atrib = Lista "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($politica.id)/assignments"
                Registrar 'AtribuirPiloto' "Grupo $($g.displayName)" (@($atrib | Where-Object { $_.target.groupId -eq $grupo }).Count -eq 1) "$($atrib.Count) atribuicao(oes)"
                $acoes.Add([pscustomobject]@{ Acao = 'AtribuirPiloto'; PolicyId = $politica.id; Justificativa = $g.displayName; DataHora = (Get-Date).ToString('o') })
                Write-Host 'No dispositivo do grupo: sincronize no Intune e no Windows, abra edge://policy, clique em Recarregar politicas e confira HomepageLocation e NewTabPageLocation.' -ForegroundColor Cyan
            }
        }

        # --------------------------------------------------------------
        Etapa 9 'Desabilitar (opcional): remove as atribuicoes e mantem a politica'
        $atrib = Lista "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($politica.id)/assignments"
        if ($atrib.Count -and (Confirmar "Remover as $($atrib.Count) atribuicao(oes)?")) {
            $null = Graph -Metodo POST -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($politica.id)/assign" -Corpo @{ assignments = @() }
            $atrib = Lista "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($politica.id)/assignments"
            Registrar 'Desabilitar' 'Atribuicoes removidas' ($atrib.Count -eq 0) "$($atrib.Count)"
        } elseif (-not $atrib.Count) { Write-Host 'Sem atribuicoes: nada a desabilitar.' -ForegroundColor DarkGray }

        # --------------------------------------------------------------
        Etapa 10 'Reverter (opcional): exclui so a politica controlada'
        Write-Host 'O relatorio recomenda manter a politica sem atribuicao no laboratorio.' -ForegroundColor DarkGray
        if ((Read-Host "Para EXCLUIR '$NomePolitica', digite EU ENTENDO O RISCO (Enter = manter)") -ceq 'EU ENTENDO O RISCO') {
            if (-not $politica.name.StartsWith($PREFIXO) -and -not $NomePolitica.StartsWith($PREFIXO)) { throw 'Guardrail: so politicas com o prefixo podem ser excluidas.' }
            $null = Graph -Metodo DELETE -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($politica.id)"
            $resta = Find-Politica
            Registrar 'Reverter' 'Politica excluida' (-not $resta) $politica.id
            Remove-Item (Join-Path $PastaTrabalho 'referencia-politica.json') -ErrorAction SilentlyContinue
        } else { Write-Host 'Politica mantida.' }
    }
} catch {
    Write-Host ''
    Write-Host "PAROU: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor DarkGray }
    Write-Host "Onde: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    $resultados.Add([pscustomobject]@{ Parte = 'Erro'; Acao = 'Parou'; Sucesso = $false; Detalhe = $_.Exception.Message })
} finally {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host ' RESUMO (quality gate)' -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    if ($resultados.Count) {
        $resultados | Format-Table -AutoSize -Wrap | Out-Host
        $resultados | Export-Csv -Path (Join-Path $script:Evid 'resumo.csv') -NoTypeInformation -Encoding utf8
        Write-Host "Quality gate: $(if ($resultados | Where-Object { -not $_.Sucesso }) { 'REPROVADO' } else { 'APROVADO' })" -ForegroundColor $(if ($resultados | Where-Object { -not $_.Sucesso }) { 'Red' } else { 'Green' })
    }
    if ($acoes.Count) { $acoes | Export-Csv -Path (Join-Path $script:Evid 'acoes.csv') -NoTypeInformation -Encoding utf8 }
    Write-Host "Evidencias: $script:Evid" -ForegroundColor DarkGray
    try { Disconnect-MgGraph | Out-Null } catch { }
    Write-Host "Log completo do teste: $LOG_TESTE" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
}
