# Funcoes do AUTO-16 (Restricted Content Discovery: tirar um site da descoberta na pesquisa da
# organizacao e no Copilot, sem mudar permissoes), trazidas do script validado no laboratorio
# (testes-manuais/originais/16-rcd-sharepoint.ps1, teste de 12/11/2026). Do roteiro em Word
# (originais/16-rcd-sharepoint-roteiro.docx) vem a lista de sites com o estado do recurso.
# Diferencas:
#   - o Graph usa o token do login do instalador (chamadas REST, sem os modulos do Graph); o
#     SharePoint (Connect-SPOService) nao aceita token, entao faz o proprio login no navegador
#     padrao (UseSystemBrowser), como no original e no item de compartilhamento;
#   - o modulo do SharePoint e importado direto no PowerShell 7 (o original usa -UseWindowsPowerShell,
#     que devolve objetos desserializados; o import direto ja foi validado no item de compartilhamento);
#   - o prefixo do SharePoint e descoberto pelo Graph (site raiz) e o site precisa ser deste tenant;
#   - sem SharePoint Advanced Management, a recusa do SharePoint vira o aviso "Bloqueado".

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'Descoberta-Restrita'
$script:VERSAO_MINIMA_SPO = [version]'16.0.25409.0'
$script:ESCOPOS = @('User.Read.All', 'Organization.Read.All', 'RoleManagement.Read.Directory', 'Sites.Read.All')
$script:MENSAGEM_SEM_SAM = 'Bloqueado: o SharePoint recusou a alteração. Este recurso exige o SharePoint Advanced Management (incluído no Microsoft 365 Copilot ou vendido à parte). Nada foi alterado.'

function Invoke-GraphRest {
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Url)
    $itens = [System.Collections.Generic.List[object]]::new()
    $r = Invoke-RestMethod -Method GET -Uri $Url -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
    if ($null -eq $r.PSObject.Properties['value']) { return $r }
    while ($true) {
        foreach ($v in @($r.value)) { if ($null -ne $v) { $itens.Add($v) } }
        $proxima = $r.PSObject.Properties['@odata.nextLink']
        if (-not $proxima -or -not $proxima.Value) { break }
        $r = Invoke-RestMethod -Method GET -Uri $proxima.Value -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
    }
    return , $itens.ToArray()
}

function Test-ErroSemSam {
    <# Recusas vistas quando o tenant nao tem o SharePoint Advanced Management (item de compartilhamento). #>
    param([Parameter(Mandatory)][object]$Erro)
    return ([string]$Erro.Exception.Message) -match 'experimental feature|not supported in the current environment|Advanced Management|not licensed|licen'
}

function Import-SharePointModulo {
    $m = Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $m) { throw 'O módulo Microsoft.Online.SharePoint.PowerShell não está instalado. Instale-o pela tela de pré-requisitos.' }
    if ($m.Version -lt $script:VERSAO_MINIMA_SPO) {
        throw "O módulo do SharePoint está na versão $($m.Version); é preciso $($script:VERSAO_MINIMA_SPO) ou superior. Atualize pela tela de pré-requisitos."
    }
    # -Global: importado dentro deste .psm1, sem -Global os comandos ficariam invisiveis para o script da etapa
    Import-Module -Name $m.Path -Force -Global -DisableNameChecking -ErrorAction Stop -WarningAction SilentlyContinue 3>$null | Out-Null
    if (-not (Get-Command Set-SPOSite).Parameters.ContainsKey('RestrictContentOrgWideSearch')) {
        throw "O módulo do SharePoint $($m.Version) não tem a opção de descoberta restrita. Atualize pela tela de pré-requisitos."
    }
    Write-BizappLog "SharePoint Online Management Shell $($m.Version)" -Nivel discreto
    return $m
}

