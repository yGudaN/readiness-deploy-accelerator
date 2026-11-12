#Requires -Version 7.0
<#
.SYNOPSIS
    Teste manual do AUTO-31 (auditoria unificada e eventos do Copilot) no tenant de demo,
    rodando o script ORIGINAL sem alteracoes.

.DESCRIPTION
    Ordem do teste:
      1. Modulos (Graph 2.41.2 e ExchangeOnlineManagement)
      2. Tenant e conta
      3. Logins, UMA vez so: Graph (codigo de dispositivo), Security & Compliance e Exchange Online
      4. Consultar (somente leitura): auditoria ligada ou nao, politicas de retencao de auditoria,
         licencas da conta e eventos do Copilot dos ultimos 7 dias
      5. (opcional) Ligar a auditoria, se estiver desligada
      6. (opcional) Criar a politica de retencao de auditoria do Copilot e, se quiser, remover depois
      7. (opcional) Desligar e religar a auditoria (so em tenant de teste)

    O script original procura um "00-preflight.ps1" na mesma pasta. Ele nao veio junto; pelo
    que o script usa, o preflight so define $TenantId e $AdminUPN. Este roteiro gera um
    preflight minimo com esses dois valores (troque pelo oficial se tiver).

    Ordem dos logins: Security & Compliance ANTES do Exchange Online. As duas sessoes tem o
    comando Get-AdminAuditLogConfig, e o que vale e o da ultima conectada. Pela documentacao
    da Microsoft, no Security & Compliance ele sempre diz que a auditoria esta desligada; o
    valor certo vem do Exchange Online. O roteiro confere isso antes de rodar o original.

    O original roda NESTE processo (e nao num pwsh separado) para reaproveitar os logins.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Teste-AUTO31.ps1
#>
param(
    [string]$TenantIdEsperado = '4c078364-25b9-4ecd-9ace-b9def6d83e2a',
    [string]$ContaEsperada = 'admin@crm202149.onmicrosoft.com',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO31-Teste')
)

$ErrorActionPreference = 'Stop'
$VERSAO_GRAPH = '2.41.2'
$MODULOS_GRAPH = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',                         # Get-MgUser
    'Microsoft.Graph.Identity.DirectoryManagement'   # Get-MgSubscribedSku
)
$MODULO_EXO = 'ExchangeOnlineManagement'
$VERSAO_MINIMA_EXO = [version]'3.2.0'   # Get-ConnectionInformation e sessoes REST
$NOME_POLITICA = 'LAB-AUTO31-Retencao-Copilot'
$PASTA_EVIDENCIAS = 'evidencias\AUTO-31-Auditoria-Copilot-UAL'

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
    $parametros = @{ Acao = $Acao } + $Extras
    Write-Host "> 31-auditoria-copilot-ual.ps1 -Acao $Acao $(($Extras.Keys | ForEach-Object { "-$_" }) -join ' ')" -ForegroundColor DarkGray
    $antes = @(Get-ChildItem -Path (Join-Path $PastaTrabalho $PASTA_EVIDENCIAS) -Directory -ErrorAction SilentlyContinue).Name
    $erro = $null
    try { & $script:Copia @parametros | Out-Host } catch { $erro = $_.Exception.Message }

    $pasta = Get-ChildItem -Path (Join-Path $PastaTrabalho $PASTA_EVIDENCIAS) -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -notin $antes | Sort-Object Name | Select-Object -Last 1
    $caminhoResumo = if ($pasta) { Join-Path $pasta.FullName 'resumo.csv' }
    $resumo = if ($caminhoResumo -and (Test-Path -LiteralPath $caminhoResumo)) { Import-Csv -LiteralPath $caminhoResumo } else { $null }
    $script:resultados.Add([pscustomobject]@{
        Acao               = $Acao
        Sucesso            = (-not $erro)
        ValidacaoAprovada  = $resumo.ValidacaoAprovada
        AlteracaoExecutada = $resumo.AlteracaoExecutada
        UalAntes           = $resumo.UalAntes
        UalDepois          = $resumo.UalDepois
        EventosCopilot     = $resumo.EventosEncontrados
        PoliticasDepois    = $resumo.PoliticasDepois
        Erro               = $(if ($erro) { $erro } else { $resumo.Erro })
        Evidencias         = $pasta.FullName
    })
    if ($erro) { Write-Host "  A execucao terminou com erro: $erro" -ForegroundColor Red }
    return $resumo
}

function Connect-ComRetry {
    <# Login do Exchange/S&C: tenta o padrao (janela de contas do Windows) e, se falhar, o navegador. #>
    param([string]$Comando)
    try {
        & $Comando -UserPrincipalName $ContaEsperada -ShowBanner:$false -ErrorAction Stop
    } catch {
        Write-Host "  O login padrao falhou ($($_.Exception.Message)). Tentando pelo navegador..." -ForegroundColor Yellow
        & $Comando -UserPrincipalName $ContaEsperada -ShowBanner:$false -DisableWAM -ErrorAction Stop
    }
}

