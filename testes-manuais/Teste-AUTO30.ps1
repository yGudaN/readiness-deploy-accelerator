#Requires -Version 7.0
<#
.SYNOPSIS
    Teste manual do AUTO-30 (politicas de alerta de atividade no Microsoft Purview) no tenant de
    demo, rodando o script ORIGINAL sem alteracoes.

.DESCRIPTION
    Ordem do teste:
      1. Modulos (Graph 2.41.2 e ExchangeOnlineManagement)
      2. Tenant e conta
      3. Logins, UMA vez so: Graph (codigo de dispositivo) e Security & Compliance
      4. Consultar (somente leitura)
      5. (opcional) Criar uma politica agregada simples, desligar e religar
      6. (opcional) Criar uma politica de atividade anomala
      7. (opcional) Remover as politicas de teste (o script original nao remove)

    O original nao usa 00-preflight.ps1: tenant, conta e pasta de evidencias vao por parametro.
    Ele roda NESTE processo para reaproveitar os logins.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Teste-AUTO30.ps1
#>
param(
    [string]$TenantIdEsperado = '4c078364-25b9-4ecd-9ace-b9def6d83e2a',
    [string]$ContaEsperada = 'admin@crm202149.onmicrosoft.com',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO30-Teste')
)

$ErrorActionPreference = 'Stop'
$VERSAO_GRAPH = '2.41.2'
$MODULOS_GRAPH = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',                         # Get-MgUser
    'Microsoft.Graph.Identity.DirectoryManagement',  # Get-MgSubscribedSku
    'Microsoft.Graph.Identity.Governance'            # funcoes administrativas
)
$MODULO_EXO = 'ExchangeOnlineManagement'
$VERSAO_MINIMA_EXO = [version]'3.2.0'
$NOME_SIMPLES = 'LAB-AUTO30-Atividade-Simples-SearchRemoved'
$NOME_ANOMALA = 'LAB-AUTO30-Atividade-Anomala-SearchRemoved'   # padrao do original
$PASTA_EVIDENCIAS = 'evidencias\AUTO-30-Alertas-Atividade-Anomala'

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
$criadas = [System.Collections.Generic.List[string]]::new()

