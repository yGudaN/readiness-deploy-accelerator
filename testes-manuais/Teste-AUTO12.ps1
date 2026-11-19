#Requires -Version 5.1
<#
.SYNOPSIS
    Teste manual do AUTO-12 (MCPs e recursos para agentes) no tenant de demo, rodando o script
    ORIGINAL sem alteracoes (originais/12-mcps-recursos-agentes.ps1, v3, vindo do guia de
    automacoes) nas acoes somente leitura Validar e Consultar.

.DESCRIPTION
    O original exige, antes de rodar:
      - PAC CLI com um perfil de login valido (pac auth who) e acesso ao ambiente (pac env who);
      - os modulos Microsoft.PowerApps.Administration.PowerShell e Microsoft.PowerApps.PowerShell;
      - (opcional) uma sessao do Microsoft Graph ja aberta: ele so le Get-MgContext e, se os modulos
        Microsoft.Graph.Users / Identity.DirectoryManagement / Identity.Governance existirem,
        inventaria licencas e funcoes.
    Este teste prepara isso (perguntando antes), roda Validar e Consultar e depois:
      - [+] lista os clientes de MCP liberados no ambiente (tabela allowedmcpclient do Dataverse,
        pelo "pac env fetch"), somente leitura;
      - acompanha a validacao funcional manual no Copilot Studio (secao "Como validar" do
        relatorio): adicionar o Dataverse MCP a um agente de laboratorio e os quatro testes.
    As acoes de alteracao do original (PrepararAcesso, Criar, Atualizar, Classificar) NAO sao usadas.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Teste-AUTO12.ps1
#>
param(
    [string]$TenantId = '6a1a0a9c-5bbb-4060-8231-08f2ad74171e',
    [string]$AdminUPN = 'admin@crm332072.onmicrosoft.com',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO12-Teste'),
    [string]$Original = (Join-Path $PSScriptRoot 'originais\12-mcps-recursos-agentes.ps1')
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$carimbo = Get-Date -Format 'yyyyMMdd-HHmmss'
$LOG_TESTE = Join-Path $PastaTrabalho "teste-$carimbo.log"
$EvidRaiz = Join-Path $PastaTrabalho 'evidencias'
Start-Transcript -LiteralPath $LOG_TESTE -Force | Out-Null

$resultados = New-Object System.Collections.Generic.List[object]
function Registrar([string]$Parte, [string]$Acao, [bool]$Ok, [string]$Detalhe = '') {
    $script:resultados.Add([pscustomobject]@{ Parte = $Parte; Acao = $Acao; Sucesso = $Ok; Detalhe = $Detalhe })
    $cor = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host "  $(if ($Ok) { 'OK' } else { 'FALHOU' }) - $Parte / $Acao$(if ($Detalhe) { ": $Detalhe" })" -ForegroundColor $cor
}
function Etapa([string]$Titulo) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host " $Titulo" -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
}
function Confirmar([string]$Pergunta) { return (Read-Host "$Pergunta (S/N)") -match '^[sS]' }
function Ultimo-Resumo {
    $p = Get-ChildItem -LiteralPath $EvidRaiz -Recurse -Filter 'resumo.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($p) { return Import-Csv $p.FullName } else { return $null }
}