function Connect-DescobertaRestrita {
    <# Graph (conta, funcao, licencas, endereco do SharePoint) e depois o SharePoint com login proprio. #>
    param([Parameter(Mandatory)][hashtable]$Entrada)
    $token = Get-BizappToken -Entrada $Entrada -Nome Graph
    $id = Assert-BizappContexto -Token $token -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta
    $faltando = @($script:ESCOPOS | Where-Object { $_ -notin $id.Escopos })
    if ($faltando) { throw "O login não tem as permissões necessárias: $($faltando -join ', ')." }

    $usuario = Invoke-GraphRest -Token $token -Url "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($id.Conta))?`$select=id,displayName,userPrincipalName,accountEnabled"
    if ($usuario.accountEnabled -ne $true) { throw 'A conta administrativa está desabilitada no Microsoft Entra ID.' }
    $atribuicoes = Invoke-GraphRest -Token $token -Url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20%27$($usuario.id)%27&`$expand=roleDefinition"
    $funcoes = @(foreach ($a in $atribuicoes) {
            [pscustomobject]@{ Conta = $id.Conta; PrincipalId = $usuario.id; Funcao = $(if ($a.roleDefinition) { $a.roleDefinition.displayName } else { 'Não resolvida' })
                RoleDefinitionId = $a.roleDefinitionId; RoleAssignmentId = $a.id; DirectoryScopeId = $a.directoryScopeId }
        })
    $nomes = @($funcoes.Funcao)
    $aceitas = 'Global Administrator', 'Company Administrator', 'SharePoint Administrator', 'SharePoint Advanced Management Administrator'
    if (-not @($nomes | Where-Object { $_ -in $aceitas })) {
        throw "Nenhuma função administrativa compatível (Administrador Global, do SharePoint ou do SharePoint Advanced Management). Funções encontradas: $($nomes -join '; ')"
    }

    $licencas = @(foreach ($s in (Invoke-GraphRest -Token $token -Url 'https://graph.microsoft.com/v1.0/subscribedSkus')) {
            [pscustomobject]@{ SkuPartNumber = [string]$s.skuPartNumber; SkuId = [string]$s.skuId; Capacidade = [string]$s.capabilityStatus
                UnidadesAtivas = [int]$(if ($s.prepaidUnits) { $s.prepaidUnits.enabled } else { 0 }); UnidadesUsadas = [int]$s.consumedUnits }
        })
    $candidata = @($licencas | Where-Object { $_.SkuPartNumber -match 'COPILOT|SHAREPOINT.*ADVANCED|ADVANCED.*SHAREPOINT' }).Count -gt 0

    $raiz = Invoke-GraphRest -Token $token -Url 'https://graph.microsoft.com/v1.0/sites/root?$select=webUrl'
    $prefixo = ([uri]$raiz.webUrl).Host -replace '\.sharepoint\.com$', ''
    if ($prefixo -notmatch '^[a-zA-Z0-9-]+$') { throw "Não foi possível identificar o endereço do SharePoint ($($raiz.webUrl))." }

    $modulo = Import-SharePointModulo
    $adminUrl = "https://$prefixo-admin.sharepoint.com"
    Write-BizappLog "Conectando ao SharePoint ($adminUrl)..."
    Write-BizappLog "O SharePoint pede um login próprio no navegador padrão do Windows. Entre com $($id.Conta)." -Nivel aviso
    $p = @{ Url = $adminUrl; ErrorAction = 'Stop' }
    if ((Get-Command Connect-SPOService).Parameters.ContainsKey('UseSystemBrowser')) { $p.UseSystemBrowser = $true }
    Connect-SPOService @p
    $null = Get-SPOTenant -ErrorAction Stop
    Write-BizappLog 'SharePoint conectado.' -Nivel sucesso

    return [pscustomobject]@{
        Identidade = $id; Funcoes = $funcoes; NomesFuncoes = $nomes; Licencas = $licencas; LicencaCandidata = $candidata
        Prefixo = $prefixo; AdminUrl = $adminUrl; RaizUrl = "https://$prefixo.sharepoint.com"; VersaoModulo = [string]$modulo.Version
    }
}

function Disconnect-DescobertaRestrita {
    try { Disconnect-SPOService -ErrorAction SilentlyContinue | Out-Null } catch { }
}

function Get-SiteNormalizado {
    <# Mesmas regras do original + o site precisa ser deste tenant. #>
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][object]$Ctx)
    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { throw 'Informe o endereço completo do site, começando com https://.' }
    $hostSite = $uri.Host.ToLowerInvariant()
    if ($hostSite -match '-admin\.sharepoint\.') { throw 'Informe o endereço do site, não o do centro de administração do SharePoint.' }
    if ($hostSite -match '-my\.sharepoint\.') { throw 'A descoberta restrita não vale para sites pessoais do OneDrive.' }
    if ($hostSite -ne ([uri]$Ctx.RaizUrl).Host.ToLowerInvariant()) { throw "O site informado não é deste tenant (esperado um endereço em $($Ctx.RaizUrl)). Nada foi alterado." }
    return $uri.GetLeftPart([System.UriPartial]::Path).TrimEnd('/')
}

function Get-RcdSiteState {
    <# Mesmo formato do original (configuracao-antes/depois.csv). #>
    param([Parameter(Mandatory)][string]$Identity)
    $site = Get-SPOSite -Identity $Identity -ErrorAction Stop
    $prop = $site.PSObject.Properties['RestrictContentOrgWideSearch']
    if ($null -eq $prop) {
        throw 'O site foi consultado, mas o SharePoint não devolveu o estado da descoberta restrita. Confira a versão do módulo, a função administrativa e a licença do SharePoint Advanced Management.'
    }
    $valor = $prop.Value
    [pscustomobject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime(); SiteUrl = [string]$site.Url; SiteTitle = [string]$site.Title; Template = [string]$site.Template
        StatusSite = [string]$site.Status; LockState = [string]$site.LockState; RestrictContentOrgWideSearch = $valor
        RcdStatus = $(if ($null -eq $valor) { 'Não determinado' } elseif ([bool]$valor) { 'Habilitado' } else { 'Desabilitado' })
    }
}

function Get-SitesRcd {
    <# Lista do roteiro em Word: todos os sites (sem OneDrive) com o estado do recurso. #>
    $sites = @(Get-SPOSite -Limit All -ErrorAction Stop | Where-Object { $_.Url -notlike '*-my.sharepoint.com*' })
    return @($sites | ForEach-Object {
            [pscustomobject]@{ Title = [string]$_.Title; Url = [string]$_.Url; Template = [string]$_.Template
                RestrictContentOrgWideSearch = $_.RestrictContentOrgWideSearch }
        } | Sort-Object Title)
}

function Set-RcdSite {
    <# Altera e confere com ate 6 leituras a cada 10 s (como o original). Devolve o estado final. #>
    param([Parameter(Mandatory)][string]$Site, [Parameter(Mandatory)][bool]$Ligar)
    Set-SPOSite -Identity $Site -RestrictContentOrgWideSearch $Ligar -ErrorAction Stop
    $tentativa = 0
    do {
        $tentativa++
        Write-BizappProgresso -Percentual ($tentativa / 6 * 100) -Fase "Conferindo o resultado ($tentativa de 6)"
        Start-Sleep -Seconds 10
        $estado = Get-RcdSiteState -Identity $Site
    } while ([bool]$estado.RestrictContentOrgWideSearch -ne $Ligar -and $tentativa -lt 6)
    return $estado
}

function Write-ContextoRcd {
    param([string]$Pasta, [object]$Ctx, [string]$Acao, [string]$Site = '', [string]$Justificativa = '')
    Export-BizappEvidencia -Pasta $Pasta -Nome 'funcoes-administrativas.csv' -Dados @($Ctx.Funcoes)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'licencas-tenant.csv' -Dados @($Ctx.Licencas | Sort-Object SkuPartNumber)
    Export-BizappEvidencia -Pasta $Pasta -Nome 'contexto.csv' -Dados ([pscustomobject][ordered]@{
            DataHoraUtc = (Get-Date).ToUniversalTime(); TenantId = $Ctx.Identidade.TenantId; Conta = $Ctx.Identidade.Conta
            EscoposGraph = ($Ctx.Identidade.Escopos -join '; '); FuncoesAtivas = ($Ctx.NomesFuncoes -join '; ')
            PowerShellVersion = [string]$PSVersionTable.PSVersion; VersaoModuloSharePoint = $Ctx.VersaoModulo; SharePointAdminUrl = $Ctx.AdminUrl
            SiteUrl = $Site; Acao = $Acao; Justificativa = $Justificativa
            AvaliacaoLicenciamento = $(if ($Ctx.LicencaCandidata) { 'SKU candidata a Microsoft Copilot ou SharePoint Advanced Management encontrada' } else { 'SKU candidata não identificada pelo nome; validar funcionalmente o recurso' }) })
}

function Write-ResumoRcd {
    param([string]$Pasta, [string]$Site, [string]$Acao, [object]$Antes, [object]$Depois, [bool]$Alterou, [bool]$Aprovada, [string]$Justificativa = '', [string]$Erro = '')
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject][ordered]@{
            DataHoraUtc = (Get-Date).ToUniversalTime(); Item = 'AUTO-16'; Controle = 'Restricted Content Discovery'; SiteUrl = $Site; AcaoSolicitada = $Acao
            EstadoAntes = $(if ($Antes) { $Antes.RcdStatus } else { 'Não capturado' }); EstadoDepois = $(if ($Depois) { $Depois.RcdStatus } else { 'Não capturado' })
            AlteracaoExecutada = $Alterou; ValidacaoAprovada = $Aprovada; PermissoesAlteradas = $false; ConteudoExportado = $false
            Justificativa = $Justificativa; Erro = $Erro; PastaEvidencias = $Pasta
            Observacao = 'A propriedade administrativa foi validada. A propagação em pesquisa e Copilot pode levar tempo.' })
}

function Get-TextoRcd {
    param([AllowNull()][object]$Valor)
    if ($null -eq $Valor) { return 'Não determinado' }
    if ([bool]$Valor) { return 'Ligada (fora da pesquisa da organização e do Copilot)' }
    return 'Desligada (aparece normalmente na pesquisa e no Copilot)'
}

Export-ModuleMember -Variable ITEM, MENSAGEM_SEM_SAM -Function Test-ErroSemSam, Connect-DescobertaRestrita, Disconnect-DescobertaRestrita, `
    Get-SiteNormalizado, Get-RcdSiteState, Get-SitesRcd, Set-RcdSite, Write-ContextoRcd, Write-ResumoRcd, Get-TextoRcd
