#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-35 · Instalar ou atualizar o PBIX no workspace (CreateOrOverwrite), como o script do
    relatorio: valida o PBIX e o workspace, grava os relatorios antes e depois, publica e confere
    que ficou exatamente um relatorio com o nome do arquivo. Exige digitar INSTALAR.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PowerBiKpis.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta'

$confirmou = ([string]$entrada.ConfirmacaoInstalar).Trim() -ceq 'INSTALAR'
Set-BizappSaida -Nome 'ConfirmacaoInstalar' -Valor ''
if (-not $confirmou) { throw 'Confira o workspace e o arquivo e digite INSTALAR no campo de confirmação. Nada foi publicado.' }

$PbixPath = ([string]$entrada.PbixPath).Trim().Trim('"')
if (-not (Test-Path -LiteralPath $PbixPath -PathType Leaf)) { throw "PBIX não localizado: $PbixPath" }
if ([IO.Path]::GetExtension($PbixPath) -ne '.pbix') { throw 'O arquivo informado não possui extensão .pbix.' }
if ((Get-Item -LiteralPath $PbixPath).Length -gt 1GB) { throw 'O PBIX passa de 1 GB, o limite desta forma de publicação. Publique pelo Power BI Desktop.' }

$id = Connect-PowerBiKpis -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Instalar'
$Workspace = Find-Workspace -Workspaces (Get-Workspaces) -Texto $entrada.Workspace
Write-BizappLog "Workspace: $($Workspace.name) ($($Workspace.id))"
$ExpectedName = [IO.Path]::GetFileNameWithoutExtension($PbixPath)

$Before = Get-Relatorios $Workspace.id
Export-BizappEvidencia -Pasta $pasta -Nome 'relatorios-antes.csv' -Dados $Before
$existente = @($Before | Where-Object Name -eq $ExpectedName)
if ($existente) { Write-BizappLog "Já existe o relatório '$ExpectedName': ele será atualizado (substituído pela versão do arquivo)." -Nivel aviso }
else { Write-BizappLog "Publicando '$ExpectedName' pela primeira vez..." }

$import = Publish-Pbix -WorkspaceId $Workspace.id -Caminho $PbixPath
($import | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $pasta 'resultado-publicacao.json') -Encoding utf8
Write-BizappProgresso -Percentual 100 -Fase 'Concluído'

$After = Get-Relatorios $Workspace.id
Export-BizappEvidencia -Pasta $pasta -Nome 'relatorios-depois.csv' -Dados $After
$Validated = @($After | Where-Object Name -eq $ExpectedName)
$aprovada = $Validated.Count -eq 1
if ($aprovada -and $existente) { $aprovada = $Validated[0].Id -eq $existente[0].Id }
$detalhe = if (-not $aprovada) { "A validação esperava um relatório chamado '$ExpectedName' e encontrou $($Validated.Count)$(if ($existente -and $Validated) { ' (com outro ID)' })." }
elseif ($existente) { "Relatório '$ExpectedName' atualizado, sem duplicidade." }
else { "Relatório '$ExpectedName' publicado." }
if ($aprovada) {
    Write-BizappLog "$detalhe Conferido no workspace." -Nivel sucesso
    Write-BizappLog 'Fontes, credenciais e gateway do modelo semântico são configurados à parte, no Power BI.' -Nivel discreto
    Set-BizappSaida -Nome 'EstadoRelatorio' -Valor "$ExpectedName · $($Workspace.name) · $(if ($existente) { 'atualizado' } else { 'publicado' })"
    Set-BizappSaida -Nome 'LinkRelatorio' -Valor $Validated[0].WebUrl
}
Write-ResumoPowerBi -Pasta $pasta -Acao 'Instalar' -Identidade $id -Aprovada $aprovada -Alterou $true -Detalhe $detalhe `
    -Extras ([ordered]@{ WorkspaceName = $Workspace.name; WorkspaceId = $Workspace.id; PbixPath = (Resolve-Path -LiteralPath $PbixPath).Path
        ReportName = $(if ($Validated) { $Validated[0].Name }); ReportId = $(if ($Validated) { $Validated[0].Id }); ConflictAction = 'CreateOrOverwrite' })
