#Requires -Version 7.0
<#
.SYNOPSIS
    Teste manual do AUTO-11 (configuracoes base do Dataverse: idiomas, fusos horarios dos usuarios,
    equipes e caixas de correio) num ambiente de demo, seguindo o roteiro em Word do item
    (originais/11-dataverse-configuracoes-roteiro.docx).

.DESCRIPTION
    O item nao tem script pronto: o roteiro traz comandos soltos para copiar e colar. Este teste
    roda esses comandos (mesmas chamadas da Web API do Dataverse, com o token do Az.Accounts) na
    ordem do roteiro, e em cada alteracao volta ao estado original no fim.

    Acrescimos ao roteiro (marcados com [+] na tela):
      - idiomas: le os idiomas JA instalados e os DISPONIVEIS no ambiente (RetrieveProvisionedLanguages
        e RetrieveAvailableLanguages, citados nas fontes do roteiro) em vez de so uma lista fixa;
      - equipes: lista as unidades de negocio para escolher (o roteiro pede o GUID de cabeca);
      - cada alteracao e desfeita no fim (fuso, equipe de teste, caixa de correio);
      - evidencias em CSV de cada leitura.

    Ordem do teste:
      1. Modulo Az.Accounts
      2. Ambiente (URL do Dataverse) e login (codigo de dispositivo)
      3. Conferir a organizacao (somente leitura)
      4. Idiomas: instalados e disponiveis; (opcional) instalar um idioma
      5. Fusos: usuarios e fusos; (opcional) mudar o fuso de UM usuario e voltar
      6. Equipes: equipes e unidades de negocio; (opcional) criar uma equipe de teste e apagar
      7. Caixas de correio: inventario; (opcional) mudar entrada/saida de UMA caixa e voltar

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Teste-AUTO11.ps1
#>
param(
    [string]$TenantIdEsperado = '4c078364-25b9-4ecd-9ace-b9def6d83e2a',
    [string]$ContaEsperada = 'admin@crm202149.onmicrosoft.com',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO11-Teste')
)

$ErrorActionPreference = 'Stop'
$NOME_EQUIPE_TESTE = 'LAB-AUTO11-Equipe-Teste'

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
    <# Mesmas chamadas do roteiro (Invoke-RestMethod na Web API v9.2); segue @odata.nextLink nas listas. #>
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

New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$script:Evid = Join-Path $PastaTrabalho "evidencias\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Force -Path $script:Evid | Out-Null
$LOG_TESTE = Join-Path $PastaTrabalho "teste-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -LiteralPath $LOG_TESTE -Force | Out-Null

