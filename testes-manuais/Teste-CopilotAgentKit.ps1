#Requires -Version 7.0
<#
.SYNOPSIS
    Teste manual da instalacao do Copilot Agent Kit (COE-IA-001) num ambiente Power Platform.

.DESCRIPTION
    Roteiro passo a passo, com pausa e confirmacao antes de cada alteracao no ambiente.
    Serve para validar o procedimento antes de ele virar um item do Readiness Deploy Accelerator.

    Diferencas em relacao ao documento COE-IA-001 (vindas da documentacao da Microsoft):
      - O Copilot Agent Kit depende do Creator Kit (CreatorKitCore): ele e importado antes.
      - O ambiente precisa de "Power Apps component framework for canvas apps" ligado
        (feito aqui pelo PAC CLI) e de "Power Apps code apps" ligado (so no admin center).
      - Todo comando pac recebe --environment explicito, para nunca usar o perfil ativo por engano.
      - Os arquivos vem da ultima release oficial no GitHub da Microsoft, com hash SHA-256 registrado.

    Tudo o que aparece no console fica gravado num log (transcricao) na pasta de trabalho.

.EXAMPLE
    pwsh -File .\Teste-CopilotAgentKit.ps1
#>
param(
    # Ambiente de demo do Gustavo (o DEV do documento COE-IA-001 depende de outra pessoa para o login)
    [string]$EnvironmentUrl = 'https://org31c11f3e.crm.dynamics.com/',
    [string]$Perfil = 'RDA-Demo',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\CopilotAgentKit-Teste')
)

$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/') + '/'

New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$log = Join-Path $PastaTrabalho "log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
Start-Transcript -Path $log | Out-Null

function Etapa([string]$Numero, [string]$Titulo) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host " ETAPA $Numero - $Titulo" -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
}

function Confirmar([string]$Pergunta) {
    $r = Read-Host "$Pergunta (S/N)"
    return $r -match '^[sS]'
}

# Caminho do executavel (o PowerShell nao diferencia maiusculas: uma funcao chamada "Pac"
# esconderia o comando pac e chamaria a si mesma)
$PacExe = (Get-Command pac -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $PacExe) { throw 'PAC CLI nao encontrado. Instale: https://aka.ms/PowerPlatformCLI' }

function Invoke-Pac {
    # Executa o pac mostrando a saida ao vivo e falha em caso de erro.
    # O pac nem sempre devolve codigo de saida diferente de 0 quando falha
    # (ex.: "Error: User canceled authentication." sai com 0), por isso a saida tambem e conferida.
    param([Parameter(ValueFromRemainingArguments)][string[]]$Argumentos)
    Write-Host "> pac $($Argumentos -join ' ')" -ForegroundColor DarkGray
    & $PacExe @Argumentos 2>&1 | Tee-Object -Variable saida | Out-Host
    $erro = $saida | Where-Object { "$_" -match '^\s*Error:' } | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or $erro) { throw "pac falhou: $(if ($erro) { "$erro".Trim() } else { "codigo $LASTEXITCODE" })" }
}

function Baixar-UltimaRelease([string]$Repositorio, [string]$PadraoArquivo) {
    $release = Invoke-RestMethod "https://api.github.com/repos/$Repositorio/releases/latest" -Headers @{ 'User-Agent' = 'ReadinessDeployAccelerator-Teste' }
    $asset = $release.assets | Where-Object name -match $PadraoArquivo | Select-Object -First 1
    if (-not $asset) { throw "Nenhum arquivo '$PadraoArquivo' na release $($release.tag_name) de $Repositorio." }
    $destino = Join-Path $PastaTrabalho $asset.name
    Write-Host "Release: $($release.tag_name) ($($release.published_at))"
    Write-Host "Arquivo: $($asset.name) - $([math]::Round($asset.size / 1MB, 1)) MB"
    if (Test-Path $destino) {
        Write-Host 'Ja baixado anteriormente.' -ForegroundColor DarkGray
    } elseif (Confirmar "Baixar de github.com/$Repositorio?") {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $destino
    } else {
        throw 'Download cancelado.'
    }
    $hash = (Get-FileHash -Algorithm SHA256 -Path $destino).Hash
    Write-Host "SHA-256: $hash"
    return $destino
}

function Solucoes-Kit {
    # Linhas da lista de solucoes que mencionam os kits (para conferir antes e depois)
    & $PacExe solution list --environment $EnvironmentUrl 2>&1 | Select-String -Pattern 'Creator|Copilot.*Kit|CopilotStudio|UniqueName|Unique Name'
}

