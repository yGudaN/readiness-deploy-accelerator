#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-34 · Relatorios de governanca de acesso e coleta de atividade (SharePoint Advanced
    Management): HabilitarColeta, DesabilitarColeta, IniciarRelatorioAtividade (sites e itens),
    IniciarBaselinePermissoes, IniciarSnapshotDetalhadoEEEU, ConsultarRelatorio, ExportarRelatorio.
    Sem o SharePoint Advanced Management o SharePoint recusa ("experimental feature"): o script
    para com o status "Bloqueado" e nada e alterado.
    ATENCAO: so a recusa sem licenca foi testada no tenant de demo; o caminho com licenca segue o
    script original e ainda precisa de teste num tenant com o recurso.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SharePointCompartilhamento.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'AcaoGovernanca'
$inicio = Get-Date

$mapa = @{
    'relatorio-permissoes' = 'IniciarBaselinePermissoes'
    'ligar-coleta'         = 'HabilitarColeta'
    'desligar-coleta'      = 'DesabilitarColeta'
    'relatorio-atividade'  = 'IniciarRelatorioAtividade'
    'snapshot-todos'       = 'IniciarSnapshotDetalhadoEEEU'
    'consultar-relatorio'  = 'ConsultarRelatorio'
    'baixar-relatorio'     = 'ExportarRelatorio'
}
$acao = $mapa[[string]$entrada.AcaoGovernanca]
if (-not $acao) { throw "Opção inválida: $($entrada.AcaoGovernanca)" }

# ID do relatorio: so para consultar/baixar (no original a falta do ID nao era barrada)
$reportId = [guid]::Empty
if ($acao -in 'ConsultarRelatorio', 'ExportarRelatorio') {
    if (-not [guid]::TryParse([string]$entrada.ReportId, [ref]$reportId) -or $reportId -eq [guid]::Empty) {
        throw 'Informe o ID do relatório (aparece depois de iniciar um relatório).'
    }
}

$ctx = Connect-SharePointCompartilhamento -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao $acao
$justificativa = 'Executado pelo Readiness Deploy Accelerator'
Write-ContextoEvidencias -Pasta $pasta -Ctx $ctx -Acao $acao -Justificativa $justificativa
$nomeRelatorio = "Readiness-Compartilhamento-$(Get-Date -Format 'yyyyMMdd-HHmm')"

