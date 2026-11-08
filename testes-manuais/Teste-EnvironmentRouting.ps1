#Requires -Version 7.0
<#
.SYNOPSIS
    Teste manual do COE-IA-003: ativar o Environment Routing (roteamento de makers para
    ambientes pessoais de Developer) no tenant do Power Platform.

.DESCRIPTION
    Roteiro passo a passo, com pausa e confirmacao antes de cada alteracao. Serve para validar
    o procedimento antes de ele virar um item do Readiness Deploy Accelerator.

    Diferencas em relacao ao documento COE-IA-003:
      - Usa o PAC CLI (pac admin list-tenant-settings / update-tenant-settings) no PowerShell 7,
        em vez do modulo Microsoft.PowerApps.Administration.PowerShell (so roda no Windows
        PowerShell 5.1 e faz login por janela embutida, que falhou no teste do Copilot Agent Kit).
      - Mantem o "payload minimo" do documento: so a propriedade enableDefaultEnvironmentRouting
        vai no arquivo enviado (o objeto completo causa InvalidManagedAppsPreviewValueInTenantSettings).
      - Guarda as configuracoes do tenant antes e depois, como evidencia.
      - Pergunta se o roteamento vale so para makers novos ou tambem para os existentes
        (environmentRoutingAllMakers), que o documento nao trata.

    ATENCAO: e uma configuracao do TENANT inteiro, nao de um ambiente.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Teste-EnvironmentRouting.ps1
#>
param(
    # Perfil do PAC CLI do tenant de demo (criado no teste do Copilot Agent Kit)
    [string]$Perfil = 'RDA-Demo',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\EnvironmentRouting-Teste')
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$carimbo = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $PastaTrabalho "log-$carimbo.txt"
Start-Transcript -Path $log | Out-Null

# Caminho do executavel (uma funcao chamada "Pac" esconderia o comando pac: o PowerShell nao diferencia maiusculas)
$PacExe = (Get-Command pac -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source

function Etapa([string]$Numero, [string]$Titulo) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host " ETAPA $Numero - $Titulo" -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
}

function Confirmar([string]$Pergunta) {
    return (Read-Host "$Pergunta (S/N)") -match '^[sS]'
}

function Invoke-Pac {
    # Mostra a saida ao vivo e falha em erro. O pac nem sempre devolve codigo de saida
    # diferente de 0 quando falha, por isso a saida tambem e conferida.
    param([Parameter(ValueFromRemainingArguments)][string[]]$Argumentos)
    Write-Host "> pac $($Argumentos -join ' ')" -ForegroundColor DarkGray
    & $PacExe @Argumentos 2>&1 | Tee-Object -Variable saida | Out-Host
    $erro = $saida | Where-Object { "$_" -match '^\s*Error:' } | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or $erro) { throw "pac falhou: $(if ($erro) { "$erro".Trim() } else { "codigo $LASTEXITCODE" })" }
}

function Get-Roteamento([string]$ArquivoEvidencia) {
    # Le as configuracoes do tenant, guarda o arquivo completo como evidencia e devolve os campos de roteamento
    & $PacExe admin list-tenant-settings --settings-file $ArquivoEvidencia 2>&1 | Out-Null
    if (-not (Test-Path $ArquivoEvidencia)) { throw 'Nao foi possivel ler as configuracoes do tenant.' }
    $governanca = (Get-Content -Raw $ArquivoEvidencia | ConvertFrom-Json).powerPlatform.governance
    return [pscustomobject]@{
        enableDefaultEnvironmentRouting                    = $governanca.enableDefaultEnvironmentRouting
        environmentRoutingAllMakers                        = $governanca.environmentRoutingAllMakers
        environmentRoutingTargetEnvironmentGroupId         = $governanca.environmentRoutingTargetEnvironmentGroupId
        environmentRoutingTargetSecurityGroupId            = $governanca.environmentRoutingTargetSecurityGroupId
        disableDeveloperEnvironmentCreationByNonAdminUsers = $governanca.disableDeveloperEnvironmentCreationByNonAdminUsers
    }
}

function Set-Governanca([hashtable]$Valores, [string]$Nome) {
    # Envia so as propriedades informadas (payload minimo, como no documento)
    $arquivo = Join-Path $PastaTrabalho "payload-$Nome-$carimbo.json"
    @{ powerPlatform = @{ governance = $Valores } } | ConvertTo-Json -Depth 5 | Set-Content -Path $arquivo -Encoding utf8
    Write-Host "Payload enviado ($arquivo):" -ForegroundColor DarkGray
    Get-Content $arquivo | ForEach-Object { "  $_" } | Out-Host
    Invoke-Pac admin update-tenant-settings --settings-file $arquivo
}

