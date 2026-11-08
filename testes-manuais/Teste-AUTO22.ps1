#Requires -Version 7.0
<#
.SYNOPSIS
    Teste manual do AUTO-22 (grupos Copilot-Premium e Copilot-Geral) no tenant de demo,
    rodando o script ORIGINAL validado no laboratorio, sem alteracoes.

.DESCRIPTION
    O roteiro so prepara o ambiente e chama o script original (originais/22-grupos-copilot.ps1)
    com os parametros do tenant de demo, na ordem do guia:
      1. Consultar (somente leitura)
      2. CriarGrupos
      3. CriarGrupos de novo (prova de idempotencia: nao pode duplicar)
      4. AdicionarMembro (usuario de teste)
      5. RemoverMembro
    Cada acao pede confirmacao antes. O script original:
      - faz login no Microsoft Graph por codigo de dispositivo A CADA execucao;
      - confere tenant e conta e aborta se forem outros;
      - grava uma pasta de evidencias por execucao (aqui, em Downloads\AUTO22-Teste\evidencias).

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Teste-AUTO22.ps1
#>
param(
    # Tenant e conta de demo usados nos testes anteriores (Environment Routing)
    [string]$TenantIdEsperado = '4c078364-25b9-4ecd-9ace-b9def6d83e2a',
    [string]$ContaEsperada = 'admin@crm202149.onmicrosoft.com',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO22-Teste')
)

$ErrorActionPreference = 'Stop'
$VERSAO_GRAPH = '2.41.2'   # versao validada no laboratorio
$MODULOS = @(
    'Microsoft.Graph.Authentication',             # Connect-MgGraph
    'Microsoft.Graph.Users',                      # Get-MgUser
    'Microsoft.Graph.Groups',                     # grupos, owners e membros
    'Microsoft.Graph.Identity.DirectoryManagement', # Get-MgSubscribedSku
    'Microsoft.Graph.Identity.Governance'         # funcoes administrativas (RoleManagement)
)

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
    <# Executa o script original num pwsh separado (cada execucao e independente, como no laboratorio). #>
    param([string]$Acao, [string[]]$Extras = @())
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Copia,
        '-Acao', $Acao, '-TenantIdEsperado', $TenantIdEsperado, '-ContaEsperada', $ContaEsperada) + $Extras
    Write-Host "> 22-grupos-copilot.ps1 -Acao $Acao $($Extras -join ' ')" -ForegroundColor DarkGray
    Write-Host '  Login: abra https://microsoft.com/devicelogin, digite o codigo exibido e entre com' -ForegroundColor Cyan
    Write-Host "  $ContaEsperada (de preferencia numa janela anonima/InPrivate)." -ForegroundColor Cyan
    & (Get-Process -Id $PID).Path @argumentos
    $codigo = $LASTEXITCODE

    $pasta = Get-ChildItem -Path (Join-Path $PastaTrabalho 'evidencias\AUTO-22-Grupos-Premium-Geral') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1
    $resumo = if ($pasta) { Import-Csv (Join-Path $pasta.FullName 'resumo.csv') -ErrorAction SilentlyContinue } else { $null }
    $script:resultados.Add([pscustomobject]@{
        Acao               = "$Acao $($Extras -join ' ')".Trim()
        CodigoSaida        = $codigo
        AlteracaoExecutada = $resumo.AlteracaoExecutada
        ValidacaoAprovada  = $resumo.ValidacaoAprovada
        Observacao         = $resumo.ObservacaoValidacao
        Evidencias         = $pasta.FullName
    })
    if ($codigo -ne 0) { Write-Host "  A execucao terminou com erro (codigo $codigo). Veja a mensagem acima." -ForegroundColor Red }
}

