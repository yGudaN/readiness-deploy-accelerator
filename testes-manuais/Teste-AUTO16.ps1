#Requires -Version 7.0
<#
.SYNOPSIS
    Teste manual do AUTO-16 (Restricted Content Discovery: tirar um site da descoberta na pesquisa e
    no Copilot) no tenant de demo, rodando o script ORIGINAL (16-rcd-sharepoint.ps1) sem alteracoes.

.DESCRIPTION
    Havia dois materiais do item: o script (base deste teste) e um roteiro em Word
    (originais/16-rcd-sharepoint-roteiro.docx). Do roteiro vem a etapa 5: a lista de todos os sites
    com o estado do recurso, que o script nao tem.

    Ordem do teste:
      1. Modulos (Graph 2.41.2 e Microsoft.Online.SharePoint.PowerShell)
      2. Tenant, conta e prefixo do SharePoint
      3. Login no Graph (codigo de dispositivo). O login do SharePoint e feito pelo proprio
         script na primeira execucao (navegador padrao); as seguintes reaproveitam as sessoes
      4. Consultar (somente leitura) no site raiz
      5. Lista de sites com o estado do recurso (comando do roteiro em Word)
      6. (opcional) Ligar e depois desligar o recurso em UM site de teste (volta ao estado original)

    O recurso exige o SharePoint Advanced Management. Sem ele (caso do tenant de demo, visto no item 34),
    espera-se que a consulta funcione e que ligar seja recusado: o objetivo e ver COMO o SharePoint recusa.

    O script original procura um "00-preflight.ps1" na mesma pasta: este roteiro gera um minimo
    com $TenantId e $AdminUPN. O original roda NESTE processo para reaproveitar os logins.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Teste-AUTO16.ps1
#>
param(
    [string]$TenantIdEsperado = '4c078364-25b9-4ecd-9ace-b9def6d83e2a',
    [string]$ContaEsperada = 'admin@crm202149.onmicrosoft.com',
    [string]$PrefixoSharePoint = 'crm202149',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO16-Teste')
)

$ErrorActionPreference = 'Stop'
$VERSAO_GRAPH = '2.41.2'
$MODULOS_GRAPH = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'Microsoft.Graph.Identity.Governance'
)
$MODULO_SPO = 'Microsoft.Online.SharePoint.PowerShell'
$VERSAO_MINIMA_SPO = [version]'16.0.25409.0'
$JUSTIFICATIVA = 'Teste manual do Readiness Deploy Accelerator no tenant de demo'
$PASTA_EVIDENCIAS = 'evidencias\AUTO-16-RCD-SharePoint'

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

function Rodar-Original {
    <# Executa o original neste processo; devolve o resumo.csv da execucao (ou $null). #>
    param([string]$Site, [string]$Acao, [string]$Motivo = '')
    $parametros = @{ SiteUrl = $Site; Acao = $Acao }
    if ($Acao -ne 'Consultar') { $parametros.ConfirmarAlteracao = $true; $parametros.Justificativa = $Motivo }
    Write-Host ''
    Write-Host "> 16-rcd-sharepoint.ps1 -SiteUrl $Site -Acao $Acao" -ForegroundColor DarkGray
    $antes = @(Get-ChildItem -Path (Join-Path $PastaTrabalho $PASTA_EVIDENCIAS) -Directory -ErrorAction SilentlyContinue).Name
    $erro = $null
    try { & $script:Copia @parametros | Out-Host } catch { $erro = $_.Exception.Message }

    $pasta = Get-ChildItem -Path (Join-Path $PastaTrabalho $PASTA_EVIDENCIAS) -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -notin $antes | Sort-Object Name | Select-Object -Last 1
    $caminhoResumo = if ($pasta) { Join-Path $pasta.FullName 'resumo.csv' }
    $resumo = if ($caminhoResumo -and (Test-Path -LiteralPath $caminhoResumo)) { Import-Csv -LiteralPath $caminhoResumo } else { $null }
    $script:resultados.Add([pscustomobject]@{
            Acao               = $Acao
            Site               = $Site
            Sucesso            = (-not $erro)
            EstadoAntes        = $resumo.EstadoAntes
            EstadoDepois       = $resumo.EstadoDepois
            AlteracaoExecutada = $resumo.AlteracaoExecutada
            ValidacaoAprovada  = $resumo.ValidacaoAprovada
            Erro               = $(if ($erro) { $erro } elseif ($resumo -and $resumo.PSObject.Properties['Erro']) { $resumo.Erro })
            Evidencias         = $pasta.FullName
        })
    if ($erro) { Write-Host "  A execucao terminou com erro: $erro" -ForegroundColor Red }
    return $resumo
}