try {
    if (-not $PacExe) { throw 'PAC CLI nao encontrado. Instale: https://aka.ms/PowerPlatformCLI' }

    # ------------------------------------------------------------------
    Etapa 1 'Conta e tenant'
    $perfis = & $PacExe auth list 2>&1 | Out-String
    if ($perfis -notmatch "\s$([regex]::Escape($Perfil))\s") {
        Write-Host "Perfil '$Perfil' nao encontrado. Criando com login por codigo." -ForegroundColor Cyan
        Write-Host '  Abra https://microsoft.com/devicelogin no navegador (ou janela InPrivate), digite o codigo'
        Write-Host '  e entre com uma conta Administrador do Power Platform do tenant de teste.'
        Invoke-Pac auth create --name $Perfil --deviceCode
    }
    Invoke-Pac auth select --name $Perfil
    Invoke-Pac auth who
    Write-Host ''
    Write-Host 'ATENCAO: o Environment Routing vale para o TENANT inteiro.' -ForegroundColor Yellow
    if (-not (Confirmar 'A conta e o tenant acima sao os do ambiente de TESTE?')) { throw 'Tenant nao confirmado. Nada foi alterado.' }

    # ------------------------------------------------------------------
    Etapa 2 'Estado atual'
    $antes = Get-Roteamento (Join-Path $PastaTrabalho "tenant-settings-antes-$carimbo.json")
    $antes | Format-List | Out-Host
    if ($antes.enableDefaultEnvironmentRouting -eq $true) {
        Write-Host 'O Environment Routing ja esta ativo neste tenant.' -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    Etapa 3 'Ativar o Environment Routing'
    Write-Host 'O que muda para os makers:' -ForegroundColor Cyan
    Write-Host '  - Ao abrir Power Apps, Power Automate ou Copilot Studio, o maker cai no proprio ambiente'
    Write-Host '    de Developer (criado automaticamente na primeira vez), em vez do ambiente padrao.'
    Write-Host '  - Esses ambientes sao Managed Environments: criar e testar e livre, mas para RODAR apps'
    Write-Host '    e fluxos nesses ambientes e preciso licenca premium.'
    Write-Host '  - O maker vira administrador do proprio ambiente e pode trocar de ambiente quando quiser.'
    Write-Host ''
    Write-Host "Hoje environmentRoutingAllMakers = $($antes.environmentRoutingAllMakers)."
    Write-Host '  False = so makers novos sao roteados. True = makers novos e existentes.'
    $todos = Confirmar 'Rotear tambem os makers EXISTENTES? (N mantem como esta, igual ao documento)'

    if (Confirmar 'Ativar o Environment Routing neste tenant agora?') {
        $valores = @{ enableDefaultEnvironmentRouting = $true }
        if ($todos) { $valores.environmentRoutingAllMakers = $true }
        Set-Governanca -Valores $valores -Nome 'ativar'
    } else {
        throw 'Ativacao cancelada. Nada foi alterado.'
    }

    # ------------------------------------------------------------------
    Etapa 4 'Validar'
    Start-Sleep -Seconds 5
    $depois = Get-Roteamento (Join-Path $PastaTrabalho "tenant-settings-depois-$carimbo.json")
    $depois | Format-List | Out-Host
    if ($depois.enableDefaultEnvironmentRouting -eq $true) {
        Write-Host 'Validado: enableDefaultEnvironmentRouting = True' -ForegroundColor Green
    } else {
        Write-Host 'O valor continua False. Veja o Troubleshooting do documento (permissao, pre-requisitos).' -ForegroundColor Red
    }

    Write-Host ''
    Write-Host 'Confira tambem no admin center (o que o instalador vai precisar saber):' -ForegroundColor Cyan
    Write-Host '  admin.powerplatform.microsoft.com > Gerenciar > Configuracoes do locatario > Roteamento de ambiente'
    Write-Host '  - O roteamento aparece ativo? Foi criada alguma regra? Para quais portais (Power Apps,'
    Write-Host '    Power Automate, Copilot Studio)? Ha grupo de ambientes de destino?'
    Read-Host 'Pressione Enter depois de conferir' | Out-Null

    # ------------------------------------------------------------------
    Etapa 5 'Desfazer (opcional)'
    if (Confirmar 'Desfazer agora e voltar o Environment Routing para False? (N mantem ativo)') {
        $valores = @{ enableDefaultEnvironmentRouting = $false }
        if ($todos) { $valores.environmentRoutingAllMakers = [bool]$antes.environmentRoutingAllMakers }
        Set-Governanca -Valores $valores -Nome 'desfazer'
        Start-Sleep -Seconds 5
        $final = Get-Roteamento (Join-Path $PastaTrabalho "tenant-settings-final-$carimbo.json")
        $final | Format-List | Out-Host
    } else {
        Write-Host 'Mantido ativo.' -ForegroundColor Green
    }
} catch {
    Write-Host ''
    Write-Host "PAROU: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Stop-Transcript | Out-Null
    Write-Host ''
    Write-Host "Log e evidencias: $PastaTrabalho" -ForegroundColor DarkGray
}
