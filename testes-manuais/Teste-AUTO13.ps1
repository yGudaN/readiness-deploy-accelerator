#Requires -Version 7.0
<#
.SYNOPSIS
    Teste manual do AUTO-13 (Canvas Apps e Cloud Flows criados em solucoes por padrao, por
    ambiente) num ambiente de demo, seguindo o roteiro em Word do item
    (originais/13-roteiro.docx; o cabecalho diz COE-IA-006).

.DESCRIPTION
    O roteiro nao automatiza a troca: pede os valores, confirma e abre o admin center, dizendo que
    nao ha cmdlet publico. Mas a documentacao da Microsoft ("Add canvas apps and cloud flows to a
    solution by default", item 5 das consideracoes) diz que as duas chaves do admin center gravam as
    colunas enablecanvasappsinsolutionsbydefault e enableflowsinsolutionbydefault da tabela
    organization do Dataverse, que a referencia da tabela lista como graváveis. Este teste confere
    se alterar essas colunas pela Web API tem o mesmo efeito da tela, para o instalador poder fazer
    isso sem passos manuais.

    Acrescimos ao roteiro (marcados com [+] na tela):
      - le o estado atual das duas chaves antes de mudar (o checklist pede "antes/depois");
      - altera pela Web API e confere relendo; voce confere tambem na tela do admin center;
      - valida o componente de teste: procura pelo nome o app ou fluxo que voce criar e mostra
        em quais solucoes ele ficou;
      - no fim, pode voltar as duas chaves ao valor original.

    Ordem do teste:
      1. Modulo Az.Accounts
      2. Ambiente (URL do Dataverse) e login (codigo de dispositivo)
      3. Conferir a organizacao e o papel da conta (somente leitura)
      4. Estado atual das chaves (somente leitura)
      5. Valores desejados, resumo e confirmacao (digite SIM, como o roteiro)
      6. Alterar e conferir; conferir tambem no admin center
      7. (opcional) Componente de teste: em qual solucao ele ficou
      8. (opcional) Voltar ao valor original

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Teste-AUTO13.ps1
#>
param(
    [string]$TenantIdEsperado = '6a1a0a9c-5bbb-4060-8231-08f2ad74171e',
    [string]$ContaEsperada = 'admin@crm332072.onmicrosoft.com',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO13-Teste')
)

$ErrorActionPreference = 'Stop'
$ADMIN_SISTEMA = '627090ff-40a3-4053-8790-584edc5be201'   # id fixo do papel Administrador do sistema
$COLUNAS = 'organizationid,name,enablecanvasappsinsolutionsbydefault,enableflowsinsolutionbydefault,enableflowsinsolutionbydefaultgraceperiod'

function Etapa([string]$Numero, [string]$Titulo) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host " ETAPA $Numero - $Titulo" -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
}

function Confirmar([string]$Pergunta) {
    return (Read-Host "$Pergunta (S/N)") -match '^[sS]'
}

