#Requires -Version 7.0
<#
.SYNOPSIS
    Teste manual do AUTO-33 (politica de Acesso Condicional "MFA Copilot" para os grupos
    Copilot-Premium e Copilot-Geral) no tenant de demo, rodando o script ORIGINAL sem alteracoes.

.DESCRIPTION
    O roteiro prepara o ambiente e chama o script original (originais/33-mfa-copilot.ps1)
    com os parametros do tenant de demo, na ordem do guia:
      0. Pre-checagem (somente leitura): licenca Entra ID P1/P2 e "padroes de seguranca"
      1. Consultar (somente leitura)
      2. Previsualizar (gera o corpo da politica, sem alterar nada)
      3. CriarReportOnly (cria a politica SOMENTE em modo de relatorio - nao bloqueia ninguem)
      4. CriarReportOnly de novo (prova de idempotencia: nao pode duplicar)
      5. Habilitar + Desabilitar (OPCIONAL, so com conta de emergencia)
      6. Reverter (exclui a politica criada pelo teste)
    Cada acao pede confirmacao antes. O script original:
      - faz login no Microsoft Graph por codigo de dispositivo A CADA execucao;
      - confere tenant e conta e aborta se forem outros;
      - exige os grupos do AUTO-22 criados e unicos;
      - exclui sempre a conta administrativa (e as contas de emergencia) da politica;
      - grava uma pasta de evidencias por execucao (aqui, em Downloads\AUTO33-Teste\evidencias).

    IMPORTANTE: o script original traz um PolicyIdConhecido fixo do laboratorio. Neste roteiro
    ele e passado vazio; senao a criacao seria bloqueada ("ID conhecido nao resolvido").

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Teste-AUTO33.ps1
#>
param(
    # Tenant e conta de demo usados nos testes anteriores (Environment Routing e AUTO-22)
    [string]$TenantIdEsperado = '4c078364-25b9-4ecd-9ace-b9def6d83e2a',
    [string]$ContaEsperada = 'admin@crm202149.onmicrosoft.com',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO33-Teste')
)

$ErrorActionPreference = 'Stop'
$VERSAO_GRAPH = '2.41.2'   # mesma versao do AUTO-22
$MODULOS = @(
    'Microsoft.Graph.Authentication',   # Connect-MgGraph
    'Microsoft.Graph.Users',            # Get-MgUser
    'Microsoft.Graph.Groups',           # Get-MgGroup
    'Microsoft.Graph.Identity.SignIns'  # *-MgIdentityConditionalAccessPolicy
)
$JUSTIFICATIVA = 'Teste manual do Readiness Deploy Accelerator no tenant de demo'

function Etapa([string]$Numero, [string]$Titulo) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host " ETAPA $Numero - $Titulo" -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
}

function Confirmar([string]$Pergunta) {
    return (Read-Host "$Pergunta (S/N)") -match '^[sS]'
}

function Aviso-Login {
    Write-Host '  Login: abra https://microsoft.com/devicelogin, digite o codigo exibido e entre com' -ForegroundColor Cyan
    Write-Host "  $ContaEsperada (de preferencia numa janela anonima/InPrivate)." -ForegroundColor Cyan
    Write-Host '  Se a tela parecer parada, aperte Esc: clicar/selecionar texto na janela pausa a saida.' -ForegroundColor DarkGray
}

$resultados = [System.Collections.Generic.List[object]]::new()
$script:Emergencia = ''