try {
    # ------------------------------------------------------------------
    Etapa 1 'Modulo Az.Accounts (usado pelo roteiro para pegar o token)'
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
    Etapa 3 'Conferir a organizacao (somente leitura)'
    $orgInfo = @((Api -Caminho 'organizations?$select=name,organizationid,languagecode').value)[0]
    Write-Host "Organizacao: $($orgInfo.name)  ·  ID $($orgInfo.organizationid)  ·  idioma base $($orgInfo.languagecode)"
    Salvar 'organizacao.csv' @([pscustomobject]@{ Url = $script:Org; Nome = $orgInfo.name; OrganizationId = $orgInfo.organizationid; IdiomaBase = $orgInfo.languagecode })
    Registrar 'Organizacao' 'Consultar' $true "$($orgInfo.name), idioma base $($orgInfo.languagecode)"
    if (-not (Confirmar 'E a organizacao esperada (ambiente de TESTE)?')) { throw 'Organizacao nao confirmada. Nada foi alterado.' }

    # ------------------------------------------------------------------
    Etapa 4 'Idiomas'
    $instalados = @()
    $disponiveis = @()
    try {
        $instalados = @((Api -Caminho 'RetrieveProvisionedLanguages()').RetrieveProvisionedLanguages)
        $disponiveis = @((Api -Caminho 'RetrieveAvailableLanguages()').LocaleIds)
        Write-Host "[+] Instalados: $($instalados -join ', ')"
        Write-Host "[+] Disponiveis para instalar: $(@($disponiveis | Where-Object { $_ -notin $instalados }) -join ', ')"
        Registrar 'Idiomas' 'Consultar instalados e disponiveis' $true "$($instalados.Count) instalados, $($disponiveis.Count) disponiveis"
    } catch { Registrar 'Idiomas' 'Consultar instalados e disponiveis' $false $_.Exception.Message }
    Salvar 'idiomas.csv' @($disponiveis | ForEach-Object { [pscustomobject]@{ LCID = $_; Instalado = ($_ -in $instalados) } })
    $aprovados = @(
        [pscustomobject]@{ LCID = 1033; Idioma = 'Ingles (Estados Unidos)' }, [pscustomobject]@{ LCID = 1036; Idioma = 'Frances (Franca)' },
        [pscustomobject]@{ LCID = 1031; Idioma = 'Alemao (Alemanha)' }, [pscustomobject]@{ LCID = 1040; Idioma = 'Italiano (Italia)' },
        [pscustomobject]@{ LCID = 1046; Idioma = 'Portugues (Brasil)' }, [pscustomobject]@{ LCID = 3082; Idioma = 'Espanhol (Espanha)' })
    Write-Host 'Lista aprovada do roteiro:'
    $aprovados | ForEach-Object { "  $($_.LCID)  $($_.Idioma)$(if ($_.LCID -in $instalados) { '  (ja instalado)' })" } | Out-Host
    Write-Host 'Instalar um idioma e assincrono (pode levar ate 1 hora) e nao muda o idioma base.' -ForegroundColor DarkGray
    $lcid = (Read-Host 'LCID para instalar (Enter para pular)').Trim()
    if ($lcid) {
        $escolha = $aprovados | Where-Object { $_.LCID -eq [int]$lcid }
        if (-not $escolha) { Registrar 'Idiomas' "Instalar $lcid" $false 'LCID fora da lista aprovada do roteiro' }
        elseif ([int]$lcid -in $instalados) { Registrar 'Idiomas' "Instalar $lcid" $true 'Ja estava instalado; nada foi feito' }
        elseif (Confirmar "Instalar $($escolha.Idioma) [$lcid]?") {
            try {
                $null = Api -Metodo POST -Caminho 'ProvisionLanguageAsync' -Corpo @{ Language = [int]$lcid }
                Registrar 'Idiomas' "Instalar $lcid" $true 'Pedido enviado (assincrono). Confira mais tarde nos idiomas do ambiente.'
            } catch { Registrar 'Idiomas' "Instalar $lcid" $false $_.Exception.Message }
        }
    }

    # ------------------------------------------------------------------
    Etapa 5 'Fusos horarios dos usuarios'
    $settings = Api -Lista -Caminho 'usersettingscollection?$select=systemuserid,timezonecode'
    $users = Api -Lista -Caminho 'systemusers?$select=systemuserid,fullname,internalemailaddress,isdisabled'
    $zonas = Api -Lista -Caminho 'timezonedefinitions?$select=timezonecode,userinterfacename,standardname&$orderby=userinterfacename'
    $inventario = @(foreach ($s in $settings) {
            $u = $users | Where-Object systemuserid -eq $s.systemuserid | Select-Object -First 1
            $z = $zonas | Where-Object timezonecode -eq $s.timezonecode | Select-Object -First 1
            [pscustomobject]@{ Nome = $u.fullname; Email = $u.internalemailaddress; Desabilitado = $u.isdisabled; UserId = $s.systemuserid
                TimeZoneCode = $s.timezonecode; Fuso = $z.userinterfacename }
        })
    $ativos = @($inventario | Where-Object { $_.Email -and -not $_.Desabilitado } | Sort-Object Nome)
    $ativos | Select-Object Nome, Email, TimeZoneCode, Fuso | Format-Table -AutoSize | Out-Host
    Salvar 'usuarios-fuso.csv' $inventario
    Salvar 'fusos.csv' $zonas
    Registrar 'Fusos' 'Consultar' $true "$($inventario.Count) configuracoes de usuario, $($ativos.Count) usuarios ativos com e-mail, $($zonas.Count) fusos"
    $emailUsuario = (Read-Host 'E-mail do usuario para mudar o fuso e voltar (Enter para pular)').Trim()
    if ($emailUsuario) {
        $alvo = $ativos | Where-Object { $_.Email -eq $emailUsuario } | Select-Object -First 1
        if (-not $alvo) { Registrar 'Fusos' 'Alterar' $false "Usuario $emailUsuario nao encontrado" }
        else {
            $brasilia = $zonas | Where-Object { $_.standardname -eq 'E. South America Standard Time' } | Select-Object -First 1
            $novo = if ($brasilia -and $brasilia.timezonecode -ne $alvo.TimeZoneCode) { $brasilia } else { $zonas | Where-Object timezonecode -eq 35 | Select-Object -First 1 }
            if (Confirmar "Mudar $($alvo.Nome) de [$($alvo.TimeZoneCode)] $($alvo.Fuso) para [$($novo.timezonecode)] $($novo.userinterfacename) e depois voltar?") {
                try {
                    $null = Api -Metodo PATCH -Caminho "usersettingscollection($($alvo.UserId))" -Corpo @{ timezonecode = [int]$novo.timezonecode }
                    $lido = Api -Caminho "usersettingscollection($($alvo.UserId))?`$select=systemuserid,timezonecode"
                    Registrar 'Fusos' 'Alterar' ($lido.timezonecode -eq $novo.timezonecode) "Lido depois: $($lido.timezonecode)"
                    $null = Api -Metodo PATCH -Caminho "usersettingscollection($($alvo.UserId))" -Corpo @{ timezonecode = [int]$alvo.TimeZoneCode }
                    $lido = Api -Caminho "usersettingscollection($($alvo.UserId))?`$select=systemuserid,timezonecode"
                    Registrar 'Fusos' 'Voltar ao original' ($lido.timezonecode -eq $alvo.TimeZoneCode) "Lido depois: $($lido.timezonecode)"
                } catch { Registrar 'Fusos' 'Alterar' $false $_.Exception.Message }
            }
        }
    }

    # ------------------------------------------------------------------
    Etapa 6 'Equipes'
    $teams = Api -Lista -Caminho 'teams?$select=teamid,name,teamtype,membershiptype,azureactivedirectoryobjectid,_businessunitid_value&$orderby=name'
    $bus = Api -Lista -Caminho 'businessunits?$select=businessunitid,name,_parentbusinessunitid_value&$orderby=name'
    $teams | Select-Object name, teamtype, membershiptype, azureactivedirectoryobjectid | Format-Table -AutoSize | Out-Host
    Write-Host '[+] Unidades de negocio:'
    $bus | Select-Object name, businessunitid, @{ n = 'Raiz'; e = { -not $_._parentbusinessunitid_value } } | Format-Table -AutoSize | Out-Host
    Salvar 'equipes.csv' $teams
    Salvar 'unidades-negocio.csv' $bus
    Registrar 'Equipes' 'Consultar' $true "$($teams.Count) equipes, $($bus.Count) unidades de negocio"
    $raiz = $bus | Where-Object { -not $_._parentbusinessunitid_value } | Select-Object -First 1
    if ($raiz -and (Confirmar "Criar a equipe proprietaria '$NOME_EQUIPE_TESTE' na unidade '$($raiz.name)' e apagar logo depois?")) {
        try {
            $existente = $teams | Where-Object name -eq $NOME_EQUIPE_TESTE | Select-Object -First 1
            if ($existente) { Registrar 'Equipes' 'Criar' $true 'Ja existia; nao foi criada de novo' ; $id = $existente.teamid }
            else {
                $null = Api -Metodo POST -Caminho 'teams' -Corpo @{ name = $NOME_EQUIPE_TESTE; teamtype = 0; 'businessunitid@odata.bind' = "/businessunits($($raiz.businessunitid))" }
                $criada = @((Api -Caminho "teams?`$select=teamid,name,teamtype&`$filter=name eq '$NOME_EQUIPE_TESTE'").value)[0]
                Registrar 'Equipes' 'Criar' ($null -ne $criada) "teamtype $($criada.teamtype)"
                $id = $criada.teamid
            }
            if ($id -and (Confirmar 'Confira no ambiente, se quiser. Apagar a equipe de teste agora?')) {
                $null = Api -Metodo DELETE -Caminho "teams($id)"
                $restante = @((Api -Caminho "teams?`$select=teamid&`$filter=name eq '$NOME_EQUIPE_TESTE'").value)
                Registrar 'Equipes' 'Apagar a equipe de teste' ($restante.Count -eq 0)
            }
        } catch { Registrar 'Equipes' 'Criar' $false $_.Exception.Message }
    }

    # ------------------------------------------------------------------
    Etapa 7 'Caixas de correio'
    $mailboxes = Api -Lista -Caminho 'mailboxes?$select=mailboxid,name,emailaddress,enabledforincomingemail,enabledforoutgoingemail,emailrouteraccessapproval,incomingemailstatus,outgoingemailstatus'
    $mailboxes | Select-Object name, emailaddress, enabledforincomingemail, enabledforoutgoingemail, emailrouteraccessapproval, incomingemailstatus, outgoingemailstatus |
        Format-Table -AutoSize | Out-Host
    Salvar 'caixas-correio.csv' $mailboxes
    Registrar 'Caixas de correio' 'Consultar' $true "$($mailboxes.Count) caixas"
    $emailCaixa = (Read-Host 'E-mail da caixa para inverter entrada/saida e voltar (Enter para pular)').Trim()
    if ($emailCaixa) {
        $cx = $mailboxes | Where-Object { $_.emailaddress -eq $emailCaixa } | Select-Object -First 1
        if (-not $cx) { Registrar 'Caixas de correio' 'Alterar' $false "Caixa $emailCaixa nao encontrada" }
        elseif (Confirmar "Inverter entrada ($($cx.enabledforincomingemail)) e saida ($($cx.enabledforoutgoingemail)) de $emailCaixa e depois voltar?") {
            try {
                $null = Api -Metodo PATCH -Caminho "mailboxes($($cx.mailboxid))" -Corpo @{ enabledforincomingemail = -not $cx.enabledforincomingemail; enabledforoutgoingemail = -not $cx.enabledforoutgoingemail }
                $lido = Api -Caminho "mailboxes($($cx.mailboxid))?`$select=enabledforincomingemail,enabledforoutgoingemail"
                Registrar 'Caixas de correio' 'Alterar' ($lido.enabledforincomingemail -ne $cx.enabledforincomingemail -and $lido.enabledforoutgoingemail -ne $cx.enabledforoutgoingemail) "Lido depois: entrada $($lido.enabledforincomingemail), saida $($lido.enabledforoutgoingemail)"
                $null = Api -Metodo PATCH -Caminho "mailboxes($($cx.mailboxid))" -Corpo @{ enabledforincomingemail = $cx.enabledforincomingemail; enabledforoutgoingemail = $cx.enabledforoutgoingemail }
                $lido = Api -Caminho "mailboxes($($cx.mailboxid))?`$select=enabledforincomingemail,enabledforoutgoingemail"
                Registrar 'Caixas de correio' 'Voltar ao original' ($lido.enabledforincomingemail -eq $cx.enabledforincomingemail -and $lido.enabledforoutgoingemail -eq $cx.enabledforoutgoingemail)
            } catch { Registrar 'Caixas de correio' 'Alterar' $false $_.Exception.Message }
        }
    }
    Write-Host 'Lembrete do roteiro: ligar entrada/saida nao substitui aprovar o endereco, o perfil do servidor de e-mail e o teste da caixa no Power Platform admin center.' -ForegroundColor DarkGray
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
