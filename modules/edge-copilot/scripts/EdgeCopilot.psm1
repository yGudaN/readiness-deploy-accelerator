# Funcoes do item "Edge abrindo no Microsoft 365 Copilot" (AUTO-26): politica do Intune (Settings
# Catalog) com HomepageLocation e NewTabPageLocation do Microsoft Edge apontando para o Copilot.
# Montado a partir do relatorio e conferido com o script validado v8 (originais/26-navegadores-m365-copilot.ps1,
# vindo do guia de automacoes): mesmos IDs, opcao _1 e corpo; a v8 usa IDs fixos e o prefixo LAB-AUTO26. Mesmos endpoints beta,
# plataforma windows10/mdm, politica criada sem atribuicao, idempotente, atribuicao so a grupo
# piloto, desabilitar = remover atribuicoes, reverter = excluir so a politica controlada.
# NAO testado: o tenant de demo nao tem Intune ("Request not applicable to target tenant").

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'Edge-Copilot'
$script:MARCA = 'Criada pelo Readiness Deploy Accelerator'
$script:BETA = 'https://graph.microsoft.com/beta/deviceManagement'
$script:PAPEIS = @{ '62e90394-69f5-4237-9190-012177145e10' = 'Administrador Global'; '3a2c62db-5318-420d-8d74-23affee5d9d5' = 'Administrador do Intune' }
$script:AJUSTES = @('HomepageLocation', 'NewTabPageLocation')
$script:Token = $null

function Connect-EdgeCopilot {
    param([Parameter(Mandatory)][hashtable]$Entrada, [switch]$PrimeiraEtapa)
    $script:Token = Get-BizappToken -Entrada $Entrada -Nome Graph
    if ($PrimeiraEtapa) { return Get-BizappIdentidade -Token $script:Token }
    return Assert-BizappContexto -Token $script:Token -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta
}

function Invoke-Graph {
    param([string]$Metodo = 'GET', [Parameter(Mandatory)][string]$Uri, [object]$Corpo)
    $p = @{ Method = $Metodo; Uri = $Uri; Headers = @{ Authorization = "Bearer $script:Token"; Accept = 'application/json' } }
    if ($null -ne $Corpo) { $p.Body = [System.Text.Encoding]::UTF8.GetBytes(($Corpo | ConvertTo-Json -Depth 20 -Compress)); $p.ContentType = 'application/json; charset=utf-8' }
    try { Invoke-RestMethod @p } catch {
        $codigo = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        $msg = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { [string]$_.ErrorDetails.Message }
        if ($msg -match 'not applicable to target tenant') { throw 'O tenant não tem Microsoft Intune ("Request not applicable to target tenant"). É preciso uma licença com Intune (ex.: Intune Plan 1, EMS, Microsoft 365 E3/E5 ou Business Premium) ativa.' }
        if ($codigo -eq 401) { throw 'O acesso ao Microsoft Graph expirou ou foi negado (401). Rode a etapa de novo para fazer login.' }
        if ($codigo -eq 403) { throw "Sem permissão (403). É preciso ser Administrador Global ou Administrador do Intune. $msg" }
        throw "Microsoft Graph (HTTP $codigo): $(if ($msg) { $msg } else { $_.Exception.Message })"
    }
}

function Get-Lista([string]$Uri) {
    $itens = [System.Collections.Generic.List[object]]::new()
    while ($Uri) { $r = Invoke-Graph -Uri $Uri; foreach ($v in @($r.value)) { if ($v) { $itens.Add($v) } }; $Uri = [string]$r.'@odata.nextLink' }
    return , $itens.ToArray()
}