function Rodar-Original {
    <# Executa o script original num pwsh separado (cada execucao e independente, como no laboratorio). #>
    param([string]$Acao, [string[]]$Extras = @())
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Copia,
        '-Acao', $Acao, '-TenantIdEsperado', $TenantIdEsperado, '-ContaEsperada', $ContaEsperada,
        '-PolicyIdConhecido', '')   # vazio: o ID fixo do laboratorio bloquearia a criacao aqui
    # A conta de emergencia vai em TODAS as execucoes: ela faz parte do desenho validado da politica
    # (se a politica for criada sem ela, Habilitar/Reverter com ela acusam "configuracao invalida").
    if ($script:Emergencia) { $argumentos += @('-EmergencyAccessUPNs', $script:Emergencia) }
    $argumentos += $Extras

    Write-Host "> 33-mfa-copilot.ps1 -Acao $Acao $($Extras -join ' ')" -ForegroundColor DarkGray
    Aviso-Login
    # A saida passa por aqui para copiar o codigo de login para a area de transferencia:
    # assim nao e preciso selecionar texto na janela (selecionar congela a saida do console).
    & (Get-Process -Id $PID).Path @argumentos 2>&1 | ForEach-Object {
        $linha = "$_"
        Write-Host $linha
        if ($linha -match 'enter the code ([A-Z0-9]+)') {
            Set-Clipboard -Value $Matches[1]
            Write-Host "  >> Codigo $($Matches[1]) COPIADO. Cole na pagina de login (Ctrl+V)." -ForegroundColor Green
        }
    }
    $codigo = $LASTEXITCODE

    $pasta = Get-ChildItem -Path (Join-Path $PastaTrabalho 'evidencias\AUTO-33-MFA-Copilot') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1
    # resumo.csv so existe quando a execucao termina; erros.csv so quando falha.
    function Ler-Csv([string]$Nome) {
        if (-not $pasta) { return $null }
        $caminho = Join-Path $pasta.FullName $Nome
        if (Test-Path -LiteralPath $caminho) { Import-Csv -LiteralPath $caminho } else { $null }
    }
    $resumo = Ler-Csv 'resumo.csv'
    $erro = Ler-Csv 'erros.csv'
    $script:resultados.Add([pscustomobject]@{
        Acao               = $Acao
        CodigoSaida        = $codigo
        EstadoAntes        = $resumo.PolicyStateBefore
        EstadoDepois       = $resumo.PolicyStateAfter
        AlteracaoExecutada = $resumo.AlteracaoExecutada
        QualityGate        = $resumo.QualityGate
        Erro               = $erro.Mensagem
        Evidencias         = $pasta.FullName
    })
    if ($codigo -ne 0) { Write-Host "  A execucao terminou com erro (codigo $codigo). Veja a mensagem acima." -ForegroundColor Red }
    return ($codigo -eq 0)
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
    Etapa 2 'Tenant, conta e conta de emergencia'
    Write-Host "Tenant esperado: $TenantIdEsperado"
    Write-Host "Conta esperada:  $ContaEsperada"
    Write-Host 'O script original aborta se o login for feito em outro tenant ou com outra conta.' -ForegroundColor DarkGray
    if (-not (Confirmar 'Estes sao o tenant e a conta de DEMO?')) {
        $TenantIdEsperado = Read-Host 'Tenant ID do tenant de demo'
        $ContaEsperada = Read-Host 'Conta administradora (UPN)'
    }
    Write-Host ''
    Write-Host 'Conta de emergencia (break-glass): uma SEGUNDA conta administrativa que fica fora da politica.'
    Write-Host 'Sem ela, o teste para no modo de relatorio (Habilitar fica bloqueado pelo proprio script).' -ForegroundColor DarkGray
    Write-Host 'Ela e excluida da politica desde a criacao, por isso e pedida agora.' -ForegroundColor DarkGray
    $script:Emergencia = (Read-Host 'UPN da conta de emergencia (Enter para nao usar)').Trim()

    New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
    $script:Copia = Join-Path $PastaTrabalho '33-mfa-copilot.ps1'
    Copy-Item -Force (Join-Path $PSScriptRoot 'originais\33-mfa-copilot.ps1') $script:Copia
    Write-Host "Script original copiado para $PastaTrabalho (as evidencias ficam ao lado dele)."

    # ------------------------------------------------------------------
    Etapa 3 'Pre-checagem: licenca e padroes de seguranca (somente leitura)'
    Write-Host 'Nao faz parte do script original. Le duas coisas que impedem a criacao da politica:'
    Write-Host '  - licenca Microsoft Entra ID P1 ou P2 no tenant;'
    Write-Host '  - "padroes de seguranca" (security defaults) ligados: com eles ligados o Entra nao aceita'
    Write-Host '    politicas de Acesso Condicional.'
    Write-Host 'Nada e alterado aqui.' -ForegroundColor DarkGray
    if (Confirmar 'Rodar a pre-checagem (mais um login)?') {
        Import-Module Microsoft.Graph.Authentication -RequiredVersion $VERSAO_GRAPH
        Aviso-Login
        Connect-MgGraph -TenantId $TenantIdEsperado -Scopes 'Policy.Read.All', 'Organization.Read.All' `
            -ContextScope Process -UseDeviceCode -NoWelcome
        try {
            $ctx = Get-MgContext
            Write-Host "Conectado como $($ctx.Account) (tenant $($ctx.TenantId))."

            $skus = (Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus').value
            $p1 = @(foreach ($s in $skus) {
                foreach ($p in $s.servicePlans) {
                    if ($p.servicePlanName -in 'AAD_PREMIUM', 'AAD_PREMIUM_P2' -and $p.provisioningStatus -eq 'Success') {
                        [pscustomobject]@{ Sku = $s.skuPartNumber; Plano = $p.servicePlanName
                            Ativas = $s.prepaidUnits.enabled; Status = $s.capabilityStatus }
                    }
                }
            })
            if ($p1.Count) {
                Write-Host 'Licenca Entra ID P1/P2: ENCONTRADA' -ForegroundColor Green
                $p1 | Format-Table -AutoSize | Out-Host
            } else {
                Write-Host 'Licenca Entra ID P1/P2: NAO ENCONTRADA - a criacao da politica deve falhar.' -ForegroundColor Yellow
            }

            $sd = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy'
            if ($sd.isEnabled) {
                Write-Host 'Padroes de seguranca: LIGADOS - a criacao da politica deve falhar.' -ForegroundColor Yellow
                Write-Host '  Para testar, desligue em Entra > Visao geral > Propriedades > Gerenciar padroes de seguranca.' -ForegroundColor DarkGray
                Write-Host '  (O roteiro NAO desliga sozinho: e uma decisao de seguranca do tenant.)' -ForegroundColor DarkGray
            } else {
                Write-Host 'Padroes de seguranca: desligados' -ForegroundColor Green
            }

            $cas = (Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?$select=displayName,state').value
            Write-Host "Politicas de Acesso Condicional existentes: $(@($cas).Count)"
            foreach ($c in $cas) { Write-Host "  - $($c.displayName) [$($c.state)]" -ForegroundColor DarkGray }
        } finally {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
        if (-not (Confirmar 'Seguir com o teste?')) { throw 'Teste interrompido apos a pre-checagem. Nada foi alterado.' }
    }

    # ------------------------------------------------------------------
    Etapa 4 'Consultar (somente leitura)'
    Write-Host 'Esperado: grupos Copilot-Premium e Copilot-Geral encontrados (unicos) e politica "MFA Copilot" ausente.'
    $null = Rodar-Original -Acao 'Consultar'

    # ------------------------------------------------------------------
    Etapa 5 'Previsualizar (somente leitura)'
    Write-Host 'Gera corpo-proposto.json na pasta de evidencias, sem alterar o tenant.'
    $null = Rodar-Original -Acao 'Previsualizar'

    # ------------------------------------------------------------------
    Etapa 6 'CriarReportOnly'
    Write-Host 'Cria a politica "MFA Copilot" em MODO DE RELATORIO: apenas registra quem seria cobrado de MFA,'
    Write-Host 'nao bloqueia nem pede MFA a ninguem. Alvo: os dois grupos, no Office 365, todos os tipos de cliente.'
    Write-Host "Excluidas: $ContaEsperada$(if ($script:Emergencia) { " e $($script:Emergencia)" })." -ForegroundColor DarkGray
    $criada = $false
    if (Confirmar 'Criar a politica em modo de relatorio?') {
        $criada = Rodar-Original -Acao 'CriarReportOnly' -Extras @('-ConfirmarAlteracao', '-Justificativa', $JUSTIFICATIVA)

        if ($criada) {
            Etapa 7 'CriarReportOnly de novo (idempotencia)'
            Write-Host 'Esperado: "Politica ja existente e valida" e AlteracaoExecutada = False.'
            if (Confirmar 'Rodar CriarReportOnly de novo?') {
                $null = Rodar-Original -Acao 'CriarReportOnly' -Extras @('-ConfirmarAlteracao', '-Justificativa', $JUSTIFICATIVA)
            }
        }
    }

    # ------------------------------------------------------------------
    if ($criada) {
        Etapa 8 'Habilitar e Desabilitar (opcional)'
        if (-not $script:Emergencia) {
            Write-Host 'Pulado: sem conta de emergencia o script original bloqueia Habilitar.' -ForegroundColor DarkGray
        } else {
            Write-Host 'ATENCAO: habilitada, a politica PASSA A EXIGIR MFA dos membros dos dois grupos ao entrar' -ForegroundColor Yellow
            Write-Host 'no Office 365. As contas excluidas acima continuam fora. Logo depois o roteiro desabilita.' -ForegroundColor Yellow
            if (Confirmar 'Habilitar a politica no tenant de demo?') {
                $null = Rodar-Original -Acao 'Habilitar' -Extras @('-ConfirmarAlteracao', '-Justificativa', $JUSTIFICATIVA,
                    '-ConfirmacaoRisco', 'HABILITAR-MFA-COPILOT')
            }
            if (Confirmar 'Desabilitar a politica (fica criada, mas sem efeito)?') {
                $null = Rodar-Original -Acao 'Desabilitar' -Extras @('-ConfirmarAlteracao', '-Justificativa', $JUSTIFICATIVA)
            }
        }

        # ------------------------------------------------------------------
        Etapa 9 'Reverter'
        Write-Host 'Exclui a politica "MFA Copilot" (so se ela bater com o desenho do script).'
        Write-Host 'Se preferir deixar a politica no tenant para ver o relatorio no Entra, responda N.' -ForegroundColor DarkGray
        if (Confirmar 'Excluir a politica criada pelo teste?') {
            $null = Rodar-Original -Acao 'Reverter' -Extras @('-ConfirmarAlteracao', '-Justificativa', $JUSTIFICATIVA,
                '-ConfirmacaoRisco', 'REMOVER-MFA-COPILOT')
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
