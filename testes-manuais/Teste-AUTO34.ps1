#Requires -Version 7.0
<#
.SYNOPSIS
    Teste manual do AUTO-34 (SharePoint: excesso de compartilhamento / SharePoint Advanced
    Management) no tenant de demo, rodando o script ORIGINAL sem alteracoes.

.DESCRIPTION
    Ordem do teste:
      1. Modulos (Graph 2.41.2 e Microsoft.Online.SharePoint.PowerShell)
      2. Tenant, conta e prefixo do SharePoint
      3. Login no Graph (codigo de dispositivo) e no SharePoint, UMA vez so: as execucoes
         seguintes reaproveitam as sessoes (o script original confere e reaproveita)
      4. Consultar (somente leitura): compartilhamento do tenant e de cada site, funcoes,
         licencas e relatorios de governanca de acesso a dados existentes
      5. (opcional) Iniciar o relatorio de permissoes (baseline) e consultar pelo ReportId
      6. (opcional) Ligar e desligar a coleta de atividade de "Todos exceto usuarios externos"
      7. (opcional) Mudar o compartilhamento de UM site de teste e voltar ao valor original

    O script original procura um "00-preflight.ps1" na mesma pasta. Ele nao veio junto; pelo
    que o script usa, o preflight so define $TenantId, $AdminUPN e $TenantPrefix. Este roteiro
    gera um preflight minimo com esses tres valores (troque pelo oficial se tiver).

    O original roda NESTE processo (e nao num pwsh separado) para reaproveitar os logins.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Teste-AUTO34.ps1
#>
param(
    [string]$TenantIdEsperado = '4c078364-25b9-4ecd-9ace-b9def6d83e2a',
    [string]$ContaEsperada = 'admin@crm202149.onmicrosoft.com',
    [string]$PrefixoSharePoint = 'crm202149',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO34-Teste')
)

$ErrorActionPreference = 'Stop'
$VERSAO_GRAPH = '2.41.2'
$MODULOS_GRAPH = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Identity.DirectoryManagement',  # Get-MgSubscribedSku
    'Microsoft.Graph.Identity.Governance'            # funcoes administrativas
)
$MODULO_SPO = 'Microsoft.Online.SharePoint.PowerShell'
$VERSAO_MINIMA_SPO = [version]'16.0.25409.0'   # minima exigida pelo script original
$JUSTIFICATIVA = 'Teste manual do Readiness Deploy Accelerator no tenant de demo'
$PASTA_EVIDENCIAS = 'evidencias\AUTO-34-SharePoint-SAM-Oversharing'

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
    param([string]$Acao, [hashtable]$Extras = @{})
    $parametros = @{ Acao = $Acao; SharePointTenantPrefix = $PrefixoSharePoint } + $Extras
    Write-Host "> 34-sharepoint-oversharing.ps1 -Acao $Acao $(($Extras.Keys | ForEach-Object { "-$_" }) -join ' ')" -ForegroundColor DarkGray
    $antes = @(Get-ChildItem -Path (Join-Path $PastaTrabalho $PASTA_EVIDENCIAS) -Directory -ErrorAction SilentlyContinue).Name
    $erro = $null
    try { & $script:Copia @parametros | Out-Host } catch { $erro = $_.Exception.Message }

    $pasta = Get-ChildItem -Path (Join-Path $PastaTrabalho $PASTA_EVIDENCIAS) -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -notin $antes | Sort-Object Name | Select-Object -Last 1
    $caminhoResumo = if ($pasta) { Join-Path $pasta.FullName 'resumo.csv' }
    $resumo = if ($caminhoResumo -and (Test-Path -LiteralPath $caminhoResumo)) { Import-Csv -LiteralPath $caminhoResumo } else { $null }
    $script:resultados.Add([pscustomobject]@{
        Acao        = $Acao
        Sucesso     = (-not $erro)
        QualityGate = $resumo.QualityGate
        ReportId    = $(if ($resumo -and $resumo.PSObject.Properties['ReportIdIniciado']) { $resumo.ReportIdIniciado })
        Erro        = $erro
        Evidencias  = $pasta.FullName
    })
    if ($erro) { Write-Host "  A execucao terminou com erro: $erro" -ForegroundColor Red }
    return $resumo
}

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
            if ($m -eq $MODULO_SPO) {
                Install-Module -Name $m -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
            } else {
                Install-Module -Name $m -RequiredVersion $VERSAO_GRAPH -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
            }
        }
        Write-Host 'Modulos instalados.' -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    Etapa 2 'Tenant, conta e prefixo do SharePoint'
    Write-Host "Tenant esperado:       $TenantIdEsperado"
    Write-Host "Conta esperada:        $ContaEsperada"
    Write-Host "Prefixo do SharePoint: $PrefixoSharePoint  (https://$PrefixoSharePoint-admin.sharepoint.com)"
    if (-not (Confirmar 'Estes sao os dados do tenant de DEMO?')) {
        $TenantIdEsperado = Read-Host 'Tenant ID do tenant de demo'
        $ContaEsperada = Read-Host 'Conta administradora (UPN)'
        $PrefixoSharePoint = Read-Host 'Prefixo do SharePoint (o "xxx" de xxx.sharepoint.com)'
    }

    New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
    $script:Copia = Join-Path $PastaTrabalho '34-sharepoint-oversharing.ps1'
    Copy-Item -Force (Join-Path $PSScriptRoot 'originais\34-sharepoint-oversharing.ps1') $script:Copia
    # Preflight minimo (o oficial nao veio junto): so as tres variaveis que o script usa
    @"