try {
    # ------------------------------------------------------------------
    Etapa 1 'PAC CLI'
    Write-Host $PacExe
    & $PacExe 2>&1 | Select-String -Pattern 'Version' | Select-Object -First 1

    # ------------------------------------------------------------------
    Etapa 2 'Perfil de autenticacao e confirmacao do ambiente'
    $perfis = & $PacExe auth list 2>&1 | Out-String
    if ($perfis -match "\s$([regex]::Escape($Perfil))\s") {
        Write-Host "Perfil '$Perfil' ja existe." -ForegroundColor DarkGray
    } else {
        # Login por codigo de dispositivo: a janela de login embutida do pac usa um navegador antigo
        # (bloqueado no cadastro de MFA) e entra sozinha com a conta do Windows.
        Write-Host "Criando o perfil '$Perfil' com login por codigo." -ForegroundColor Cyan
        Write-Host '  1. O pac vai mostrar um codigo e o endereco https://microsoft.com/devicelogin.'
        Write-Host '  2. Abra esse endereco no navegador (ou janela anonima/InPrivate) onde esta a conta do ambiente de demo.'
        Write-Host '  3. Digite o codigo, entre com a conta de administrador do ambiente e volte para ca.'
        Write-Host '  Se a conta pedir para configurar o MFA ("Keep your account secure"), conclua no navegador.' -ForegroundColor DarkGray
        Invoke-Pac auth create --environment $EnvironmentUrl --name $Perfil --deviceCode
    }
    Invoke-Pac auth select --name $Perfil
    Invoke-Pac org who --environment $EnvironmentUrl
    if (-not (Confirmar "O 'Org URL' acima e $EnvironmentUrl e o 'Friendly Name' e o ambiente de demo esperado?")) { throw 'Ambiente nao confirmado. Nada foi alterado.' }

    # ------------------------------------------------------------------
    Etapa 3 'Configuracoes do ambiente exigidas pelo kit'
    Write-Host 'Configuracoes atuais relacionadas a componentes de codigo:'
    & $PacExe env list-settings --environment $EnvironmentUrl 2>&1 | Select-String -Pattern 'customcontrol|codeapp|pcf' | ForEach-Object { "  $_" }
    if (Confirmar 'Ligar "Power Apps component framework for canvas apps" (iscustomcontrolsincanvasappsenabled = true)?') {
        Invoke-Pac env update-settings --environment $EnvironmentUrl --name iscustomcontrolsincanvasappsenabled --value true
    }
    Write-Host ''
    Write-Host '"Power Apps code apps" so pode ser ligado no admin center:' -ForegroundColor Yellow
    Write-Host '  admin.powerplatform.microsoft.com > Gerenciar > Ambientes > (ambiente org31c11f3e) > Configuracoes'
    Write-Host '  > Produto > Recursos > Power Apps code apps > Ativar code apps > Salvar'
    Read-Host 'Pressione Enter depois de ligar (ou se ja estiver ligado)' | Out-Null

    # ------------------------------------------------------------------
    Etapa 4 'Download dos pacotes oficiais'
    Write-Host 'Creator Kit (dependencia obrigatoria):'
    $creatorKit = Baixar-UltimaRelease 'microsoft/powercat-creator-kit' '^CreatorKitCore_.*_managed\.zip$'
    Write-Host ''
    Write-Host 'Copilot Agent Kit:'
    $agentKit = Baixar-UltimaRelease 'microsoft/Power-CAT-Copilot-Studio-Kit' '^(CopilotAgentKit|CopilotStudioKit)_.*_managed\.zip$'

    Write-Host ''
    Write-Host 'Solucoes de kit ja presentes no ambiente (antes da importacao):'
    Solucoes-Kit

    # ------------------------------------------------------------------
    Etapa 5 'Importar o Creator Kit'
    if (Confirmar "Importar $(Split-Path $creatorKit -Leaf) em $EnvironmentUrl?") {
        $inicio = Get-Date
        Invoke-Pac solution import --environment $EnvironmentUrl --path $creatorKit --async --max-async-wait-time 60
        Write-Host "Creator Kit importado em $([int]((Get-Date) - $inicio).TotalMinutes) min." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    Etapa 6 'Importar o Copilot Agent Kit'
    Write-Host 'Observacao: a importacao e feita sem arquivo de configuracao, ou seja, sem preencher as'
    Write-Host 'referencias de conexao. Elas sao configuradas depois pelo Setup Wizard do kit.'
    Write-Host 'Se a importacao falhar por causa de conexoes, guarde a mensagem: ela define como o'
    Write-Host 'instalador vai tratar esse ponto.' -ForegroundColor Yellow
    if (Confirmar "Importar $(Split-Path $agentKit -Leaf) em $EnvironmentUrl? (pode levar de 10 a 30 min)") {
        $inicio = Get-Date
        Invoke-Pac solution import --environment $EnvironmentUrl --path $agentKit --async --max-async-wait-time 90
        Write-Host "Copilot Agent Kit importado em $([int]((Get-Date) - $inicio).TotalMinutes) min." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    Etapa 7 'Conferencia'
    Write-Host 'Solucoes de kit no ambiente (depois da importacao):'
    Solucoes-Kit
    Write-Host ''
    Write-Host 'Proximo passo (manual): abrir o app "Copilot Agent Kit" em make.powerapps.com, no ambiente de demo,' -ForegroundColor Cyan
    Write-Host 'e rodar o Setup Wizard (pre-requisitos, referencias de conexao, variaveis de ambiente e fluxos).' -ForegroundColor Cyan
} catch {
    Write-Host ''
    Write-Host "PAROU: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Stop-Transcript | Out-Null
    Write-Host ''
    Write-Host "Log completo: $log" -ForegroundColor DarkGray
}
