# Funcoes do item "Power BI de KPIs" (AUTO-35): instalar ou atualizar um PBIX num workspace.
# Mesma logica do script proposto no relatorio (testes-manuais/originais/35-instalar-powerbi-kpis.ps1),
# validado no teste manual (17/11/2026, CRM332072, workspace LAB-AUTO35): publicacao inicial e
# atualizacao com CreateOrOverwrite sem duplicidade e com o mesmo ID. O original usa o modulo
# MicrosoftPowerBIMgmt (New-PowerBIReport -ConflictAction CreateOrOverwrite); aqui as mesmas
# operacoes vao pela API REST do Power BI com o login do instalador:
#  - GET  /v1.0/myorg/groups/{id} e /groups/{id}/reports   (Get-PowerBIWorkspace / Get-PowerBIReport)
#  - POST /v1.0/myorg/groups/{id}/imports?nameConflict=CreateOrOverwrite  (New-PowerBIReport)

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'PowerBI-KPIs'
$script:API = 'https://api.powerbi.com/v1.0/myorg'
$script:Token = $null

function Connect-PowerBiKpis {
    param([Parameter(Mandatory)][hashtable]$Entrada, [switch]$PrimeiraEtapa)
    $script:Token = Get-BizappToken -Entrada $Entrada -Nome PowerBI
    if ($PrimeiraEtapa) { return Get-BizappIdentidade -Token $script:Token }
    return Assert-BizappContexto -Token $script:Token -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta
}

function Invoke-PowerBi {
    param([string]$Metodo = 'GET', [Parameter(Mandatory)][string]$Uri, [hashtable]$Form)
    $p = @{ Method = $Metodo; Uri = $Uri; Headers = @{ Authorization = "Bearer $script:Token"; Accept = 'application/json' }; TimeoutSec = 900 }
    if ($Form) { $p.Form = $Form }
    try { Invoke-RestMethod @p } catch {
        $codigo = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        $msg = try { $e = $_.ErrorDetails.Message | ConvertFrom-Json; "$($e.error.code) $($e.error.message)".Trim() } catch { [string]$_.ErrorDetails.Message }
        if ($codigo -eq 401) { throw "O acesso ao Power BI foi negado (401). Confira se a conta tem licença Power BI Pro (ou Fabric) e rode a etapa de novo. $msg" }
        if ($codigo -eq 403) { throw "Sem permissão no workspace (403). A conta precisa ser Administrador, Membro ou Colaborador do workspace. $msg" }
        if ($codigo -eq 404) { throw "Workspace ou relatório não encontrado (404). $msg" }
        throw "Power BI (HTTP $codigo): $(if ($msg) { $msg } else { $_.Exception.Message })"
    }
}

function Get-Workspaces { return , @((Invoke-PowerBi -Uri "$script:API/groups").value) }

function Find-Workspace {
    <# Workspace pelo ID ou pelo nome exato. O original confere o nome contra o ID informado. #>
    param([object[]]$Workspaces, [string]$Texto)
    $t = ([string]$Texto).Trim()
    if (-not $t) { throw 'Informe o workspace. Nada foi publicado.' }
    $porId = @($Workspaces | Where-Object { $_.id -eq $t })
    if ($porId) { return $porId[0] }
    $porNome = @($Workspaces | Where-Object { [string]::Equals($_.name, $t, [StringComparison]::OrdinalIgnoreCase) })
    if ($porNome.Count -gt 1) { throw "Há mais de um workspace chamado '$t'. Informe o ID do workspace. Nada foi publicado." }
    if (-not $porNome) { throw "Workspace '$t' não encontrado entre os que a conta acessa. O 'Meu workspace' não é aceito. Nada foi publicado." }
    return $porNome[0]
}

function Get-Relatorios([string]$WorkspaceId) {
    return , @((Invoke-PowerBi -Uri "$script:API/groups/$WorkspaceId/reports").value | ForEach-Object {
            [pscustomobject]@{ Name = $_.name; Id = $_.id; DatasetId = $_.datasetId; WebUrl = $_.webUrl }
        })
}

function Publish-Pbix {
    <# Importa o PBIX com CreateOrOverwrite e acompanha ate terminar. Devolve o import. #>
    param([Parameter(Mandatory)][string]$WorkspaceId, [Parameter(Mandatory)][string]$Caminho)
    $arquivo = Get-Item -LiteralPath $Caminho
    # O nome do conjunto de dados inclui a extensao; o Power BI mostra o nome sem ".pbix"
    $nome = [uri]::EscapeDataString($arquivo.Name)
    $imp = Invoke-PowerBi -Metodo POST -Uri "$script:API/groups/$WorkspaceId/imports?datasetDisplayName=$nome&nameConflict=CreateOrOverwrite" -Form @{ file = $arquivo }
    $inicio = Get-Date
    while ($true) {
        Start-Sleep -Seconds 5
        $estado = Invoke-PowerBi -Uri "$script:API/groups/$WorkspaceId/imports/$($imp.id)"
        Write-BizappProgresso -Percentual ([math]::Min(90, 20 + ((Get-Date) - $inicio).TotalSeconds)) -Fase "Publicando ($($estado.importState))"
        if ($estado.importState -eq 'Succeeded') { return $estado }
        if ($estado.importState -eq 'Failed') { throw "O Power BI recusou a publicação do PBIX: $($estado.error.code) $($estado.error.details.message)" }
        if (((Get-Date) - $inicio).TotalMinutes -ge 20) { throw 'A publicação passou de 20 minutos. Confira o workspace no Power BI e rode a etapa de novo.' }
    }
}

function Write-ResumoPowerBi {
    param([string]$Pasta, [string]$Acao, [object]$Identidade, [bool]$Aprovada, [bool]$Alterou, [string]$Detalhe, [System.Collections.IDictionary]$Extras = @{})
    $resumo = [ordered]@{
        DataHora = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; Item = 'AUTO-35'; Controle = 'Instalação do Power BI de KPIs'
        AcaoSolicitada = $Acao; TenantId = $Identidade.TenantId; Conta = $Identidade.Conta
    }
    foreach ($k in $Extras.Keys) { $resumo[$k] = $Extras[$k] }
    $resumo.AlteracaoExecutada = $Alterou
    $resumo.StatusFinal = $(if ($Aprovada) { 'APROVADO_COM_EVIDENCIAS' } else { 'REPROVADO_COM_FALHA' })
    $resumo.Detalhe = $Detalhe
    Export-BizappEvidencia -Pasta $Pasta -Nome $(if ($Aprovada) { 'resumo.csv' } else { 'erros.csv' }) -Dados ([pscustomobject]$resumo)
    if (-not $Aprovada) { throw $Detalhe }
}

Export-ModuleMember -Variable ITEM -Function Connect-PowerBiKpis, Get-Workspaces, Find-Workspace, Get-Relatorios, Publish-Pbix, Write-ResumoPowerBi