$resultados = [System.Collections.Generic.List[object]]::new()
function Registrar([string]$Parte, [string]$Acao, [bool]$Ok, [string]$Detalhe = '') {
    $script:resultados.Add([pscustomobject]@{ Parte = $Parte; Acao = $Acao; Sucesso = $Ok; Detalhe = $Detalhe })
    Write-Host "  $(if ($Ok) { 'OK' } else { 'FALHOU' }) - $Parte / ${Acao}$(if ($Detalhe) { ": $Detalhe" })" -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

function Api {
    param([string]$Metodo = 'GET', [Parameter(Mandatory)][string]$Caminho, [object]$Corpo, [switch]$Lista)
    $url = if ($Caminho -match '^https://') { $Caminho } else { "$script:Org/api/data/v9.2/$Caminho" }
    $p = @{ Method = $Metodo; Uri = $url; Headers = $script:Cab; ErrorAction = 'Stop' }
    if ($null -ne $Corpo) { $p.Body = ($Corpo | ConvertTo-Json -Depth 10); $p.ContentType = 'application/json' }
    if (-not $Lista) { return Invoke-RestMethod @p }
    $itens = [System.Collections.Generic.List[object]]::new()
    while ($url) {
        $p.Uri = $url
        $r = Invoke-RestMethod @p
        foreach ($v in @($r.value)) { if ($null -ne $v) { $itens.Add($v) } }
        $url = [string]$r.'@odata.nextLink'
    }
    return , $itens.ToArray()
}

function Salvar([string]$Nome, [object[]]$Dados) {
    $arq = Join-Path $script:Evid $Nome
    if (@($Dados).Count) { @($Dados) | Export-Csv -Path $arq -NoTypeInformation -Encoding utf8 }
    else { [pscustomobject]@{ Resultado = 'Sem registros' } | Export-Csv -Path $arq -NoTypeInformation -Encoding utf8 }
}

function Ler-Chaves {
    $o = @((Api -Caminho "organizations?`$select=$COLUNAS").value)[0]
    [pscustomobject]@{
        OrganizationId = $o.organizationid; Nome = $o.name
        CanvasApps = [bool]$o.enablecanvasappsinsolutionsbydefault
        CloudFlows = [bool]$o.enableflowsinsolutionbydefault
        PeriodoCarenciaFlows = [bool]$o.enableflowsinsolutionbydefaultgraceperiod
    }
}

function Texto([bool]$v) { if ($v) { 'On' } else { 'Off' } }

function Pedir-SimNao([string]$Pergunta, [bool]$Atual) {
    while ($true) {
        $r = (Read-Host "$Pergunta Digite SIM ou NAO (Enter = manter $(if ($Atual) { 'SIM' } else { 'NAO' }))").Trim().ToUpper()
        if (-not $r) { return $Atual }
        if ($r -eq 'SIM') { return $true }
        if ($r -eq 'NAO') { return $false }
    }
}

New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$script:Evid = Join-Path $PastaTrabalho "evidencias\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Force -Path $script:Evid | Out-Null
$LOG_TESTE = Join-Path $PastaTrabalho "teste-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -LiteralPath $LOG_TESTE -Force | Out-Null
$antes = $null

try {
    # ------------------------------------------------------------------
    Etapa 1 'Modulo Az.Accounts (para pegar o token do Dataverse)'
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Host 'Falta o Az.Accounts. E instalado so para o seu usuario (Install-Module -Scope CurrentUser).' -ForegroundColor DarkGray
        if (-not (Confirmar 'Instalar agora?')) { throw 'Modulo nao instalado. Nada foi alterado.' }
        Install-Module -Name Az.Accounts -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    Import-Module Az.Accounts -ErrorAction Stop
    Write-Host "Az.Accounts $((Get-Module Az.Accounts).Version)" -ForegroundColor Green

    # ------------------------------------------------------------------
    Etapa 2 'Ambiente e login'
    Write-Host "Tenant esperado: $TenantIdEsperado"
    Write-Host "Conta esperada:  $ContaEsperada"
    if (-not (Confirmar 'Estes sao os dados do tenant de DEMO?')) {
        $TenantIdEsperado = Read-Host 'Tenant ID do tenant de demo'
        $ContaEsperada = Read-Host 'Conta administradora (UPN)'
    }
    $nomeAmbiente = Read-Host 'Informe o nome do ambiente que voce quer configurar'
    Write-Host 'URL do ambiente Dataverse de TESTE (ex.: https://org1234.crm.dynamics.com).' -ForegroundColor Cyan
    Write-Host 'Voce encontra em https://admin.powerplatform.microsoft.com > Ambientes > ambiente > URL do ambiente.' -ForegroundColor DarkGray
    $script:Org = (Read-Host 'URL do ambiente').Trim().TrimEnd('/')
    if ($script:Org -notmatch '^https://[a-z0-9-]+\.crm\d*\.dynamics\.com$') { throw "URL invalida: $($script:Org)" }
    Write-Host 'Login: abra https://microsoft.com/devicelogin, digite o codigo que vai aparecer e entre com' -ForegroundColor Cyan
    Write-Host "$ContaEsperada. Se a tela parecer parada, aperte Esc." -ForegroundColor Cyan
    Connect-AzAccount -Tenant $TenantIdEsperado -UseDeviceAuthentication -ErrorAction Stop | Out-Null
    $conta = (Get-AzContext).Account.Id
    if ($conta -ne $ContaEsperada) { throw "Login com outra conta ($conta). Nada foi alterado." }
    $at = Get-AzAccessToken -ResourceUrl $script:Org
    $token = if ($at.Token -is [System.Security.SecureString]) { [System.Net.NetworkCredential]::new('', $at.Token).Password } else { $at.Token }
    $script:Cab = @{ Authorization = "Bearer $token"; Accept = 'application/json'; 'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0' }
    Write-Host "Conectado como $conta (o token nao e exibido nem gravado)." -ForegroundColor Green

    # ------------------------------------------------------------------
    Etapa 3 'Conferir o ambiente e o papel da conta (somente leitura)'
    $atual = (Api -Caminho "RetrieveCurrentOrganization(AccessType=@p)?@p=Microsoft.Dynamics.CRM.EndpointAccessType'Default'").Detail
    Write-Host "Ambiente: $($atual.FriendlyName)  ·  Environment ID $($atual.EnvironmentId)  ·  versao $($atual.OrganizationVersion)"
    if ($nomeAmbiente -and $atual.FriendlyName -ne $nomeAmbiente) { Write-Host "Atencao: o nome informado ($nomeAmbiente) e diferente do nome do ambiente." -ForegroundColor Yellow }
    $eu = Api -Caminho 'WhoAmI'
    $papeis = Api -Lista -Caminho "systemusers($($eu.UserId))/systemuserroles_association?`$select=name,_roletemplateid_value"
    $admin = [bool]($papeis | Where-Object { $_._roletemplateid_value -eq $ADMIN_SISTEMA })
    Write-Host "Papeis da conta: $((@($papeis.name) | Sort-Object -Unique) -join ', ')"
    Registrar 'Ambiente' 'Conferir' $true "$($atual.FriendlyName) / $($atual.EnvironmentId); Administrador do sistema: $admin"
    Salvar 'ambiente.csv' @([pscustomobject]@{ Url = $script:Org; Nome = $atual.FriendlyName; EnvironmentId = $atual.EnvironmentId; Versao = $atual.OrganizationVersion; AdministradorDoSistema = $admin })
    if (-not (Confirmar 'E o ambiente de TESTE esperado?')) { throw 'Ambiente nao confirmado. Nada foi alterado.' }

    # ------------------------------------------------------------------
    Etapa 4 '[+] Estado atual (somente leitura)'
    $antes = Ler-Chaves
    Write-Host "Canvas apps em solucoes por padrao: $(Texto $antes.CanvasApps)"
    Write-Host "Cloud flows em solucoes por padrao: $(Texto $antes.CloudFlows)"
    Write-Host "Periodo de carencia dos fluxos (Microsoft liga sozinha depois): $(Texto $antes.PeriodoCarenciaFlows)" -ForegroundColor DarkGray
    Write-Host 'Confira se e o mesmo que aparece no admin center: ambiente > Configuracoes > Produto > Recursos >' -ForegroundColor DarkGray
    Write-Host '"Create new canvas apps and cloud flows in Dataverse solutions".' -ForegroundColor DarkGray
    Salvar 'chaves-antes.csv' @($antes)
    Registrar 'Estado' 'Ler antes' $true "Canvas $(Texto $antes.CanvasApps), Flows $(Texto $antes.CloudFlows)"
    $igualTela = Confirmar 'O admin center mostra os mesmos valores?'
    Registrar 'Estado' 'Leitura igual a tela' $igualTela

    # ------------------------------------------------------------------
    Etapa 5 'Valores desejados (secao 3 do roteiro)'
    $canvas = Pedir-SimNao 'Ativar Canvas Apps em solucoes por padrao?' $antes.CanvasApps
    $flows = Pedir-SimNao 'Ativar Cloud Flows em solucoes por padrao?' $antes.CloudFlows
    Write-Host ''
    Write-Host "Ambiente: $($atual.FriendlyName)"
    Write-Host "Environment ID: $($atual.EnvironmentId)"
    Write-Host "Canvas Apps: $(Texto $antes.CanvasApps) -> $(Texto $canvas)"
    Write-Host "Cloud Flows: $(Texto $antes.CloudFlows) -> $(Texto $flows)"
    if ($canvas -and -not $antes.CanvasApps) { Write-Host 'Lembrete do roteiro: Canvas Apps em solucoes e Preview; avalie antes de ligar em producao.' -ForegroundColor Yellow }
    if ((Read-Host 'Confirmar esses valores? Digite SIM') -cne 'SIM') { throw 'Operacao cancelada. Nada foi alterado.' }

    # ------------------------------------------------------------------
    Etapa 6 'Alterar e conferir'
    $corpo = [ordered]@{}
    if ($canvas -ne $antes.CanvasApps) { $corpo.enablecanvasappsinsolutionsbydefault = $canvas }
    if ($flows -ne $antes.CloudFlows) { $corpo.enableflowsinsolutionbydefault = $flows }
    if (-not $corpo.Count) {
        Write-Host 'Os valores ja estavam assim. Nada foi alterado.' -ForegroundColor Green
        Registrar 'Alteracao' 'PATCH organizations' $true 'Nada a mudar'
    } else {
        Write-Host "Enviando: $($corpo | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
        try {
            $null = Api -Metodo PATCH -Caminho "organizations($($antes.OrganizationId))" -Corpo $corpo
            $depois = Ler-Chaves
            Salvar 'chaves-depois.csv' @($depois)
            Registrar 'Alteracao' 'PATCH organizations' ($depois.CanvasApps -eq $canvas -and $depois.CloudFlows -eq $flows) "Lido depois: Canvas $(Texto $depois.CanvasApps), Flows $(Texto $depois.CloudFlows)"
        } catch {
            $det = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $_.Exception.Message }
            Registrar 'Alteracao' 'PATCH organizations' $false $det
            throw "A alteracao foi recusada: $det"
        }
        Write-Host 'Agora reabra (F5) o admin center: ambiente > Configuracoes > Produto > Recursos.' -ForegroundColor Cyan
        $telaOk = Confirmar 'Os switches de Canvas apps e Cloud flows mostram os novos valores?'
        Registrar 'Alteracao' 'Conferido no admin center' $telaOk
    }

    # ------------------------------------------------------------------
    Etapa 7 '[+] Componente de teste (opcional, secao 6 do roteiro)'
    Write-Host 'Crie em make.powerapps.com, neste ambiente, um app de tela EM BRANCO (Aplicativos > Novo > Tela) ou' -ForegroundColor DarkGray
    Write-Host 'um fluxo da nuvem instantaneo em make.powerautomate.com, e salve com um nome facil (ex.: LAB-AUTO13).' -ForegroundColor DarkGray
    Write-Host 'Templates e formularios do SharePoint nao seguem a configuracao (secao 7 do roteiro).' -ForegroundColor DarkGray
    $nomeTeste = (Read-Host 'Nome do app ou fluxo de teste (Enter para pular)').Trim()
    if ($nomeTeste) {
        $filtro = $nomeTeste.Replace("'", "''")
        # Api -Lista devolve a lista como um objeto so: guardar antes de usar (com @() direto, uma
        # lista vazia virava um item vazio e a busca da solucao quebrava)
        $apps = Api -Lista -Caminho "canvasapps?`$select=canvasappid,name,displayname,createdtime&`$filter=displayname eq '$filtro' or name eq '$filtro'"
        $fluxos = Api -Lista -Caminho "workflows?`$select=workflowid,name,category,createdon&`$filter=name eq '$filtro' and category eq 5"
        $achados = @(
            $apps | Where-Object canvasappid | ForEach-Object { [pscustomobject]@{ Tipo = 'Canvas app'; Nome = $_.displayname; Id = $_.canvasappid; TipoComponente = 300; CriadoEm = $_.createdtime } }
            $fluxos | Where-Object workflowid | ForEach-Object { [pscustomobject]@{ Tipo = 'Cloud flow'; Nome = $_.name; Id = $_.workflowid; TipoComponente = 29; CriadoEm = $_.createdon } }
        )
        $chavesAgora = Ler-Chaves
        Write-Host "Chaves agora: Canvas $(Texto $chavesAgora.CanvasApps), Flows $(Texto $chavesAgora.CloudFlows)."
        Write-Host 'Esperado com a chave On: o componente fica na Common Data Services Default Solution (ou na solucao preferida).' -ForegroundColor DarkGray
        Write-Host 'Esperado com a chave Off: o componente fica fora do Dataverse (o teste nao o encontra) e nao aparece em Solucoes.' -ForegroundColor DarkGray
        if (-not $achados) { Registrar 'Componente' 'Encontrar no Dataverse' (-not ($chavesAgora.CanvasApps -or $chavesAgora.CloudFlows)) "Nada com o nome '$nomeTeste' no Dataverse" }
        foreach ($c in $achados) {
            $comps = Api -Lista -Caminho "solutioncomponents?`$select=solutioncomponentid,_solutionid_value&`$filter=objectid eq $($c.Id) and componenttype eq $($c.TipoComponente)&`$expand=solutionid(`$select=uniquename,friendlyname)"
            # "Active" e "Default" sao solucoes do sistema que contem tudo; a que importa e a outra
            $sols = @($comps | Where-Object { $_.solutionid.uniquename -notin 'Active', 'Default' } | ForEach-Object { "$($_.solutionid.friendlyname) ($($_.solutionid.uniquename))" })
            Write-Host "$($c.Tipo) '$($c.Nome)' (criado em $($c.CriadoEm) UTC): $(if ($sols) { $sols -join '; ' } else { 'em nenhuma solucao' })"
            Registrar 'Componente' "$($c.Tipo) em solucao" ($sols.Count -gt 0) "$($sols -join '; ') · criado $($c.CriadoEm) UTC"
        }
        Salvar 'componente-teste.csv' $achados
        Write-Host 'Remova o componente de teste depois, se nao precisar dele.' -ForegroundColor DarkGray
    }

    # ------------------------------------------------------------------
    Etapa 8 'Voltar ao valor original (opcional)'
    $agora = Ler-Chaves
    if ($agora.CanvasApps -eq $antes.CanvasApps -and $agora.CloudFlows -eq $antes.CloudFlows) {
        Write-Host 'Ja esta igual ao original.' -ForegroundColor DarkGray
    } elseif (Confirmar "Voltar ao original (Canvas $(Texto $antes.CanvasApps), Flows $(Texto $antes.CloudFlows))?") {
        try {
            $null = Api -Metodo PATCH -Caminho "organizations($($antes.OrganizationId))" -Corpo ([ordered]@{
                    enablecanvasappsinsolutionsbydefault = $antes.CanvasApps; enableflowsinsolutionbydefault = $antes.CloudFlows })
            $volta = Ler-Chaves
            Salvar 'chaves-restauradas.csv' @($volta)
            Registrar 'Limpeza' 'Voltar ao original' ($volta.CanvasApps -eq $antes.CanvasApps -and $volta.CloudFlows -eq $antes.CloudFlows) "Canvas $(Texto $volta.CanvasApps), Flows $(Texto $volta.CloudFlows)"
        } catch { Registrar 'Limpeza' 'Voltar ao original' $false $_.Exception.Message }
    } else { Write-Host "Mantido: Canvas $(Texto $agora.CanvasApps), Flows $(Texto $agora.CloudFlows)." }
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
        $resultados | Export-Csv -Path (Join-Path $script:Evid 'resumo.csv') -NoTypeInformation -Encoding utf8
    } else { Write-Host 'Nada foi executado.' }
    Write-Host "Evidencias: $script:Evid" -ForegroundColor DarkGray
    Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Log completo do teste: $LOG_TESTE" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
}