# Gerado por Teste-AUTO34.ps1: substituto minimo do 00-preflight.ps1 do laboratorio.
`$TenantId = '$TenantIdEsperado'
`$AdminUPN = '$ContaEsperada'
`$TenantPrefix = '$PrefixoSharePoint'
"@ | Set-Content -Path (Join-Path $PastaTrabalho '00-preflight.ps1') -Encoding utf8
    Write-Host "Script original e preflight minimo em $PastaTrabalho (as evidencias ficam ao lado)."

    # ------------------------------------------------------------------
    Etapa 3 'Logins (uma vez so)'
    # Mesma versao do Graph para todos os submodulos, antes do modulo do SharePoint
    foreach ($m in $MODULOS_GRAPH) { Import-Module $m -RequiredVersion $VERSAO_GRAPH -ErrorAction Stop }
    Write-Host 'Microsoft Graph: abra https://microsoft.com/devicelogin, digite o codigo que vai aparecer e entre com' -ForegroundColor Cyan
    Write-Host "$ContaEsperada (de preferencia numa janela anonima/InPrivate)." -ForegroundColor Cyan
    Write-Host 'Se a tela parecer parada, aperte Esc: selecionar texto na janela pausa a saida.' -ForegroundColor DarkGray
    Connect-MgGraph -TenantId $TenantIdEsperado -Scopes 'User.Read.All', 'Organization.Read.All', 'RoleManagement.Read.Directory' `
        -ContextScope Process -UseDeviceCode -NoWelcome -ErrorAction Stop
    Write-Host "Graph conectado como $((Get-MgContext).Account)." -ForegroundColor Green
    Write-Host ''
    Write-Host 'O login do SharePoint e feito pelo proprio script na primeira execucao (abre o navegador).' -ForegroundColor Cyan
    Write-Host "Use somente $ContaEsperada." -ForegroundColor Cyan

    # ------------------------------------------------------------------
    Etapa 4 'Consultar (somente leitura)'
    Write-Host 'Le o compartilhamento do tenant e de cada site (sem OneDrive), funcoes, licencas e'
    Write-Host 'relatorios de governanca de acesso a dados ja existentes. Nao altera nada.'
    Write-Host 'Consultas de relatorio podem falhar sem licenca do SharePoint Advanced Management:' -ForegroundColor DarkGray
    Write-Host 'nesse caso ficam registradas como "Falha" em dag-consultas.csv, sem interromper.' -ForegroundColor DarkGray
    $consulta = Rodar-Original -Acao 'Consultar'
    if (-not $consulta -or $consulta.QualityGate -eq 'Falha') { throw 'A consulta nao foi concluida; as acoes opcionais foram puladas.' }
    Write-Host ''
    Write-Host "Sites lidos: $($consulta.SitesEnumerados) · com erro: $($consulta.SitesComErro) · relatorios existentes: $($consulta.RelatoriosEncontrados)"
    Write-Host "Licenciamento: $($consulta.AvaliacaoLicenciamento)"

    # ------------------------------------------------------------------
    Etapa 5 'Relatorio de permissoes (opcional)'
    Write-Host 'Pede ao SharePoint um relatorio de quem tem permissao em cada site (processamento assincrono,'
    Write-Host 'pode levar horas). Nao muda permissoes. Exige SharePoint Advanced Management (vem com o Copilot).'
    if (Confirmar 'Iniciar o relatorio de permissoes?') {
        $r = Rodar-Original -Acao 'IniciarBaselinePermissoes' -Extras @{ ConfirmarAlteracao = $true; Justificativa = $JUSTIFICATIVA }
        if ($r -and $r.ReportIdIniciado) {
            Write-Host "ReportId: $($r.ReportIdIniciado)" -ForegroundColor Green
            if (Confirmar 'Consultar o status do relatorio agora?') {
                $null = Rodar-Original -Acao 'ConsultarRelatorio' -Extras @{ ReportId = [guid]$r.ReportIdIniciado }
            }
            Write-Host 'Para exportar depois que concluir:' -ForegroundColor DarkGray
            Write-Host "  & '$($script:Copia)' -Acao ExportarRelatorio -SharePointTenantPrefix $PrefixoSharePoint -ReportId $($r.ReportIdIniciado)" -ForegroundColor DarkGray
        }
    }

    # ------------------------------------------------------------------
    Etapa 6 'Coleta de atividade de "Todos exceto usuarios externos" (opcional)'
    Write-Host 'Liga a coleta de auditoria usada nos relatorios de atividade (precisa de ~24 h de coleta antes'
    Write-Host 'do relatorio). Nao muda permissoes nem conteudo. O roteiro pergunta depois se quer desligar.'
    if (Confirmar 'Ligar a coleta (sites e itens)?') {
        $null = Rodar-Original -Acao 'HabilitarColeta' -Extras @{ EscopoEEEU = 'Ambos'; ConfirmarAlteracao = $true; Justificativa = $JUSTIFICATIVA }
        if (Confirmar 'Desligar a coleta de novo (responda N para deixar coletando)?') {
            $null = Rodar-Original -Acao 'DesabilitarColeta' -Extras @{ EscopoEEEU = 'Ambos'; ConfirmarAlteracao = $true; Justificativa = $JUSTIFICATIVA }
        }
    }

    # ------------------------------------------------------------------
    Etapa 7 'Compartilhamento de UM site de teste (opcional)'
    Write-Host 'Muda o compartilhamento externo de um site e depois volta ao valor original.'
    Write-Host 'Use um site de TESTE: enquanto estiver mudado, links e convidados podem parar de funcionar.' -ForegroundColor Yellow
    $site = (Read-Host 'URL do site de teste (Enter para pular)').Trim()
    if ($site) {
        $original = [string](Get-SPOSite -Identity $site -ErrorAction Stop).SharingCapability
        Write-Host "Hoje: $original"
        $novo = if ($original -eq 'Disabled') { 'ExistingExternalUserSharingOnly' } else { 'Disabled' }
        if (Confirmar "Mudar para $novo e depois voltar para $original?") {
            $null = Rodar-Original -Acao 'ConfigurarCompartilhamentoSite' -Extras @{ SiteUrl = $site; SharingCapability = $novo; ConfirmarAlteracao = $true; Justificativa = $JUSTIFICATIVA }
            $null = Rodar-Original -Acao 'ConfigurarCompartilhamentoSite' -Extras @{ SiteUrl = $site; SharingCapability = $original; ConfirmarAlteracao = $true; Justificativa = "$JUSTIFICATIVA (restaurar)" }
        }
    }
} catch {
    Write-Host ''
    Write-Host "PAROU: $($_.Exception.Message)" -ForegroundColor Red
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
}
