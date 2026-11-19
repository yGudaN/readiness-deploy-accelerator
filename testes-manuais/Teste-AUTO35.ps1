#Requires -Version 5.1
<#
.SYNOPSIS
    Teste manual do AUTO-35 (instalar ou atualizar o Power BI de KPIs num workspace), rodando o
    script PROPOSTO no relatorio SEM alteracoes (originais/35-instalar-powerbi-kpis.ps1, extraido
    de originais/35-power-bi-relatorio.docx).

.DESCRIPTION
    O relatorio deixa pendentes os dois testes da instalacao porque o PBIX "tudo em 1" ainda nao
    existe. Este teste roda os dois com QUALQUER PBIX de teste (ex.: um relatorio em branco salvo
    no Power BI Desktop), num workspace de TESTE:
      - Teste 1, publicacao inicial: confere que o workspace nao tem o relatorio, roda o original e
        confere um relatorio com o nome do PBIX;
      - Teste 2, atualizacao: roda o original de novo (CreateOrOverwrite) e confere que nao criou
        duplicidade.
    O original faz o proprio login (Connect-PowerBIServiceAccount), valida o PBIX e o workspace,
    grava transcript, relatorios antes/depois e resumo. As evidencias ficam em
    Downloads\AUTO35-Teste\evidencias.

    Pre-requisitos: modulo MicrosoftPowerBIMgmt 1.3.84 (o teste oferece instalar), licenca Power BI
    Pro (ou Fabric) para a conta e um workspace de teste em que ela seja Admin, Membro ou
    Colaborador. O "Meu workspace" nao serve: o original valida o workspace pelo ID.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Teste-AUTO35.ps1
#>
param(
    [string]$TenantId = '6a1a0a9c-5bbb-4060-8231-08f2ad74171e',
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO35-Teste'),
    [string]$Original = (Join-Path $PSScriptRoot 'originais\35-instalar-powerbi-kpis.ps1')
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
function Ultima-Evidencia { Get-ChildItem -LiteralPath $EvidRaiz -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1 }

try {
    Etapa 'Preparacao'
    Write-Host "Original: $Original" -ForegroundColor DarkGray
    Write-Host "SHA-256:  $((Get-FileHash -Algorithm SHA256 -LiteralPath $Original).Hash)" -ForegroundColor DarkGray
    if (-not (Get-Module -ListAvailable MicrosoftPowerBIMgmt | Where-Object Version -eq '1.3.84')) {
        if ((Read-Host 'Falta o MicrosoftPowerBIMgmt 1.3.84 (pedido pelo original). Instalar para o seu usuario? (S/N)') -notmatch '^[sS]') { throw 'Modulo nao instalado. Nada foi alterado.' }
        Install-Module MicrosoftPowerBIMgmt -RequiredVersion 1.3.84 -Scope CurrentUser -Force -AllowClobber
    }
    Registrar 'Preparacao' 'MicrosoftPowerBIMgmt 1.3.84' $true

    Write-Host "Tenant: $TenantId"
    if ((Read-Host 'E o tenant de DEMO? (S/N)') -notmatch '^[sS]') { $TenantId = Read-Host 'Tenant ID' }
    Write-Host 'Workspace de TESTE: abra app.powerbi.com > Workspaces > o workspace. O ID e o trecho depois de /groups/ na URL.' -ForegroundColor Cyan
    $WorkspaceId = (Read-Host 'WorkspaceId').Trim()
    $WorkspaceName = (Read-Host 'Nome exato do workspace').Trim()
    Write-Host 'PBIX de TESTE: qualquer relatorio (ex.: em branco, salvo no Power BI Desktop). O nome do arquivo vira o nome do relatorio.' -ForegroundColor Cyan
    $PbixPath = (Read-Host 'Caminho completo do .pbix').Trim().Trim('"')
    $nomeEsperado = [IO.Path]::GetFileNameWithoutExtension($PbixPath)

    # ------------------------------------------------------------------
    Etapa 'Teste 1 - publicacao inicial'
    if ((Read-Host "Confirmo que o workspace '$WorkspaceName' e de TESTE e nao tem um relatorio '$nomeEsperado' que eu precise manter. Digite PUBLICAR") -cne 'PUBLICAR') { throw 'Cancelado. Nada foi publicado.' }
    $ok1 = $true
    try { & $Original -TenantId $TenantId -WorkspaceId $WorkspaceId -WorkspaceName $WorkspaceName -PbixPath $PbixPath -EvidenceRoot $EvidRaiz }
    catch { $ok1 = $false; Write-Host "O original parou: $($_.Exception.Message)" -ForegroundColor Red }
    $ev1 = Ultima-Evidencia
    $antes1 = @(Import-Csv (Join-Path $ev1.FullName 'relatorios-antes.csv') -ErrorAction SilentlyContinue | Where-Object Name -eq $nomeEsperado)
    $depois1 = @(Import-Csv (Join-Path $ev1.FullName 'relatorios-depois.csv') -ErrorAction SilentlyContinue | Where-Object Name -eq $nomeEsperado)
    Registrar 'Teste 1' 'Relatorio ausente antes' ($antes1.Count -eq 0) "$($antes1.Count) com o nome '$nomeEsperado'"
    Registrar 'Teste 1' 'Publicacao (resumo do original)' ($ok1 -and (Test-Path (Join-Path $ev1.FullName 'resumo.csv'))) $(if ($depois1) { "ReportId $($depois1[0].Id), DatasetId $($depois1[0].DatasetId)" } else { 'veja erros.csv' })
    if ($depois1) { Write-Host "Abra e confira: $($depois1[0].WebUrl)" -ForegroundColor Cyan }

    # ------------------------------------------------------------------
    if ($ok1) {
        Etapa 'Teste 2 - atualizacao (CreateOrOverwrite)'
        Write-Host 'Se quiser ver a troca de versao, mude algo no PBIX no Power BI Desktop e salve com o MESMO nome antes de continuar.' -ForegroundColor DarkGray
        if ((Read-Host 'Rodar a atualizacao? Digite ATUALIZAR (Enter = pular)') -ceq 'ATUALIZAR') {
            $ok2 = $true
            try { & $Original -TenantId $TenantId -WorkspaceId $WorkspaceId -WorkspaceName $WorkspaceName -PbixPath $PbixPath -EvidenceRoot $EvidRaiz }
            catch { $ok2 = $false; Write-Host "O original parou: $($_.Exception.Message)" -ForegroundColor Red }
            $ev2 = Ultima-Evidencia
            $depois2 = @(Import-Csv (Join-Path $ev2.FullName 'relatorios-depois.csv') -ErrorAction SilentlyContinue | Where-Object Name -eq $nomeEsperado)
            Registrar 'Teste 2' 'Atualizacao (resumo do original)' $ok2
            Registrar 'Teste 2' 'Sem duplicidade' ($depois2.Count -eq 1) "$($depois2.Count) relatorio(s) '$nomeEsperado'"
            if ($depois1 -and $depois2) { Registrar 'Teste 2' 'Mesmo relatorio atualizado' ($depois2[0].Id -eq $depois1[0].Id) "Id antes $($depois1[0].Id) / depois $($depois2[0].Id)" }
        }
    }
    Write-Host ''
    Write-Host 'Limpeza: se nao precisar, exclua o relatorio e o modelo semantico de teste no workspace (app.powerbi.com).' -ForegroundColor DarkGray
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