function Get-Contexto {
    <# Funcao (Administrador Global ou do Intune) e planos de servico do Intune. #>
    $papeis = Get-Lista 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName,roleTemplateId'
    $aceitos = @($papeis | Where-Object { $script:PAPEIS.ContainsKey($_.roleTemplateId) } | ForEach-Object { $script:PAPEIS[$_.roleTemplateId] })
    $skus = Get-Lista 'https://graph.microsoft.com/v1.0/subscribedSkus'
    $planos = @(foreach ($s in $skus) { foreach ($p in @($s.servicePlans)) { if ($p.servicePlanName -match 'INTUNE') { [pscustomobject]@{ Sku = $s.skuPartNumber; Plano = $p.servicePlanName; Status = $p.provisioningStatus } } } })
    # INTUNE_O365 e a "mobilidade basica" do Office 365: nao habilita o Settings Catalog
    $intune = @($planos | Where-Object { $_.Status -eq 'Success' -and $_.Plano -ne 'INTUNE_O365' })
    return [pscustomobject]@{ Papeis = $aceitos; Planos = $planos; TemIntune = [bool]$intune }
}

function Get-ArquivoReferencia { Join-Path (Get-BizappPastaEvidencias -Item $script:ITEM) 'referencia-politica.json' }

function Find-Politica {
    <# Politica controlada: pelo ID guardado (se ainda existir) ou pelo nome exato. #>
    param([Parameter(Mandatory)][string]$Nome)
    $ref = Get-ArquivoReferencia
    if (Test-Path -LiteralPath $ref) {
        $id = (Get-Content -LiteralPath $ref -Raw | ConvertFrom-Json).PolicyId
        try { $p = Invoke-Graph -Uri "$script:BETA/configurationPolicies/$id"; if ($p.name -eq $Nome) { return $p } } catch { }
    }
    $todas = Get-Lista "$script:BETA/configurationPolicies?`$select=id,name,description,platforms,technologies,isAssigned,lastModifiedDateTime"
    $mesmas = @($todas | Where-Object { $_.name -eq $Nome })
    if ($mesmas.Count -gt 1) { throw "Há $($mesmas.Count) políticas chamadas '$Nome'. Resolva a duplicidade no Intune antes de continuar. Nada foi alterado." }
    return $mesmas | Select-Object -First 1
}

function Test-PoliticaDoItem([object]$Politica) { return ([string]$Politica.description).Contains($script:MARCA) }

function Save-Referencia([object]$Politica) {
    $ref = Get-ArquivoReferencia
    New-Item -ItemType Directory -Force -Path (Split-Path $ref) | Out-Null
    @{ PolicyId = $Politica.id; Nome = $Politica.name; CriadaEm = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $ref -Encoding utf8
}

function Get-Definicoes {
    <#
    Definicoes do Edge (principal com Habilitado + filho com a URL). Como o relatorio, resolve
    direto em /configurationSettings/{id}; se nao achar, pesquisa no catalogo.
    #>
    $defs = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $script:AJUSTES) {
        $id = "device_vendor_msft_policy_config_microsoft_edge~policy~microsoft_edge~startup_$($a.ToLower())"
        $pai = $null
        try { $pai = Invoke-Graph -Uri "$script:BETA/configurationSettings/$id" } catch {
            if ($_.Exception.Message -match 'Intune') { throw }
            $filtro = [uri]::EscapeDataString("contains(id,'microsoft_edge') and contains(id,'$($a.ToLower())')")
            $cands = @(Get-Lista "$script:BETA/configurationSettings?`$filter=$filtro" | Where-Object { $_.id -like 'device_vendor_msft_policy_config_microsoft_edge*' -and $_.id -notlike '*recommended*' -and $_.id -like "*_$($a.ToLower())" })
            if ($cands.Count -ne 1) { throw "Não foi possível identificar o ajuste $a do Edge no catálogo do Intune ($($cands.Count) candidatos)." }
            $pai = $cands[0]
        }
        $ligado = @($pai.options) | Where-Object { $_.itemId -like '*_1' -or $_.displayName -match 'Enabled|Habilitado' } | Select-Object -First 1
        if (-not $ligado) { throw "O ajuste $a não tem a opção Habilitado no catálogo." }
        $filhoId = @($ligado.dependedOnBy.dependedOnBy) | Select-Object -First 1
        if (-not $filhoId) { $filhoId = "$($pai.id)_$($a.ToLower())" }
        $filho = Invoke-Graph -Uri "$script:BETA/configurationSettings/$filhoId"
        $defs.Add([pscustomobject]@{ Ajuste = $a; Principal = $pai.id; OpcaoHabilitado = $ligado.itemId; Filho = $filho.id })
    }
    return , $defs.ToArray()
}