try {
    # ------------------------------------------------------------------
    Etapa 1 'Modulos do Microsoft Graph'
    $faltando = @($MODULOS | Where-Object { -not (Get-Module -ListAvailable -Name $_ | Where-Object Version -eq $VERSAO_GRAPH) })
    if ($faltando.Count -eq 0) {
        Write-Host "Modulos do Graph $VERSAO_GRAPH ja instalados." -ForegroundColor Green
    } else {
        Write-Host "Faltam (versao $VERSAO_GRAPH): $($faltando -join ', ')"
        Write-Host 'Sao instalados so para o seu usuario (Install-Module -Scope CurrentUser), da PowerShell Gallery.' -ForegroundColor DarkGray
        if (-not (Confirmar 'Instalar agora?')) { throw 'Modulos nao instalados. Nada foi alterado.' }
        foreach ($m in $faltando) {
            Write-Host "Instalando $m $VERSAO_GRAPH..."
            Install-Module -Name $m -RequiredVersion $VERSAO_GRAPH -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        }
        Write-Host 'Modulos instalados.' -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    Etapa 2 'Tenant e conta'
    Write-Host "Tenant esperado: $TenantIdEsperado"
    Write-Host "Conta esperada:  $ContaEsperada"
    Write-Host 'O script original aborta se o login for feito em outro tenant ou com outra conta.' -ForegroundColor DarkGray
    if (-not (Confirmar 'Estes sao o tenant e a conta de DEMO?')) {
        $TenantIdEsperado = Read-Host 'Tenant ID do tenant de demo'
        $ContaEsperada = Read-Host 'Conta administradora (UPN)'
    }

    New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
    $script:Copia = Join-Path $PastaTrabalho '22-grupos-copilot.ps1'
    Copy-Item -Force (Join-Path $PSScriptRoot 'originais\22-grupos-copilot.ps1') $script:Copia
    Write-Host "Script original copiado para $PastaTrabalho (as evidencias ficam ao lado dele)."

    # ------------------------------------------------------------------
    Etapa 3 'Consultar (somente leitura)'
    Rodar-Original -Acao 'Consultar'

    # ------------------------------------------------------------------
    Etapa 4 'CriarGrupos'
    Write-Host 'Cria Copilot-Premium e Copilot-Geral (seguranca, sem e-mail), com a conta administrativa como owner.'
    Write-Host 'Nao atribui licencas e nao exclui nada.' -ForegroundColor DarkGray
    if (Confirmar 'Criar os grupos no tenant de demo?') {
        Rodar-Original -Acao 'CriarGrupos' -Extras @('-ConfirmarAlteracao')

        Etapa 5 'CriarGrupos de novo (idempotencia)'
        Write-Host 'Esperado: "Grupo ja existia; criacao ignorada" e AlteracaoExecutada = False.'
        if (Confirmar 'Rodar CriarGrupos de novo?') {
            Rodar-Original -Acao 'CriarGrupos' -Extras @('-ConfirmarAlteracao')
        }
    }

    # ------------------------------------------------------------------
    Etapa 6 'AdicionarMembro e RemoverMembro'
    Write-Host 'Use um usuario de TESTE do tenant de demo (nao a conta administrativa).'
    $upn = Read-Host 'UPN do usuario de teste (Enter para pular)'
    if ($upn) {
        if (Confirmar "Adicionar $upn aos dois grupos?") {
            Rodar-Original -Acao 'AdicionarMembro' -Extras @('-UsuarioTesteUPN', $upn, '-ConfirmarAlteracao')
        }
        if (Confirmar "Remover $upn dos dois grupos?") {
            Rodar-Original -Acao 'RemoverMembro' -Extras @('-UsuarioTesteUPN', $upn, '-ConfirmarAlteracao')
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
    $arquivo = Join-Path $PastaTrabalho "resumo-teste-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    if ($resultados.Count) { $resultados | Export-Csv -Path $arquivo -NoTypeInformation -Encoding utf8; Write-Host "Resumo salvo em $arquivo" -ForegroundColor DarkGray }
}