try {
    Etapa '1. Preparacao (modulos, Graph e PAC)'
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Rode no Windows PowerShell 5.1 (powershell.exe), como pede o original.' }
    Write-Host "Original: $Original" -ForegroundColor DarkGray
    Write-Host "SHA-256:  $((Get-FileHash -Algorithm SHA256 -LiteralPath $Original).Hash)" -ForegroundColor DarkGray

    if (-not (Get-Module -ListAvailable Microsoft.PowerApps.PowerShell)) {
        if (-not (Confirmar 'Falta o Microsoft.PowerApps.PowerShell (obrigatorio para o original). Instalar para o seu usuario?')) { throw 'Modulo obrigatorio nao instalado. Nada foi alterado.' }
        Install-Module Microsoft.PowerApps.PowerShell -Scope CurrentUser -Force -AllowClobber
    }
    Registrar 'Preparacao' 'Modulos do Power Apps' $true

    $graphVer = (Get-Module -ListAvailable Microsoft.Graph.Authentication | Sort-Object Version -Descending | Select-Object -First 1).Version
    $faltamGraph = @('Microsoft.Graph.Users', 'Microsoft.Graph.Identity.DirectoryManagement', 'Microsoft.Graph.Identity.Governance' | Where-Object { -not (Get-Module -ListAvailable $_ | Where-Object Version -eq $graphVer) })
    if ($graphVer -and $faltamGraph -and (Confirmar "Instalar $($faltamGraph -join ', ') $graphVer (opcional: licencas e funcoes nas evidencias)?")) {
        foreach ($mod in $faltamGraph) { Install-Module $mod -RequiredVersion $graphVer -Scope CurrentUser -Force -AllowClobber }
    }
    if ($graphVer -and (Confirmar 'Abrir uma sessao do Microsoft Graph so de leitura (opcional; o original usa se existir)?')) {
        Import-Module Microsoft.Graph.Authentication
        # Login por codigo de dispositivo: no Windows PowerShell 5.1 o login interativo do Graph derruba
        # o processo se a janela de login nao for concluida em 2 minutos (OperationCanceledException).
        Write-Host 'Abra https://microsoft.com/devicelogin, digite o codigo que vai aparecer e entre com a conta admin.' -ForegroundColor Cyan
        Connect-MgGraph -TenantId $TenantId -Scopes 'User.Read.All', 'Organization.Read.All', 'RoleManagement.Read.Directory' -UseDeviceCode -NoWelcome
        Registrar 'Preparacao' 'Sessao Graph' ((Get-MgContext).Account -eq $AdminUPN) (Get-MgContext).Account
    }

    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) { throw 'PAC CLI nao encontrado.' }
    Write-Host 'Environment ID do ambiente de TESTE (admin center > Ambientes > ambiente > ID do ambiente).' -ForegroundColor Cyan
    $EnvironmentId = (Read-Host 'EnvironmentId').Trim()
    Write-Host 'Perfis do PAC hoje:' -ForegroundColor DarkGray
    & pac auth list 2>&1 | Out-Host
    if (Confirmar "Criar/selecionar um perfil do PAC para este ambiente com $AdminUPN (abre o login no navegador)?") {
        & pac auth create --environment $EnvironmentId 2>&1 | Out-Host
    }

    # ------------------------------------------------------------------
    Etapa '2. Original: Validar (somente leitura)'
    $ok = $true
    try { & $Original -Acao Validar -TenantId $TenantId -AdminUPN $AdminUPN -EnvironmentId $EnvironmentId -EvidenceRoot $EvidRaiz }
    catch { $ok = $false; Write-Host "O original parou: $($_.Exception.Message)" -ForegroundColor Red }
    $r = Ultimo-Resumo
    Registrar 'Original' 'Validar' $ok "$(if ($r) { ($r | Select-Object -Last 1 | ConvertTo-Csv -NoTypeInformation | Select-Object -Last 1) })"

    Etapa '3. Original: Consultar (somente leitura)'
    $ok = $true
    try { & $Original -Acao Consultar -TenantId $TenantId -AdminUPN $AdminUPN -EnvironmentId $EnvironmentId -EvidenceRoot $EvidRaiz }
    catch { $ok = $false; Write-Host "O original parou: $($_.Exception.Message)" -ForegroundColor Red }
    $r = Ultimo-Resumo
    Registrar 'Original' 'Consultar' $ok "$(if ($r) { ($r | Select-Object -Last 1 | ConvertTo-Csv -NoTypeInformation | Select-Object -Last 1) })"

    # ------------------------------------------------------------------
    Etapa '4. [+] Clientes de MCP liberados no ambiente (somente leitura)'
    Write-Host 'Tabela allowedmcpclient do Dataverse (mesma lista de Configuracoes > Produto > Recursos > Dataverse MCP > Configuracoes avancadas).' -ForegroundColor DarkGray
    $xml = "<fetch><entity name='allowedmcpclient'><attribute name='name'/><attribute name='uniquename'/><attribute name='applicationid'/><attribute name='isenabled'/><attribute name='statecode'/></entity></fetch>"
    $saida = & pac env fetch --environment $EnvironmentId --xml $xml 2>&1 | Out-String
    Write-Host $saida
    $saida | Set-Content -Path (Join-Path $PastaTrabalho "clientes-mcp-$carimbo.txt") -Encoding UTF8
    Registrar 'Clientes MCP' 'Listar allowedmcpclient' ($saida -notmatch 'Error|Erro') 'Veja clientes-mcp-*.txt'

    # ------------------------------------------------------------------
    Etapa '5. Validacao funcional no Copilot Studio (manual)'
    Write-Host '1. Em copilotstudio.microsoft.com, NO MESMO ambiente, crie um agente de LABORATORIO (nao publique).' -ForegroundColor Cyan
    Write-Host '2. Ferramentas > Adicionar ferramenta > Model Context Protocol > Dataverse MCP Server. Crie a conexao.' -ForegroundColor Cyan
    Write-Host '3. Deixe so ferramentas de leitura (ex.: list_tables, describe_table, read_query) na primeira rodada.' -ForegroundColor Cyan
    Write-Host '4. No painel de teste, faca as quatro perguntas abaixo e confira a atividade (ferramenta, argumentos, resultado).' -ForegroundColor Cyan
    if (Confirmar 'Vai fazer a validacao funcional agora?') {
        Registrar 'Copilot Studio' 'Dataverse MCP adicionado ao agente' (Confirmar 'O Dataverse MCP aparece nas ferramentas do agente?')
        Registrar 'Copilot Studio' 'Teste 1 - descobrir metadados ("Quais tabelas existem?")' (Confirmar 'Respondeu com as tabelas?')
        Registrar 'Copilot Studio' 'Teste 2 - descrever estrutura ("Descreva a tabela conta")' (Confirmar 'Descreveu as colunas?')
        Registrar 'Copilot Studio' 'Teste 3 - consulta limitada ("Liste 3 contas, so o nome")' (Confirmar 'Trouxe so o pedido?')
        Registrar 'Copilot Studio' 'Teste 4 - pedir alteracao ("Crie uma conta X")' (Confirmar 'A alteracao foi recusada ou nao estava disponivel?')
        Write-Host 'Reversao: remova o MCP do agente e apague a conexao e o agente de laboratorio, se nao precisar mais.' -ForegroundColor DarkGray
    }
} catch {
    Write-Host ''
    Write-Host "PAROU: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Etapa 'RESUMO DO TESTE'
    if ($resultados.Count) {
        $resultados | Format-Table -AutoSize -Wrap | Out-Host
        $resultados | Export-Csv -Path (Join-Path $PastaTrabalho "resumo-teste-$carimbo.csv") -NoTypeInformation -Encoding UTF8
    } else { Write-Host 'Nada foi registrado.' }
    Write-Host "Evidencias do original: $EvidRaiz" -ForegroundColor DarkGray
    Write-Host "Log completo do teste: $LOG_TESTE" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
}