function New-CorpoPolitica {
    param([Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][object[]]$Definicoes)
    $settings = @(foreach ($d in $Definicoes) {
            @{
                '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
                settingInstance = @{
                    '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
                    settingDefinitionId = $d.Principal
                    choiceSettingValue  = @{
                        '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
                        value    = $d.OpcaoHabilitado
                        children = @(@{
                                '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
                                settingDefinitionId = $d.Filho
                                simpleSettingValue  = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'; value = $Url }
                            })
                    }
                }
            }
        })
    return [ordered]@{
        name = $Nome; description = "Página inicial e nova guia do Microsoft Edge no Microsoft 365 Copilot ($Url). $script:MARCA."
        platforms = 'windows10'; technologies = 'mdm'; roleScopeTagIds = @('0'); settings = $settings
    }
}

function Get-Valores([string]$PolicyId) {
    $s = Get-Lista "$script:BETA/configurationPolicies/$PolicyId/settings"
    return , @(foreach ($x in $s) {
            $inst = $x.settingInstance
            [pscustomobject]@{ Definicao = $inst.settingDefinitionId; Opcao = $inst.choiceSettingValue.value; Valor = (@($inst.choiceSettingValue.children)[0]).simpleSettingValue.value }
        })
}

function Get-Atribuicoes([string]$PolicyId) {
    <# Devolve a lista como um objeto so (como Get-Lista): use sem @() em volta. #>
    $lista = Get-Lista "$script:BETA/configurationPolicies/$PolicyId/assignments"
    return , $lista
}

function Set-Atribuicoes {
    <# POST /assign: substitui as atribuicoes (lista vazia remove todas). #>
    param([Parameter(Mandatory)][string]$PolicyId, [string[]]$Grupos = @())
    $lista = @(foreach ($g in $Grupos) { @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationPolicyAssignment'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g } } })
    $null = Invoke-Graph -Metodo POST -Uri "$script:BETA/configurationPolicies/$PolicyId/assign" -Corpo @{ assignments = $lista }
}

function Get-TextoPolitica([object]$Politica, [int]$Atribuicoes) {
    if (-not $Politica) { return 'Não existe' }
    return "$($Politica.name) · $(if ($Atribuicoes) { "atribuída a $Atribuicoes grupo(s)" } else { 'sem atribuição (sem efeito nos dispositivos)' })"
}

function Write-ResumoEdge {
    param([string]$Pasta, [string]$Acao, [object]$Identidade, [bool]$Aprovada, [bool]$Alterou, [string]$Detalhe, [System.Collections.IDictionary]$Extras = @{})
    $resumo = [ordered]@{
        DataHoraFimUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-26'; Controle = 'Edge com página inicial e nova guia no Microsoft 365 Copilot'
        AcaoSolicitada = $Acao; TenantId = $Identidade.TenantId; Conta = $Identidade.Conta
    }
    foreach ($k in $Extras.Keys) { $resumo[$k] = $Extras[$k] }
    $resumo.AlteracaoExecutada = $Alterou
    $resumo.ValidacaoAprovada = $Aprovada
    $resumo.Resultado = $(if ($Aprovada) { 'Validado' } else { 'Falha' })
    $resumo.Detalhe = $Detalhe
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject]$resumo)
    if (-not $Aprovada) { throw $Detalhe }
}

Export-ModuleMember -Variable ITEM, MARCA -Function Connect-EdgeCopilot, Invoke-Graph, Get-Lista, Get-Contexto, Find-Politica, Test-PoliticaDoItem, Save-Referencia, `
    Get-Definicoes, New-CorpoPolitica, Get-Valores, Get-Atribuicoes, Set-Atribuicoes, Get-TextoPolitica, Write-ResumoEdge