New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$LOG_TESTE = Join-Path $PastaTrabalho "teste-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -LiteralPath $LOG_TESTE -Force | Out-Null

try {
    # ------------------------------------------------------------------
    Etapa 1 'Modulos'
    $faltando = @($MODULOS_GRAPH | Where-Object { -not (Get-Module -ListAvailable -Name $_ | Where-Object Version -eq $VERSAO_GRAPH) })
    $exo = Get-Module -ListAvailable -Name $MODULO_EXO | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $exo -or $exo.Version -lt $VERSAO_MINIMA_EXO) { $faltando += $MODULO_EXO }
    if ($faltando.Count -eq 0) {
        Write-Host "Modulos ja instalados (Graph $VERSAO_GRAPH, Exchange Online $($exo.Version))." -ForegroundColor Green
    } else {
        Write-Host "Faltam: $($faltando -join ', ')"
        Write-Host 'Sao instalados so para o seu usuario (Install-Module -Scope CurrentUser), da PowerShell Gallery.' -ForegroundColor DarkGray
        if (-not (Confirmar 'Instalar agora?')) { throw 'Modulos nao instalados. Nada foi alterado.' }
        foreach ($m in $faltando) {
            Write-Host "Instalando $m..."
            if ($m -eq $MODULO_EXO) {
                Install-Module -Name $m -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
            } else {
                Install-Module -Name $m -RequiredVersion $VERSAO_GRAPH -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
            }
        }
        Write-Host 'Modulos instalados.' -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    Etapa 2 'Tenant e conta'
    Write-Host "Tenant esperado: $TenantIdEsperado"
    Write-Host "Conta esperada:  $ContaEsperada"
    if (-not (Confirmar 'Estes sao os dados do tenant de DEMO?')) {
        $TenantIdEsperado = Read-Host 'Tenant ID do tenant de demo'
        $ContaEsperada = Read-Host 'Conta administradora (UPN)'
    }

    New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
    $script:Copia = Join-Path $PastaTrabalho '31-auditoria-copilot-ual.ps1'
    Copy-Item -Force (Join-Path $PSScriptRoot 'originais\31-auditoria-copilot-ual.ps1') $script:Copia
    # Preflight minimo (o oficial nao veio junto): so as duas variaveis que o script usa
    @"
# Gerado por Teste-AUTO31.ps1: substituto minimo do 00-preflight.ps1 do laboratorio.
`$TenantId = '$TenantIdEsperado'
`$AdminUPN = '$ContaEsperada'
"@ | Set-Content -Path (Join-Path $PastaTrabalho '00-preflight.ps1') -Encoding utf8
    Write-Host "Script original e preflight minimo em $PastaTrabalho (as evidencias ficam ao lado)."

    # ------------------------------------------------------------------
    Etapa 3 'Logins (uma vez so)'
    # Exchange antes do Graph: os dois trazem a biblioteca de login da Microsoft (MSAL) e a
    # primeira carregada e a que fica no processo
    Import-Module $MODULO_EXO -ErrorAction Stop
    foreach ($m in $MODULOS_GRAPH) { Import-Module $m -RequiredVersion $VERSAO_GRAPH -ErrorAction Stop }

    Write-Host '1/3 Microsoft Graph: abra https://microsoft.com/devicelogin, digite o codigo que vai aparecer e entre com' -ForegroundColor Cyan
    Write-Host "$ContaEsperada (de preferencia numa janela anonima/InPrivate)." -ForegroundColor Cyan
    Write-Host 'Se a tela parecer parada, aperte Esc: selecionar texto na janela pausa a saida.' -ForegroundColor DarkGray
    Connect-MgGraph -TenantId $TenantIdEsperado -Scopes 'User.Read.All', 'Organization.Read.All' `
        -ContextScope Process -UseDeviceCode -NoWelcome -ErrorAction Stop
    Write-Host "Graph conectado como $((Get-MgContext).Account)." -ForegroundColor Green

    Write-Host ''
    Write-Host "2/3 Security & Compliance: vai abrir a escolha de conta. Use somente $ContaEsperada." -ForegroundColor Cyan
    Connect-ComRetry -Comando 'Connect-IPPSSession'
    Write-Host 'Security & Compliance conectado.' -ForegroundColor Green

    Write-Host ''
    Write-Host "3/3 Exchange Online: pode nao pedir login de novo. Se pedir, use $ContaEsperada." -ForegroundColor Cyan
    Connect-ComRetry -Comando 'Connect-ExchangeOnline'
    Write-Host 'Exchange Online conectado.' -ForegroundColor Green

    # Get-AdminAuditLogConfig precisa vir da sessao do Exchange (no S&C a auditoria aparece sempre desligada)
    $sessaoExo = Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' -and -not $_.IsEopSession } | Select-Object -Last 1
    $origem = (Get-Command Get-AdminAuditLogConfig -ErrorAction Stop).ModuleName
    # Get-ConnectionInformation devolve o caminho completo do modulo temporario; Get-Command, so o nome
    if ($sessaoExo -and $sessaoExo.ModuleName -and $origem -ne (Split-Path -Leaf $sessaoExo.ModuleName)) {
        throw "Get-AdminAuditLogConfig esta vindo do Security & Compliance ($origem), nao do Exchange Online ($($sessaoExo.ModuleName)). O resultado da auditoria sairia errado."
    }
    Write-Host 'Get-AdminAuditLogConfig vem da sessao do Exchange Online, como deve ser.' -ForegroundColor DarkGray

    # ------------------------------------------------------------------
    Etapa 4 'Consultar (somente leitura)'
    Write-Host 'Le se a auditoria esta ligada, as politicas de retencao de auditoria, as licencas da conta'
    Write-Host 'e conta os eventos do Copilot dos ultimos 7 dias. Nao altera nada e nao exporta o conteudo'
    Write-Host 'das conversas (prompts, respostas ou arquivos).'
    $consulta = Rodar-Original -Acao 'Consultar'
    if (-not $consulta -or $consulta.ValidacaoAprovada -ne 'True') { throw 'A consulta nao foi concluida; as acoes opcionais foram puladas.' }
    Write-Host ''
    Write-Host "Auditoria ligada: $($consulta.UalDepois) · eventos do Copilot (7 dias): $($consulta.EventosEncontrados) · politicas de retencao: $($consulta.PoliticasDepois)"
    Write-Host "Licenca candidata a Audit Premium na conta: $($consulta.LicencaAuditPremiumCandidata)"
    $ualLigada = $consulta.UalDepois -eq 'True'

    # ------------------------------------------------------------------
    Etapa 5 'Ligar a auditoria (opcional)'
    if ($ualLigada) {
        Write-Host 'A auditoria ja esta ligada. Rodando a acao mesmo assim para testar o caminho (nao muda nada).'
        $null = Rodar-Original -Acao 'HabilitarUAL' -Extras @{ ConfirmarAlteracao = $true }
    } elseif (Confirmar 'A auditoria esta DESLIGADA. Ligar agora? (pode levar ate 60 min para valer)') {
        $r = Rodar-Original -Acao 'HabilitarUAL' -Extras @{ ConfirmarAlteracao = $true }
        $ualLigada = $r -and $r.UalDepois -eq 'True'
    }

    # ------------------------------------------------------------------
    Etapa 6 'Politica de retencao de auditoria do Copilot (opcional)'
    Write-Host "Cria (ou atualiza) a politica '$NOME_POLITICA': guarda os eventos do Copilot por 12 meses,"
    Write-Host 'prioridade 100. Exige licenca de auditoria premium (ex.: Microsoft 365 E5 ou Office 365 E5).'
    if (Confirmar 'Criar a politica?') {
        $r = Rodar-Original -Acao 'AplicarRetencao' -Extras @{ ConfirmarAlteracao = $true }
        if ($r -and $r.ValidacaoAprovada -eq 'True') {
            Write-Host 'Politica criada e conferida.' -ForegroundColor Green
            Write-Host 'Rodando de novo para testar a atualizacao (mesmos valores; nao deve duplicar).'
            $null = Rodar-Original -Acao 'AplicarRetencao' -Extras @{ ConfirmarAlteracao = $true }
        }
        $existe = Get-UnifiedAuditLogRetentionPolicy -ErrorAction SilentlyContinue | Where-Object Name -eq $NOME_POLITICA
        if ($existe -and (Confirmar 'Remover a politica de teste agora (o script original nao tem essa acao)?')) {
            Remove-UnifiedAuditLogRetentionPolicy -Identity $existe.Identity -Confirm:$false -ErrorAction Stop
            Write-Host 'Politica removida.' -ForegroundColor Green
        }
    }

    # ------------------------------------------------------------------
    Etapa 7 'Desligar e religar a auditoria (opcional, so em tenant de teste)'
    Write-Host 'Enquanto a auditoria estiver desligada, NADA e registrado no log de auditoria do tenant' -ForegroundColor Yellow
    Write-Host '(nem do Copilot, nem de admins). Religar pode levar ate 60 min para valer.' -ForegroundColor Yellow
    if ($ualLigada -and (Confirmar 'Desligar e religar logo em seguida?')) {
        $null = Rodar-Original -Acao 'DesabilitarUAL' -Extras @{ ConfirmarAlteracao = $true }
        $null = Rodar-Original -Acao 'HabilitarUAL' -Extras @{ ConfirmarAlteracao = $true }
    }
} catch {
    Write-Host ''
    Write-Host "PAROU: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Onde: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    Write-Host "Tipo: $($_.Exception.GetType().FullName)" -ForegroundColor DarkGray
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
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Log completo do teste: $LOG_TESTE" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
}
