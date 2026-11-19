# OBJETIVO:
# Publicar ou atualizar o BI "tudo em 1" em um workspace Power BI parametrizado.
# FERRAMENTA: MicrosoftPowerBIMgmt 1.3.84.
# PERMISSÃO: acesso ao tenant e função de escrita no workspace.
# LICENÇA: Power BI/Fabric compatível com o workspace e o relatório.
# EFEITO: cria ou sobrescreve um relatório no workspace informado.
# RECURSO-ALVO: workspace Power BI definido por parâmetro.
# PARÂMETROS EDITÁVEIS: TenantId, WorkspaceId, WorkspaceName, PbixPath, EvidenceRoot.
# EVIDÊNCIAS: contexto, relatórios antes/depois, resultado da publicação e resumo.
# RISCOS: CreateOrOverwrite substitui um relatório existente com o mesmo nome.
# ATENÇÃO: executar somente após aprovação do PBIX e confirmação do workspace-alvo.
 
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$TenantId,
    [Parameter(Mandatory)] [string]$WorkspaceId,
    [Parameter(Mandatory)] [string]$WorkspaceName,
    [Parameter(Mandatory)] [string]$PbixPath,
    [string]$EvidenceRoot = '.\evidencias\AUTO-35-Publicacao-PowerBI'
)
 
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ModuleVersion = '1.3.84'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$EvidenceFolder = Join-Path $EvidenceRoot $Timestamp
$TranscriptStarted = $false
 
try {
    New-Item -Path $EvidenceFolder -ItemType Directory -Force | Out-Null
    Start-Transcript -Path (Join-Path $EvidenceFolder 'execucao.log') -Force | Out-Null
    $TranscriptStarted = $true
 
    if (-not (Test-Path -LiteralPath $PbixPath -PathType Leaf)) {
        throw "PBIX não localizado: $PbixPath"
    }
    if ([IO.Path]::GetExtension($PbixPath) -ne '.pbix') {
        throw 'O arquivo informado não possui extensão .pbix.'
    }
 
    Remove-Module MicrosoftPowerBIMgmt* -Force -ErrorAction SilentlyContinue
    Import-Module MicrosoftPowerBIMgmt -RequiredVersion $ModuleVersion -Force
 
    Disconnect-PowerBIServiceAccount -ErrorAction SilentlyContinue
    Connect-PowerBIServiceAccount -Tenant $TenantId -ErrorAction Stop | Out-Null
 
    $Workspace = Get-PowerBIWorkspace -Id $WorkspaceId -ErrorAction Stop
    if ($Workspace.Name -ne $WorkspaceName) {
        throw "Workspace divergente. Esperado: $WorkspaceName. Encontrado: $($Workspace.Name)."
    }
 
    $Before = @(Get-PowerBIReport -WorkspaceId $WorkspaceId -ErrorAction Stop)
    $Before | Select-Object Name, Id, DatasetId, WebUrl |
        Export-Csv (Join-Path $EvidenceFolder 'relatorios-antes.csv') -Encoding UTF8
 
    New-PowerBIReport -Path $PbixPath -WorkspaceId $WorkspaceId -ConflictAction CreateOrOverwrite -ErrorAction Stop | Out-Null
 
    $After = @(Get-PowerBIReport -WorkspaceId $WorkspaceId -ErrorAction Stop)
    $After | Select-Object Name, Id, DatasetId, WebUrl |
        Export-Csv (Join-Path $EvidenceFolder 'relatorios-depois.csv') -Encoding UTF8
 
    $ExpectedName = [IO.Path]::GetFileNameWithoutExtension($PbixPath)
    $Validated = @($After | Where-Object Name -eq $ExpectedName)
    if ($Validated.Count -ne 1) {
        throw "A validação esperava um relatório chamado '$ExpectedName' e encontrou $($Validated.Count)."
    }
 
    [PSCustomObject]@{
        DataHora = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        TenantId = $TenantId
        WorkspaceName = $Workspace.Name
        WorkspaceId = $Workspace.Id
        PbixPath = (Resolve-Path $PbixPath).Path
        ReportName = $Validated[0].Name
        ReportId = $Validated[0].Id
        ConflictAction = 'CreateOrOverwrite'
        StatusFinal = 'APROVADO_COM_EVIDENCIAS'
        EvidenceFolder = $EvidenceFolder
    } | Export-Csv (Join-Path $EvidenceFolder 'resumo.csv') -NoTypeInformation -Encoding UTF8
}
catch {
    [PSCustomObject]@{
        DataHora = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        StatusFinal = 'REPROVADO_COM_FALHA'
        Mensagem = $_.Exception.Message
        EvidenceFolder = $EvidenceFolder
    } | Export-Csv (Join-Path $EvidenceFolder 'erros.csv') -NoTypeInformation -Encoding UTF8
    throw
}
finally {
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
}