function Rodar-Original {
    <# Executa o original neste processo; devolve o resumo.csv da execucao (ou $null). #>
    param([string]$Acao, [hashtable]$Extras = @{})
    $parametros = @{
        Acao = $Acao; ExpectedTenantId = $TenantIdEsperado; ExpectedAdminUpn = $ContaEsperada
        EvidenceRoot = (Join-Path $PastaTrabalho 'evidencias')
    } + $Extras
    Write-Host "> 30-alertas-anomalos.ps1 -Acao $Acao $(($Extras.Keys | ForEach-Object { "-$_" }) -join ' ')" -ForegroundColor DarkGray
    $antes = @(Get-ChildItem -Path (Join-Path $PastaTrabalho $PASTA_EVIDENCIAS) -Directory -ErrorAction SilentlyContinue).Name
    $erro = $null
    try { & $script:Copia @parametros | Out-Host } catch { $erro = $_.Exception.Message }

    $pasta = Get-ChildItem -Path (Join-Path $PastaTrabalho $PASTA_EVIDENCIAS) -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -notin $antes | Sort-Object Name | Select-Object -Last 1
    $caminhoResumo = if ($pasta) { Join-Path $pasta.FullName 'resumo.csv' }
    $resumo = if ($caminhoResumo -and (Test-Path -LiteralPath $caminhoResumo)) { Import-Csv -LiteralPath $caminhoResumo } else { $null }
    $script:resultados.Add([pscustomobject]@{
        Acao               = $Acao
        Politica           = $(if ($Extras.AlertName) { $Extras.AlertName } else { $NOME_ANOMALA })
        Sucesso            = (-not $erro)
        ValidacaoAprovada  = $resumo.ValidacaoAprovada
        AlteracaoExecutada = $resumo.AlteracaoExecutada
        Resultado          = $resumo.Resultado
        Detalhe            = $resumo.Detalhe
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
    $script:Copia = Join-Path $PastaTrabalho '30-alertas-anomalos.ps1'
    Copy-Item -Force (Join-Path $PSScriptRoot 'originais\30-alertas-anomalos.ps1') $script:Copia
    Write-Host "Script original em $PastaTrabalho (as evidencias ficam ao lado)."

    # ------------------------------------------------------------------
    Etapa 3 'Logins (uma vez so)'
    # Exchange antes do Graph: os dois trazem a biblioteca de login da Microsoft (MSAL)
    Import-Module $MODULO_EXO -ErrorAction Stop
    foreach ($m in $MODULOS_GRAPH) { Import-Module $m -RequiredVersion $VERSAO_GRAPH -ErrorAction Stop }

    Write-Host '1/2 Microsoft Graph: abra https://microsoft.com/devicelogin, digite o codigo que vai aparecer e entre com' -ForegroundColor Cyan
    Write-Host "$ContaEsperada (de preferencia numa janela anonima/InPrivate)." -ForegroundColor Cyan
    Write-Host 'Se a tela parecer parada, aperte Esc: selecionar texto na janela pausa a saida.' -ForegroundColor DarkGray
    Connect-MgGraph -TenantId $TenantIdEsperado -Scopes 'User.Read.All', 'Organization.Read.All', 'RoleManagement.Read.Directory' `
        -ContextScope Process -UseDeviceCode -NoWelcome -ErrorAction Stop
    Write-Host "Graph conectado como $((Get-MgContext).Account)." -ForegroundColor Green

    Write-Host ''
    Write-Host "2/2 Security & Compliance: vai abrir a escolha de conta. Use somente $ContaEsperada." -ForegroundColor Cyan
    try {
        Connect-IPPSSession -UserPrincipalName $ContaEsperada -ShowBanner:$false -ErrorAction Stop
    } catch {
        Write-Host "  O login padrao falhou ($($_.Exception.Message)). Tentando pelo navegador..." -ForegroundColor Yellow
        Connect-IPPSSession -UserPrincipalName $ContaEsperada -ShowBanner:$false -DisableWAM -ErrorAction Stop
    }
    Write-Host 'Security & Compliance conectado.' -ForegroundColor Green

    # ------------------------------------------------------------------
    Etapa 4 'Consultar (somente leitura)'
    Write-Host 'Confere conta, funcoes, licencas e se a politica de teste existe. Nao altera nada.'
    $consulta = Rodar-Original -Acao 'Consultar'
    if (-not $consulta -or $consulta.ValidacaoAprovada -ne 'True') { throw 'A consulta nao foi concluida; as acoes opcionais foram puladas.' }
    Write-Host "Resultado: $($consulta.Detalhe)"
    Write-Host 'Politicas de alerta que ja existem no tenant (nome, tipo, ligada?):' -ForegroundColor DarkGray
    Get-ProtectionAlert | Sort-Object Name | Select-Object Name, AggregationType, @{ n = 'Ligada'; e = { -not $_.Disabled } } |
        Format-Table -AutoSize | Out-Host

    # ------------------------------------------------------------------
    Etapa 5 'Politica agregada simples (opcional)'
    Write-Host "Cria '$NOME_SIMPLES': alerta quando o MESMO usuario faz 50 ou mais exclusoes de pesquisa"
    Write-Host '(SearchRemoved) em 120 minutos. Fica ligada e notifica a conta admin. Depois o roteiro'
    Write-Host 'desliga e religa para testar essas acoes.'
    if (Confirmar 'Criar a politica simples?') {
        $extras = @{ AlertName = $NOME_SIMPLES; ConfirmarAlteracao = $true }
        $r = Rodar-Original -Acao 'CriarSimples' -Extras $extras
        if ($r -and $r.ValidacaoAprovada -eq 'True') {
            $criadas.Add($NOME_SIMPLES)
            Write-Host 'Rodando de novo para conferir que nao duplica.'
            $null = Rodar-Original -Acao 'CriarSimples' -Extras $extras
            $null = Rodar-Original -Acao 'Desabilitar' -Extras $extras
            $null = Rodar-Original -Acao 'Habilitar' -Extras $extras
        }
    }

    # ------------------------------------------------------------------
    Etapa 6 'Politica de atividade anomala (opcional)'
    Write-Host "Cria '$NOME_ANOMALA': alerta quando um usuario foge do proprio padrao de exclusoes de pesquisa."
    Write-Host 'A Microsoft leva ate 7 dias para aprender o padrao; nesse periodo nao dispara alertas.'
    if (Confirmar 'Criar a politica anomala?') {
        $r = Rodar-Original -Acao 'CriarAnomala' -Extras @{ AlertName = $NOME_ANOMALA; ConfirmarAlteracao = $true }
        if ($r -and $r.ValidacaoAprovada -eq 'True') { $criadas.Add($NOME_ANOMALA) }
    }

    # ------------------------------------------------------------------
    Etapa 7 'Remover as politicas de teste (opcional)'
    $existentes = @(Get-ProtectionAlert | Where-Object { $_.Name -like 'LAB-AUTO30-*' })
    if (-not $existentes) {
        Write-Host 'Nenhuma politica LAB-AUTO30- no tenant.'
    } else {
        Write-Host 'Politicas de teste no tenant:'
        $existentes | ForEach-Object { Write-Host "  - $($_.Name)" }
        Write-Host 'Antes de responder, se quiser, confira no Microsoft Purview (https://purview.microsoft.com):' -ForegroundColor DarkGray
        Write-Host 'digite "Alert policies" (ou "Politicas de alerta") na busca do portal.' -ForegroundColor DarkGray
        if (Confirmar 'Remover essas politicas agora (o script original nao tem essa acao)?') {
            foreach ($p in $existentes) {
                Remove-ProtectionAlert -Identity $p.Identity -Confirm:$false -ErrorAction Stop
                Write-Host "  Removida: $($p.Name)" -ForegroundColor Green
            }
        }
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