$acoes = [System.Collections.Generic.List[object]]::new()
$relatorios = [System.Collections.Generic.List[object]]::new()
$gate = 'Falha'
$extras = @{}
try {
    switch ($acao) {
        { $_ -in 'HabilitarColeta', 'DesabilitarColeta' } {
            $antes = [System.Collections.Generic.List[object]]::new(); $depois = [System.Collections.Generic.List[object]]::new()
            $esperado = if ($acao -eq 'HabilitarColeta') { 'InProgress' } else { 'Paused' }
            foreach ($ent in (Get-ActivityEntities 'Ambos')) {
                $a = Get-CollectionStatusValue (Get-SPOAuditDataCollectionStatusForActivityInsights -ReportEntity $ent -ErrorAction Stop)
                $antes.Add([pscustomobject]@{ ReportEntity = $ent; Status = $a })
                if ($a -eq $esperado) {
                    Write-BizappLog "$ent`: já estava $(Get-TextoColeta $a)." -Nivel discreto
                } elseif ($acao -eq 'HabilitarColeta') {
                    Start-SPOAuditDataCollectionForActivityInsights -ReportEntity $ent -ErrorAction Stop
                } else {
                    Stop-SPOAuditDataCollectionForActivityInsights -ReportEntity $ent -ErrorAction Stop
                }
                $d = Get-CollectionStatusValue (Get-SPOAuditDataCollectionStatusForActivityInsights -ReportEntity $ent -ErrorAction Stop)
                $depois.Add([pscustomobject]@{ ReportEntity = $ent; Status = $d })
                $acoes.Add([pscustomobject]@{ Acao = $acao; ReportEntity = $ent; Antes = $a; Depois = $d; Justificativa = $justificativa })
            }
            Export-BizappEvidencia -Pasta $pasta -Nome 'coleta-antes.csv' -Dados @($antes)
            Export-BizappEvidencia -Pasta $pasta -Nome 'coleta-depois.csv' -Dados @($depois)
            $ok = @($depois | Where-Object Status -ne $esperado).Count -eq 0
            $gate = if ($ok) { if ($acao -eq 'HabilitarColeta') { 'Aprovado - coleta em andamento' } else { 'Aprovado - coleta pausada' } } else { 'Parcial - revisar estado da coleta' }
            Set-BizappSaida -Nome 'ColetaAtividade' -Valor (Get-TextoColeta $depois[0].Status)
            if ($acao -eq 'HabilitarColeta') { Write-BizappLog 'Coleta ligada. Os relatórios de atividade precisam de pelo menos 24 horas de coleta.' -Nivel sucesso }
            else { Write-BizappLog 'Coleta desligada.' -Nivel sucesso }
        }
        'IniciarRelatorioAtividade' {
            foreach ($ent in (Get-ActivityEntities 'Ambos')) {
                $st = Get-CollectionStatusValue (Get-SPOAuditDataCollectionStatusForActivityInsights -ReportEntity $ent -ErrorAction Stop)
                if ($st -ne 'InProgress' -and -not $ctx.TemSamPorLicenca) {
                    throw "A coleta de atividade não está ligada ($(Get-TextoColeta $st)). Ligue a coleta e aguarde pelo menos 24 horas antes do relatório."
                }
                $criado = Start-SPODataAccessGovernanceInsight -ReportEntity $ent -Workload SharePoint -ReportType RecentActivity -Name $nomeRelatorio -ErrorAction Stop
                $relatorios.Add((Convert-DagReportToEvidence $criado "Relatório de atividade ($ent)"))
            }
        }
        'IniciarBaselinePermissoes' {
            $criado = Start-SPODataAccessGovernanceInsight -ReportEntity PermissionedUsers -Workload SharePoint -ReportType Snapshot `
                -Name $nomeRelatorio -CountOfUsersMoreThan 0 -ErrorAction Stop
            $relatorios.Add((Convert-DagReportToEvidence $criado 'Baseline de permissões'))
        }
        'IniciarSnapshotDetalhadoEEEU' {
            if (-not $ctx.AdminSam) { throw 'O relatório detalhado de "Todos" exige a função Administrador do SharePoint Advanced Management.' }
            $base = @(Get-SPODataAccessGovernanceInsight -ReportEntity PermissionedUsers -Workload SharePoint -ReportType Snapshot -ErrorAction Stop)
            if (-not $base.Count) { throw 'Gere antes o relatório de permissões dos sites (pelo menos uma vez).' }
            $criado = Start-SPODataAccessGovernanceInsight -ReportEntity EveryoneExceptExternalUsers -ReportType Snapshot -ErrorAction Stop
            $relatorios.Add((Convert-DagReportToEvidence $criado 'Snapshot detalhado Everyone/EEEU'))
        }
        'ConsultarRelatorio' {
            $r = Get-SPODataAccessGovernanceInsight -ReportID $reportId -ErrorAction Stop
            $relatorios.Add((Convert-DagReportToEvidence $r 'Consulta por ReportId'))
            Write-BizappLog "Relatório $reportId · status: $($relatorios[0].Status)" -Nivel sucesso
            $gate = 'Aprovado - relatório consultado'
        }
        'ExportarRelatorio' {
            $r = Get-SPODataAccessGovernanceInsight -ReportID $reportId -ErrorAction Stop
            $ev = Convert-DagReportToEvidence $r 'Exportação por ReportId'
            $relatorios.Add($ev)
            if ($ev.Status -notmatch 'Completed|Available|Ready') { throw "O relatório ainda não está concluído. Status atual: $($ev.Status)" }
            Export-SPODataAccessGovernanceInsight -ReportID $reportId -DownloadPath $pasta -ErrorAction Stop
            Write-BizappLog "Relatório baixado na pasta de evidências: $pasta" -Nivel sucesso
            $extras.DiretorioExportacao = $pasta
            $gate = 'Aprovado - relatório exportado'
        }
    }
} catch {
    if (Test-ErroSemSam $_) {
        Write-BizappLog 'SharePoint Advanced Management não encontrado neste tenant (licença ou recurso).' -Nivel aviso
        Set-BizappSaida -Nome 'RecursoSam' -Valor 'Não encontrado (licença ou recurso)'
        Export-BizappEvidencia -Pasta $pasta -Nome 'resumo.csv' -Dados ([pscustomobject]@{
                Automacao = 'AUTO-34'; Acao = $acao; Inicio = $inicio; Fim = Get-Date; QualityGate = 'Bloqueado - sem SharePoint Advanced Management'
                Erro = $_.Exception.Message; PastaEvidencias = $pasta })
        throw $MENSAGEM_SEM_SAM
    }
    throw
}

# Relatorio iniciado: devolve o ID para consultar/baixar depois
if ($acao -like 'Iniciar*') {
    $idCriado = @($relatorios | Where-Object ReportId | Select-Object -Last 1).ReportId
    if ($idCriado) {
        Set-BizappSaida -Nome 'ReportId' -Valor $idCriado
        Write-BizappLog "Relatório iniciado (ID $idCriado). O processamento é feito pelo SharePoint e pode levar horas; consulte o status depois com a opção ""Consultar um relatório""." -Nivel sucesso
        $gate = 'Aprovado - relatório iniciado'
    } else {
        $gate = 'Parcial - relatório iniciado sem ReportId capturado'
    }
    $extras.ReportIdIniciado = $idCriado
}
Export-BizappEvidencia -Pasta $pasta -Nome 'dag-reports.csv' -Dados @($relatorios)
Export-BizappEvidencia -Pasta $pasta -Nome 'acoes.csv' -Dados @($(if ($acoes.Count) { $acoes } else { [pscustomobject]@{ Acao = $acao; Resultado = 'Sem alteração de configuração.' } }))
Write-ResumoSharePoint -Pasta $pasta -Acao $acao -Ctx $ctx -QualityGate $gate -Inicio $inicio -Extras $extras