New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$LOG_TESTE = Join-Path $PastaTrabalho "teste-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -LiteralPath $LOG_TESTE -Force | Out-Null

try {
    # ------------------------------------------------------------------
    Etapa 1 'Modulos'
    $faltando = @($MODULOS_GRAPH | Where-Object { -not (Get-Module -ListAvailable -Name $_ | Where-Object Version -eq $VERSAO_GRAPH) })
    $spo = Get-Module -ListAvailable -Name $MODULO_SPO | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $spo -or $spo.Version -lt $VERSAO_MINIMA_SPO) { $faltando += $MODULO_SPO }
    if ($faltando.Count -eq 0) {
        Write-Host "Modulos ja instalados (Graph $VERSAO_GRAPH, SharePoint $($spo.Version))." -ForegroundColor Green
    } else {
        Write-Host "Faltam: $($faltando -join ', ')"
        Write-Host 'Sao instalados so para o seu usuario (Install-Module -Scope CurrentUser), da PowerShell Gallery.' -ForegroundColor DarkGray
        if (-not (Confirmar 'Instalar agora?')) { throw 'Modulos nao instalados. Nada foi alterado.' }
        foreach ($m in $faltando) {
            Write-Host "Instalando $m..."
            if ($m -eq $MODULO_SPO) { Install-Module -Name $m -Scope CurrentUser -Repository PSGallery -Force -AllowClobber }
            else { Install-Module -Name $m -RequiredVersion $VERSAO_GRAPH -Scope CurrentUser -Repository PSGallery -Force -AllowClobber }
        }
        Write-Host 'Modulos instalados.' -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    Etapa 2 'Tenant, conta e prefixo do SharePoint'
    Write-Host "Tenant esperado:       $TenantIdEsperado"
    Write-Host "Conta esperada:        $ContaEsperada"
    Write-Host "Prefixo do SharePoint: $PrefixoSharePoint  (https://$PrefixoSharePoint.sharepoint.com)"
    if (-not (Confirmar 'Estes sao os dados do tenant de DEMO?')) {
        $TenantIdEsperado = Read-Host 'Tenant ID do tenant de demo'
        $ContaEsperada = Read-Host 'Conta administradora (UPN)'
        $PrefixoSharePoint = Read-Host 'Prefixo do SharePoint (o "xxx" de xxx.sharepoint.com)'
    }
    $siteRaiz = "https://$PrefixoSharePoint.sharepoint.com"
    $script:Copia = Join-Path $PastaTrabalho '16-rcd-sharepoint.ps1'
    Copy-Item -Force (Join-Path $PSScriptRoot 'originais\16-rcd-sharepoint.ps1') $script:Copia
    @"
# Gerado por Teste-AUTO16.ps1: substituto minimo do 00-preflight.ps1 do laboratorio.
`$TenantId = '$TenantIdEsperado'
`$AdminUPN = '$ContaEsperada'
"@ | Set-Content -Path (Join-Path $PastaTrabalho '00-preflight.ps1') -Encoding utf8
    Write-Host "Script original e preflight minimo em $PastaTrabalho (as evidencias ficam ao lado)."

    # ------------------------------------------------------------------
    Etapa 3 'Login no Graph'
    foreach ($m in $MODULOS_GRAPH) { Import-Module $m -RequiredVersion $VERSAO_GRAPH -ErrorAction Stop }
    Write-Host 'Microsoft Graph: abra https://microsoft.com/devicelogin, digite o codigo que vai aparecer e entre com' -ForegroundColor Cyan
    Write-Host "$ContaEsperada (de preferencia numa janela anonima/InPrivate)." -ForegroundColor Cyan
    Write-Host 'Se a tela parecer parada, aperte Esc: selecionar texto na janela pausa a saida.' -ForegroundColor DarkGray
    Connect-MgGraph -TenantId $TenantIdEsperado -Scopes 'User.Read.All', 'Organization.Read.All', 'RoleManagement.Read.Directory' `
        -ContextScope Process -UseDeviceCode -NoWelcome -ErrorAction Stop
    Write-Host "Graph conectado como $((Get-MgContext).Account). O script original vai reaproveitar esse login." -ForegroundColor Green
    Write-Host ''
    Write-Host 'O login do SharePoint e feito pelo proprio script na primeira execucao (abre o navegador padrao).' -ForegroundColor Cyan
    Write-Host "Use somente $ContaEsperada." -ForegroundColor Cyan

    # ------------------------------------------------------------------
    Etapa 4 'Consultar (somente leitura) no site raiz'
    $consulta = Rodar-Original -Site $siteRaiz -Acao 'Consultar'
    if (-not $consulta -or $consulta.ValidacaoAprovada -ne 'True') { throw 'A consulta nao foi concluida; as etapas seguintes foram puladas.' }
    Write-Host "Site raiz: $($consulta.EstadoDepois)"

    # ------------------------------------------------------------------
    Etapa 5 'Lista de sites com o estado do recurso (do roteiro em Word)'
    $sites = @(Get-SPOSite -Limit All -ErrorAction Stop | Where-Object { $_.Url -notlike '*-my.sharepoint.com*' } |
            Select-Object Title, Url, RestrictContentOrgWideSearch | Sort-Object Title)
    $sites | Format-Table -AutoSize | Out-Host
    $arquivoSites = Join-Path $PastaTrabalho "sites-rcd-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    $sites | Export-Csv -Path $arquivoSites -NoTypeInformation -Encoding utf8
    Write-Host "$($sites.Count) sites; com o recurso ligado: $(@($sites | Where-Object RestrictContentOrgWideSearch).Count). Lista salva em $arquivoSites" -ForegroundColor Green

    # ------------------------------------------------------------------
    Etapa 6 'Ligar e desligar em UM site de teste (opcional)'
    Write-Host 'Liga o recurso no site (ele some da pesquisa da organizacao e do Copilot para quem nao usa o site;'
    Write-Host 'as permissoes NAO mudam) e depois volta ao estado original. A propagacao na pesquisa demora.'
    Write-Host 'Sem SharePoint Advanced Management, espera-se que o SharePoint recuse: anote a mensagem.' -ForegroundColor Yellow
    $site = (Read-Host 'URL do site de teste (Enter para pular)').Trim().TrimEnd('/')
    if ($site) {
        $estadoAntes = $sites | Where-Object { $_.Url.TrimEnd('/') -eq $site } | Select-Object -First 1
        $estavaLigado = $estadoAntes -and $estadoAntes.RestrictContentOrgWideSearch -eq $true
        $primeira = if ($estavaLigado) { 'Desabilitar' } else { 'Habilitar' }
        $volta = if ($estavaLigado) { 'Habilitar' } else { 'Desabilitar' }
        if (Confirmar "Hoje esta $(if ($estavaLigado) { 'LIGADO' } else { 'desligado' }). Rodar $primeira e depois $volta?") {
            $r = Rodar-Original -Site $site -Acao $primeira -Motivo $JUSTIFICATIVA
            Write-Host 'Rodando de novo para conferir que nao altera o que ja esta no estado pedido.'
            $null = Rodar-Original -Site $site -Acao $primeira -Motivo $JUSTIFICATIVA
            if ($r -and $r.AlteracaoExecutada -eq 'True') {
                $null = Rodar-Original -Site $site -Acao $volta -Motivo "$JUSTIFICATIVA (restaurar)"
            }
        }
    }
} catch {
    Write-Host ''
    Write-Host "PAROU: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Onde: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
} finally {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host ' RESUMO DAS EXECUCOES' -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    if ($resultados.Count) { $resultados | Format-List | Out-Host } else { Write-Host 'Nenhuma execucao do script original.' }
    if ($resultados.Count) {
        $arquivo = Join-Path $PastaTrabalho "resumo-teste-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $resultados | Export-Csv -Path $arquivo -NoTypeInformation -Encoding utf8
        Write-Host "Resumo salvo em $arquivo" -ForegroundColor DarkGray
    }
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Log completo do teste: $LOG_TESTE" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
}
