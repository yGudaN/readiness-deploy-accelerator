#Requires -Version 5.1
<#
.SYNOPSIS
    Teste manual do AUTO-20 (DLP da Power Platform, Acesso Condicional, DLP do Purview e rotulo de
    sensibilidade) no tenant de demo, rodando o script ORIGINAL sem alteracoes.

.DESCRIPTION
    O original exige o Windows PowerShell 5.1 (powershell.exe, NAO o pwsh 7), o modulo
    Microsoft.PowerApps.Administration.PowerShell e o Graph fixado em 2.39.0. Os modulos do
    PowerShell 7 nao valem para o 5.1: este roteiro instala o que faltar so para o seu usuario.

    Ordem do teste:
      1. Conferir o Windows PowerShell 5.1 e os modulos
      2. Tenant e conta
      3. Consultar (somente leitura)
      4. (opcional) CriarModelo: cria os 5 objetos LAB-AUTO20
      5. (opcional) HabilitarModelo e logo depois DesabilitarModelo
      6. (opcional, recomendado) ReverterModelo: remove tudo o que o modelo criou

    Cada execucao do original faz os proprios logins (ele desconecta no fim):
      - Power Platform: janela de login da Microsoft;
      - Microsoft Graph: codigo de dispositivo (https://microsoft.com/devicelogin);
      - Microsoft Purview: pagina de login no navegador.
    Use sempre a mesma conta admin do tenant de demo.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Teste-AUTO20.ps1
#>
param(
    [string]$TenantIdEsperado = '4c078364-25b9-4ecd-9ace-b9def6d83e2a',
    [string]$ContaEsperada = 'admin@crm202149.onmicrosoft.com',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO20-Teste')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$VERSAO_GRAPH = '2.39.0'   # fixada pelo original
$MODULOS = @(
    @{ Nome = 'Microsoft.PowerApps.Administration.PowerShell'; Versao = $null },
    @{ Nome = 'Microsoft.Graph.Authentication'; Versao = $VERSAO_GRAPH },
    @{ Nome = 'Microsoft.Graph.Identity.SignIns'; Versao = $VERSAO_GRAPH },
    # 3.10.0: no 5.1, o Graph 2.39 carrega antes a biblioteca de login (MSAL 4.82) e o Exchange
    # 3.11.x quebra com "Metodo nao encontrado ... WithBroker"; 3.7.2 a 3.9.2 tambem. O 3.10.0
    # (MSAL 4.83) chegou ao login sem conflito no teste de 12/11/2026.
    @{ Nome = 'ExchangeOnlineManagement'; Versao = '3.10.0' }
)
$VERSAO_EXO = [version]'3.10.0'
$JUSTIFICATIVA = 'Teste manual do Readiness Deploy Accelerator no tenant de demo'
$PASTA_EVIDENCIAS = 'evidencias\AUTO-20-DLP-CA-Rotulos'

function Etapa([string]$Numero, [string]$Titulo) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host " ETAPA $Numero - $Titulo" -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
}

function Confirmar([string]$Pergunta) {
    return (Read-Host "$Pergunta (S/N)") -match '^[sS]'
}

$resultados = New-Object System.Collections.Generic.List[object]

function Rodar-Original {
    <# Executa o original neste processo; devolve o resumo.json da execucao (ou $null). #>
    param([string]$Acao, [hashtable]$Extras = @{})
    $parametros = @{
        Acao = $Acao; TenantId = $TenantIdEsperado; AdminUPN = $ContaEsperada
        EvidenceRoot = (Join-Path $PastaTrabalho 'evidencias')
    }
    foreach ($k in $Extras.Keys) { $parametros[$k] = $Extras[$k] }
    Write-Host ''
    Write-Host "> 20-dlp-ca-rotulos.ps1 -Acao $Acao" -ForegroundColor DarkGray
    Write-Host '  Logins desta execucao: Power Platform (janela), Graph (codigo de dispositivo) e Purview (navegador).' -ForegroundColor Cyan
    Write-Host "  Use somente $ContaEsperada. Se a tela parecer parada, aperte Esc." -ForegroundColor DarkGray
    $antes = @(Get-ChildItem -Path (Join-Path $PastaTrabalho $PASTA_EVIDENCIAS) -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $erro = $null
    try { & $script:Copia @parametros | Out-Host } catch { $erro = $_.Exception.Message }

    $pasta = Get-ChildItem -Path (Join-Path $PastaTrabalho $PASTA_EVIDENCIAS) -Directory -ErrorAction SilentlyContinue |
        Where-Object { $antes -notcontains $_.Name } | Sort-Object Name | Select-Object -Last 1
    $resumo = $null
    if ($pasta) {
        $arquivo = Join-Path $pasta.FullName 'resumo.json'
        if (Test-Path -LiteralPath $arquivo) { $resumo = Get-Content -LiteralPath $arquivo -Raw -Encoding UTF8 | ConvertFrom-Json }
    }
    $acoes = ''
    if ($resumo -and $resumo.Acoes) { $acoes = (@($resumo.Acoes) | ForEach-Object { "$($_.Componente): $($_.Status)" }) -join ' | ' }
    $script:resultados.Add([pscustomobject]@{
            Acao        = $Acao
            Sucesso     = (-not $erro)
            QualityGate = $(if ($resumo) { $resumo.QualityGate } else { '' })
            Purview     = $(if ($resumo) { $resumo.PurviewDisponivel } else { '' })
            Componentes = $acoes
            Erro        = $(if ($erro) { $erro } elseif ($resumo -and $resumo.PSObject.Properties['ErroFatal']) { $resumo.ErroFatal } else { '' })
            Evidencias  = $(if ($pasta) { $pasta.FullName } else { '' })
        })
    if ($erro) { Write-Host "  A execucao terminou com erro: $erro" -ForegroundColor Red }
    return $resumo
}

New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$LOG_TESTE = Join-Path $PastaTrabalho "teste-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -LiteralPath $LOG_TESTE -Force | Out-Null

try {
    # ------------------------------------------------------------------
    Etapa 1 'Windows PowerShell 5.1 e modulos'
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
        throw 'Rode este teste no Windows PowerShell 5.1: powershell.exe -ExecutionPolicy Bypass -File .\Teste-AUTO20.ps1'
    }
    Write-Host "Windows PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green
    $faltando = @($MODULOS | Where-Object {
            $m = $_
            $lista = @(Get-Module -ListAvailable -Name $m.Nome)
            if ($m.Versao) { -not ($lista | Where-Object { $_.Version -eq [version]$m.Versao }) } else { $lista.Count -eq 0 }
        })
    if ($faltando.Count -eq 0) {
        Write-Host 'Modulos ja instalados no Windows PowerShell 5.1.' -ForegroundColor Green
    } else {
        Write-Host "Faltam no Windows PowerShell 5.1: $(($faltando | ForEach-Object { if ($_.Versao) { "$($_.Nome) $($_.Versao)" } else { $_.Nome } }) -join ', ')"
        Write-Host 'Sao instalados so para o seu usuario (Install-Module -Scope CurrentUser), da PowerShell Gallery.' -ForegroundColor DarkGray
        if (-not (Confirmar 'Instalar agora?')) { throw 'Modulos nao instalados. Nada foi alterado.' }
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
            Write-Host 'Instalando o provedor NuGet (necessario para o Install-Module no 5.1)...'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        foreach ($m in $faltando) {
            Write-Host "Instalando $($m.Nome)$(if ($m.Versao) { " $($m.Versao)" })..."
            $p = @{ Name = $m.Nome; Scope = 'CurrentUser'; Repository = 'PSGallery'; Force = $true; AllowClobber = $true }
            if ($m.Versao) { $p.RequiredVersion = $m.Versao }
            Install-Module @p
        }
        Write-Host 'Modulos instalados.' -ForegroundColor Green
    }
    # O original importa a MAIOR versao do Exchange instalada no 5.1: versoes acima da 3.10.0 conflitam
    $novas = @(Get-Module -ListAvailable -Name ExchangeOnlineManagement | Where-Object { $_.Version -gt $VERSAO_EXO })
    if ($novas) {
        Write-Host "No Windows PowerShell 5.1 ha o Exchange $(($novas | ForEach-Object { $_.Version }) -join ', '), que conflita com o Graph 2.39." -ForegroundColor Yellow
        Write-Host 'O script original usaria essa versao. O PowerShell 7 tem a pasta de modulos dele e nao e afetado.' -ForegroundColor DarkGray
        if (-not (Confirmar "Desinstalar do 5.1 as versoes acima de $VERSAO_EXO?")) { throw 'Sem isso o Purview falha com conflito de biblioteca. Nada foi alterado.' }
        foreach ($n in $novas) {
            Uninstall-Module -Name ExchangeOnlineManagement -RequiredVersion $n.Version -Force -ErrorAction Stop
            Write-Host "  Desinstalado do 5.1: ExchangeOnlineManagement $($n.Version)" -ForegroundColor Green
        }
    }

    # ------------------------------------------------------------------
    Etapa 2 'Tenant e conta'
    Write-Host "Tenant esperado: $TenantIdEsperado"
    Write-Host "Conta esperada:  $ContaEsperada"
    if (-not (Confirmar 'Estes sao os dados do tenant de DEMO?')) {
        $TenantIdEsperado = Read-Host 'Tenant ID do tenant de demo'
        $ContaEsperada = Read-Host 'Conta administradora (UPN)'
    }
    $script:Copia = Join-Path $PastaTrabalho '20-dlp-ca-rotulos.ps1'
    Copy-Item -Force (Join-Path $PSScriptRoot 'originais\20-dlp-ca-rotulos.ps1') $script:Copia
    # Correcao minima so na COPIA de trabalho: os parametros de Get-Auto20State sao obrigatorios e nao
    # aceitam lista vazia, entao o original para sempre que o Purview fica indisponivel ou que o tenant
    # nao tem DLP/rotulos ("Nao e possivel associar o argumento ... porque ele e uma matriz vazia").
    $texto = Get-Content -LiteralPath $script:Copia -Raw -Encoding UTF8
    $corrigido = [regex]::Replace($texto, '\[object\[\]\](\$(PowerPlatformPolicies|ConditionalAccessPolicies|PurviewDlpPolicies|Labels|LabelPolicies))\b', '[AllowEmptyCollection()][object[]]$1')
    $trocas = ([regex]::Matches($texto, '\[object\[\]\]\$(PowerPlatformPolicies|ConditionalAccessPolicies|PurviewDlpPolicies|Labels|LabelPolicies)\b')).Count
    Set-Content -LiteralPath $script:Copia -Value $corrigido -Encoding UTF8
    Write-Host "Script original em $PastaTrabalho (as evidencias ficam ao lado)."
    Write-Host "Correcao na copia: $trocas parametros de Get-Auto20State passam a aceitar lista vazia [AllowEmptyCollection()]." -ForegroundColor DarkGray

    # ------------------------------------------------------------------
    Etapa 3 'Consultar (somente leitura)'
    Write-Host 'Le as politicas DLP da Power Platform, de Acesso Condicional, de DLP do Purview, os rotulos e as'
    Write-Host 'politicas de rotulos, alem de funcoes e licencas. Nao altera nada.'
    $consulta = Rodar-Original -Acao 'Consultar'
    if (-not $consulta -or $consulta.QualityGate -eq 'Reprovado') { throw 'A consulta nao foi concluida; as acoes opcionais foram puladas.' }
    Write-Host "Quality gate: $($consulta.QualityGate) - Purview disponivel: $($consulta.PurviewDisponivel)"
    if (-not $consulta.PurviewDisponivel) { Write-Host "Purview bloqueado: $($consulta.PurviewBloqueio)" -ForegroundColor Yellow }

    # ------------------------------------------------------------------
    Etapa 4 'Criar o modelo (opcional)'
    Write-Host 'Cria 5 objetos com prefixo LAB-AUTO20:'
    Write-Host '  - DLP da Power Platform para todos os ambientes, com todos os conectores no grupo padrao (nao bloqueia nada);'
    Write-Host '  - Acesso Condicional exigindo MFA so da conta admin, em modo de relatorio (nao cobra MFA);'
    Write-Host '  - DLP do Purview para o Exchange, sem regras e em modo de teste sem notificacoes;'
    Write-Host '  - rotulo de sensibilidade sem criptografia e politica de rotulos publicada so para a conta admin.'
    $criou = $false
    if (Confirmar 'Criar o modelo?') {
        $r = Rodar-Original -Acao 'CriarModelo' -Extras @{ ConfirmarAlteracao = $true; Justificativa = $JUSTIFICATIVA }
        $criou = $null -ne $r
        if ($r) {
            Write-Host 'Rodando de novo para conferir que nao duplica.'
            $null = Rodar-Original -Acao 'CriarModelo' -Extras @{ ConfirmarAlteracao = $true; Justificativa = $JUSTIFICATIVA }
        }
    }

    # ------------------------------------------------------------------
    Etapa 5 'Habilitar e desabilitar o modelo (opcional)'
    Write-Host 'HabilitarModelo LIGA o Acesso Condicional: a conta admin passa a precisar de MFA em todos os apps.' -ForegroundColor Yellow
    Write-Host 'Se a conta admin nao tiver MFA configurado, o proximo login vai pedir para configurar.' -ForegroundColor Yellow
    Write-Host 'Tambem liga a DLP do Purview (sem regras) e publica o rotulo para a conta admin.'
    Write-Host 'Logo em seguida o roteiro roda DesabilitarModelo.'
    if ($criou -and (Confirmar 'Habilitar e desabilitar logo em seguida?')) {
        $null = Rodar-Original -Acao 'HabilitarModelo' -Extras @{ ConfirmarAlteracao = $true; Justificativa = $JUSTIFICATIVA }
        $null = Rodar-Original -Acao 'DesabilitarModelo' -Extras @{ ConfirmarAlteracao = $true; Justificativa = $JUSTIFICATIVA }
    }

    # ------------------------------------------------------------------
    Etapa 6 'Reverter o modelo (recomendado depois de conferir)'
    Write-Host 'Remove somente os objetos LAB-AUTO20 criados pelo modelo.'
    Write-Host 'Antes de responder, se quiser, confira no portal:' -ForegroundColor DarkGray
    Write-Host '  - DLP da Power Platform: https://admin.powerplatform.microsoft.com > Seguranca > Politicas de dados' -ForegroundColor DarkGray
    Write-Host '  - Acesso Condicional: https://entra.microsoft.com > Protecao > Acesso Condicional' -ForegroundColor DarkGray
    Write-Host '  - DLP e rotulos: https://purview.microsoft.com > Prevencao contra perda de dados / Information Protection' -ForegroundColor DarkGray
    if (Confirmar 'Reverter o modelo agora?') {
        $null = Rodar-Original -Acao 'ReverterModelo' -Extras @{ ConfirmarAlteracao = $true; Justificativa = "$JUSTIFICATIVA (reverter)" }
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
        $resultados | Export-Csv -Path $arquivo -NoTypeInformation -Encoding UTF8
        Write-Host "Resumo salvo em $arquivo" -ForegroundColor DarkGray
    }
    Write-Host "Log completo do teste: $LOG_TESTE" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
}
