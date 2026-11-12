# OBJETIVO:
# Validar, consultar e alterar controladamente a auditoria unificada,
# pesquisar eventos CopilotInteraction e administrar a política de
# retenção de auditoria do item AUTO-31.
#
# FERRAMENTA:
# Microsoft Graph PowerShell, Exchange Online PowerShell e
# Security & Compliance PowerShell.
#
# PERMISSÃO:
# Audit Logs ou View-Only Audit Logs para consulta.
# Audit Logs para habilitar ou desabilitar auditoria.
# Organization Configuration para criar ou alterar retenção.
#
# LICENÇA:
# Audit Standard para consulta e retenção padrão.
# Microsoft 365 E5, Office 365 E5, Microsoft Purview Suite ou
# add-on equivalente para retenção de até 12 meses.
#
# EFEITO:
# Consultar: não altera o ambiente.
# HabilitarUAL: habilita Unified Audit Log Ingestion.
# DesabilitarUAL: desabilita Unified Audit Log Ingestion.
# AplicarRetencao: cria ou atualiza política de retenção.
#
# RECURSO-ALVO:
# Unified Audit Log e política LAB-AUTO31-Retencao-Copilot.
#
# PARÂMETROS EDITÁVEIS:
# Acao, DiasPesquisa, NomePolitica, DuracaoRetencao e Prioridade.
#
# EVIDÊNCIAS:
# Transcript, contexto, módulos, licenças, permissões funcionais,
# configuração antes/depois, políticas antes/depois, eventos e resumo.
#
# RISCOS:
# Desabilitar a UAL interrompe a geração e pesquisa de registros.
# Políticas personalizadas podem alterar o período aplicável aos eventos.
#
# ATENÇÃO:
# O script não exporta AuditData bruto, prompts, respostas,
# conteúdo de mensagens, conteúdo de arquivos ou URLs acessadas.

[CmdletBinding()]
param(
    [ValidateSet(
        'Consultar',
        'HabilitarUAL',
        'DesabilitarUAL',
        'AplicarRetencao'
    )]
    [string]$Acao = 'Consultar',

    [switch]$ConfirmarAlteracao,

    [ValidateRange(1, 180)]
    [int]$DiasPesquisa = 7,

    [ValidateNotNullOrEmpty()]
    [string]$NomePolitica = 'LAB-AUTO31-Retencao-Copilot',

    [ValidateSet(
        'ThreeMonths',
        'SixMonths',
        'NineMonths',
        'TwelveMonths',
        'TenYears'
    )]
    [string]$DuracaoRetencao = 'TwelveMonths',

    [ValidateRange(1, 10000)]
    [int]$Prioridade = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\00-preflight.ps1"

$ItemId = 'AUTO-31'
$ItemNome = 'Auditoria-Copilot-UAL'
$AlteracaoSolicitada = $Acao -ne 'Consultar'

if ($AlteracaoSolicitada -and -not $ConfirmarAlteracao) {
    throw @"
A ação $Acao altera configurações do tenant.

Execute novamente acrescentando:
-ConfirmarAlteracao

Nenhuma alteração foi realizada.
"@
}

$EvidenceRoot = Join-Path `
    -Path $PSScriptRoot `
    -ChildPath 'evidencias'

$ItemEvidenceRoot = Join-Path `
    -Path $EvidenceRoot `
    -ChildPath "$ItemId-$ItemNome"

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$EvidenceFolder = Join-Path `
    -Path $ItemEvidenceRoot `
    -ChildPath $Timestamp

New-Item `
    -Path $EvidenceFolder `
    -ItemType Directory `
    -Force |
    Out-Null

$TranscriptPath = Join-Path `
    -Path $EvidenceFolder `
    -ChildPath 'execucao.log'

$ContextPath = Join-Path `
    -Path $EvidenceFolder `
    -ChildPath 'contexto.csv'

$CommandsPath = Join-Path `
    -Path $EvidenceFolder `
    -ChildPath 'modulos-comandos.csv'

$LicensesPath = Join-Path `
    -Path $EvidenceFolder `
    -ChildPath 'licencas-conta.csv'

$PermissionsPath = Join-Path `
    -Path $EvidenceFolder `
    -ChildPath 'permissoes-funcionais.csv'

$ConfigBeforePath = Join-Path `
    -Path $EvidenceFolder `
    -ChildPath 'configuracao-antes.csv'

$ConfigAfterPath = Join-Path `
    -Path $EvidenceFolder `
    -ChildPath 'configuracao-depois.csv'

$PoliciesBeforePath = Join-Path `
    -Path $EvidenceFolder `
    -ChildPath 'politicas-antes.csv'

$PoliciesAfterPath = Join-Path `
    -Path $EvidenceFolder `
    -ChildPath 'politicas-depois.csv'

$EventsPath = Join-Path `
    -Path $EvidenceFolder `
    -ChildPath 'eventos-copilot.csv'

$SummaryPath = Join-Path `
    -Path $EvidenceFolder `
    -ChildPath 'resumo.csv'

function Export-CsvEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$EmptyMessage
    )

    $ObjectsToExport = @()

    if ($null -ne $InputObject) {
        $ObjectsToExport = @(
            $InputObject |
                Where-Object { $null -ne $_ }
        )
    }

    if ($ObjectsToExport.Count -gt 0) {
        $ObjectsToExport |
            Export-Csv `
                -LiteralPath $Path `
                -NoTypeInformation `
                -Encoding utf8

        return
    }

    [PSCustomObject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime()
        Resultado = 'Sem registros'
        Quantidade = 0
        Observacao = $EmptyMessage
    } |
        Export-Csv `
            -LiteralPath $Path `
            -NoTypeInformation `
            -Encoding utf8
}

$TranscriptStarted = $false
$ValidationApproved = $false
$ChangeExecuted = $false
$SearchStatus = 'Não executada'
$SearchMessage = ''
$ErrorMessage = ''

$BeforeConfig = $null
$AfterConfig = $null
$ExchangeConnection = $null
$PurviewConnection = $null
$GraphContext = $null

$PoliciesBefore = @()
$PoliciesAfter = @()
$NormalizedEvents = @()

try {
    Start-Transcript `
        -LiteralPath $TranscriptPath `
        -Force |
        Out-Null

    $TranscriptStarted = $true

    Write-Host ''
    Write-Host '====================================================='
    Write-Host ' AUTO-31 - AUDITORIA COPILOT E UAL'
    Write-Host '====================================================='
    Write-Host "Ação: $Acao"
    Write-Host "Tenant esperado: $TenantId"
    Write-Host "Conta esperada: $AdminUPN"
    Write-Host "Evidências: $EvidenceFolder"
    Write-Host ''

    # ================================================================
    # VALIDAR GRAPH
    # ================================================================
    Write-Host '==> Validando Microsoft Graph'

    $GraphContext = Get-MgContext

    if ($null -eq $GraphContext) {
        throw @'
Não existe conexão ativa com Microsoft Graph.

Execute primeiro:
.\01-conectar-graph.ps1

Use a mesma sessão PowerShell.
'@
    }

    if (-not [string]::Equals(
        [string]$GraphContext.TenantId,
        [string]$TenantId,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw @"
A sessão Graph pertence a outro tenant.

Esperado:
$TenantId

Autenticado:
$($GraphContext.TenantId)
"@
    }

    if (-not [string]::Equals(
        [string]$GraphContext.Account,
        [string]$AdminUPN,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw @"
A sessão Graph pertence a outra conta.

Esperada:
$AdminUPN

Autenticada:
$($GraphContext.Account)
"@
    }

    # ================================================================
    # VALIDAR SESSÕES EXCHANGE E PURVIEW
    # ================================================================
    Write-Host '==> Validando sessões Exchange e Purview'

    $AllConnections = @(Get-ConnectionInformation)

    $ExchangeConnection = $AllConnections |
        Where-Object {
            $_.State -eq 'Connected' -and
            $_.IsEopSession -eq $false
        } |
        Select-Object -Last 1

    $PurviewConnection = $AllConnections |
        Where-Object {
            $_.State -eq 'Connected' -and
            $_.IsEopSession -eq $true
        } |
        Select-Object -Last 1

    if ($null -eq $ExchangeConnection) {
        throw @'
Não existe conexão ativa com Exchange Online.

Execute:
.\04-conectar-exchange.ps1

Use a mesma sessão PowerShell.
'@
    }

    if ($null -eq $PurviewConnection) {
        throw @'
Não existe conexão ativa com Security & Compliance.

Execute:
.\05-conectar-purview.ps1

Use a mesma sessão PowerShell.
'@
    }

    foreach ($Connection in @(
        $ExchangeConnection,
        $PurviewConnection
    )) {
        if (-not [string]::Equals(
            [string]$Connection.TenantID,
            [string]$TenantId,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw @"
Uma sessão administrativa pertence a outro tenant.

Tenant esperado:
$TenantId

Tenant identificado:
$($Connection.TenantID)
"@
        }

        if (-not [string]::Equals(
            [string]$Connection.UserPrincipalName,
            [string]$AdminUPN,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw @"
Uma sessão administrativa pertence a outra conta.

Conta esperada:
$AdminUPN

Conta identificada:
$($Connection.UserPrincipalName)
"@
        }
    }

    # ================================================================
    # VALIDAR MÓDULOS E COMANDOS
    # ================================================================
    Write-Host '==> Validando módulos e comandos'

    $RequiredCommands = @(
        'Get-MgContext',
        'Get-MgUser',
        'Get-MgSubscribedSku',
        'Get-ConnectionInformation',
        'Get-AdminAuditLogConfig',
        'Set-AdminAuditLogConfig',
        'Search-UnifiedAuditLog',
        'Get-UnifiedAuditLogRetentionPolicy',
        'New-UnifiedAuditLogRetentionPolicy',
        'Set-UnifiedAuditLogRetentionPolicy'
    )

    $CommandEvidence = foreach (
        $CommandName in $RequiredCommands
    ) {
        $Command = Get-Command `
            -Name $CommandName `
            -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            Comando = $CommandName
            Disponivel = $null -ne $Command
            Tipo = if ($null -ne $Command) {
                [string]$Command.CommandType
            }
            else {
                ''
            }
            Modulo = if ($null -ne $Command) {
                [string]$Command.ModuleName
            }
            else {
                ''
            }
        }
    }

    $CommandEvidence |
        Export-Csv `
            -LiteralPath $CommandsPath `
            -NoTypeInformation `
            -Encoding utf8

    $MissingCommands = @(
        $CommandEvidence |
            Where-Object {
                $_.Disponivel -ne $true
            }
    )

    if ($MissingCommands.Count -gt 0) {
        throw @"
Os seguintes comandos não estão disponíveis:

$($MissingCommands.Comando -join ', ')
"@
    }

    # ================================================================
    # VALIDAR CONTA E LICENÇAS
    # ================================================================
    Write-Host '==> Validando conta e licenças atribuídas'

    $AdminUser = Get-MgUser `
        -UserId $AdminUPN `
        -Property Id,UserPrincipalName,AccountEnabled,AssignedLicenses

    if ($AdminUser.AccountEnabled -ne $true) {
        throw 'A conta administrativa está desabilitada.'
    }

    $SubscribedSkus = @(Get-MgSubscribedSku)

    $AssignedSkuIds = @(
        $AdminUser.AssignedLicenses |
            ForEach-Object {
                [string]$_.SkuId
            }
    )

    $AssignedSkuEvidence = @(
        foreach ($Sku in $SubscribedSkus) {
            if (
                $AssignedSkuIds -contains [string]$Sku.SkuId
            ) {
                $SkuName = [string]$Sku.SkuPartNumber

                $Candidate = $SkuName -match (
                    'E5|PURVIEW|COMPLIANCE|AUDIT|EDISCOVERY'
                )

                [PSCustomObject]@{
                    Conta = $AdminUPN
                    ContaHabilitada = $AdminUser.AccountEnabled
                    SkuPartNumber = $SkuName
                    SkuId = $Sku.SkuId
                    CandidataAuditPremium = $Candidate
                    Observacao = if ($Candidate) {
                        'SKU candidata; validar direitos do produto.'
                    }
                    else {
                        'Não classificada como candidata pelo nome.'
                    }
                }
            }
        }
    )

    Export-CsvEvidence `
        -InputObject $AssignedSkuEvidence `
        -Path $LicensesPath `
        -EmptyMessage 'Nenhuma licença atribuída foi retornada.'

    $HasCandidateAuditPremium = @(
        $AssignedSkuEvidence |
            Where-Object {
                $_.CandidataAuditPremium -eq $true
            }
    ).Count -gt 0

    # ================================================================
    # REGISTRAR CONTEXTO
    # ================================================================
    [PSCustomObject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime()
        Item = $ItemId
        Acao = $Acao
        TenantEsperado = $TenantId
        TenantGraph = $GraphContext.TenantId
        TenantExchange = $ExchangeConnection.TenantID
        TenantPurview = $PurviewConnection.TenantID
        ContaEsperada = $AdminUPN
        ContaGraph = $GraphContext.Account
        ContaExchange = $ExchangeConnection.UserPrincipalName
        ContaPurview = $PurviewConnection.UserPrincipalName
        PowerShellVersion = $PSVersionTable.PSVersion
        PowerShellEdition = $PSVersionTable.PSEdition
        DiasPesquisa = $DiasPesquisa
        NomePolitica = $NomePolitica
        DuracaoRetencao = $DuracaoRetencao
        Prioridade = $Prioridade
        Confirmacao = $ConfirmarAlteracao.IsPresent
        LicencaAuditPremiumCandidata = $HasCandidateAuditPremium
    } |
        Export-Csv `
            -LiteralPath $ContextPath `
            -NoTypeInformation `
            -Encoding utf8

    # ================================================================
    # CONFIGURAÇÃO ANTES
    # ================================================================
    Write-Host '==> Consultando configuração inicial da UAL'

    $BeforeConfig = Get-AdminAuditLogConfig

    [PSCustomObject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime()
        UnifiedAuditLogIngestionEnabled =
            $BeforeConfig.UnifiedAuditLogIngestionEnabled
        AdminAuditLogEnabled =
            $BeforeConfig.AdminAuditLogEnabled
        AdminAuditLogAgeLimit =
            $BeforeConfig.AdminAuditLogAgeLimit
    } |
        Export-Csv `
            -LiteralPath $ConfigBeforePath `
            -NoTypeInformation `
            -Encoding utf8

    # ================================================================
    # POLÍTICAS ANTES
    # ================================================================
    Write-Host '==> Inventariando políticas de retenção existentes'

    $PoliciesBefore = @(
        Get-UnifiedAuditLogRetentionPolicy `
            -ErrorAction Stop |
            Sort-Object Priority
    )

    $NormalizedPoliciesBefore = @(
        foreach ($Policy in $PoliciesBefore) {
            [PSCustomObject]@{
                Name = $Policy.Name
                Priority = $Policy.Priority
                RetentionDuration =
                    $Policy.RetentionDuration
                RecordTypes =
                    @($Policy.RecordTypes) -join ';'
                Operations =
                    @($Policy.Operations) -join ';'
                UserIds =
                    @($Policy.UserIds) -join ';'
                Identity =
                    $Policy.Identity
            }
        }
    )

    Export-CsvEvidence `
        -InputObject $NormalizedPoliciesBefore `
        -Path $PoliciesBeforePath `
        -EmptyMessage (
            'Nenhuma política personalizada de retenção foi encontrada.'
        )

    # ================================================================
    # PERMISSÕES FUNCIONAIS
    # ================================================================
    $PermissionEvidence = @(
        [PSCustomObject]@{
            Capacidade =
                'Consultar configuração da UAL'
            Validada =
                $null -ne $BeforeConfig
            Evidencia =
                'Get-AdminAuditLogConfig concluído'
        },
        [PSCustomObject]@{
            Capacidade =
                'Consultar políticas de retenção'
            Validada =
                $true
            Evidencia =
                'Get-UnifiedAuditLogRetentionPolicy concluído'
        },
        [PSCustomObject]@{
            Capacidade =
                'Comando para alterar UAL disponível'
            Validada =
                $null -ne (
                    Get-Command `
                        Set-AdminAuditLogConfig `
                        -ErrorAction SilentlyContinue
                )
            Evidencia =
                'Cmdlet exposto na sessão Exchange'
        },
        [PSCustomObject]@{
            Capacidade =
                'Comando para criar retenção disponível'
            Validada =
                $null -ne (
                    Get-Command `
                        New-UnifiedAuditLogRetentionPolicy `
                        -ErrorAction SilentlyContinue
                )
            Evidencia =
                'Cmdlet exposto na sessão Purview'
        },
        [PSCustomObject]@{
            Capacidade =
                'Licença candidata a Audit Premium'
            Validada =
                $HasCandidateAuditPremium
            Evidencia =
                'Validação das SKUs atribuídas à conta'
        }
    )

    $PermissionEvidence |
        Export-Csv `
            -LiteralPath $PermissionsPath `
            -NoTypeInformation `
            -Encoding utf8

    # ================================================================
    # EXECUTAR AÇÃO
    # ================================================================
    switch ($Acao) {
        'Consultar' {
            Write-Host ''
            Write-Host (
                'Modo consulta: nenhuma alteração será realizada.'
            )
        }

        'HabilitarUAL' {
            if (
                $BeforeConfig.
                    UnifiedAuditLogIngestionEnabled -ne $true
            ) {
                Write-Host '==> Habilitando a UAL'

                Set-AdminAuditLogConfig `
                    -UnifiedAuditLogIngestionEnabled $true `
                    -Confirm:$false

                $ChangeExecuted = $true
            }
            else {
                Write-Host 'A UAL já estava habilitada.'
            }
        }

        'DesabilitarUAL' {
            if (
                $BeforeConfig.
                    UnifiedAuditLogIngestionEnabled -eq $true
            ) {
                Write-Host '==> Desabilitando a UAL'

                Set-AdminAuditLogConfig `
                    -UnifiedAuditLogIngestionEnabled $false `
                    -Confirm:$false

                $ChangeExecuted = $true
            }
            else {
                Write-Host 'A UAL já estava desabilitada.'
            }
        }

        'AplicarRetencao' {
            if (-not $HasCandidateAuditPremium) {
                throw @'
Nenhuma licença candidata a Audit Premium foi encontrada
na conta administrativa.

A política de retenção não será aplicada.
'@
            }

            $ExistingPolicy = $PoliciesBefore |
                Where-Object {
                    [string]::Equals(
                        [string]$_.Name,
                        $NomePolitica,
                        [System.StringComparison]::
                            OrdinalIgnoreCase
                    )
                } |
                Select-Object -First 1

            if ($null -eq $ExistingPolicy) {
                Write-Host '==> Criando política de retenção'

                New-UnifiedAuditLogRetentionPolicy `
                    -Name $NomePolitica `
                    -Description (
                        'Retenção controlada para eventos ' +
                        'CopilotInteraction - AUTO-31'
                    ) `
                    -RecordTypes CopilotInteraction `
                    -RetentionDuration $DuracaoRetencao `
                    -Priority $Prioridade `
                    -Confirm:$false

                $ChangeExecuted = $true
            }
            else {
                Write-Host '==> Atualizando política de retenção'

                Set-UnifiedAuditLogRetentionPolicy `
                    -Identity $ExistingPolicy.Identity `
                    -Description (
                        'Retenção controlada para eventos ' +
                        'CopilotInteraction - AUTO-31'
                    ) `
                    -RecordTypes CopilotInteraction `
                    -RetentionDuration $DuracaoRetencao `
                    -Priority $Prioridade `
                    -Confirm:$false

                $ChangeExecuted = $true
            }
        }
    }

    # ================================================================
    # CONFIGURAÇÃO DEPOIS
    # ================================================================
    Write-Host '==> Reconsultando configuração da UAL'

    $AfterConfig = Get-AdminAuditLogConfig

    [PSCustomObject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime()
        UnifiedAuditLogIngestionEnabled =
            $AfterConfig.UnifiedAuditLogIngestionEnabled
        AdminAuditLogEnabled =
            $AfterConfig.AdminAuditLogEnabled
        AdminAuditLogAgeLimit =
            $AfterConfig.AdminAuditLogAgeLimit
    } |
        Export-Csv `
            -LiteralPath $ConfigAfterPath `
            -NoTypeInformation `
            -Encoding utf8

    # ================================================================
    # POLÍTICAS DEPOIS
    # ================================================================
    Write-Host '==> Reconsultando políticas de retenção'

    $PoliciesAfter = @(
        Get-UnifiedAuditLogRetentionPolicy `
            -ErrorAction Stop |
            Sort-Object Priority
    )

    $NormalizedPoliciesAfter = @(
        foreach ($Policy in $PoliciesAfter) {
            [PSCustomObject]@{
                Name = $Policy.Name
                Priority = $Policy.Priority
                RetentionDuration =
                    $Policy.RetentionDuration
                RecordTypes =
                    @($Policy.RecordTypes) -join ';'
                Operations =
                    @($Policy.Operations) -join ';'
                UserIds =
                    @($Policy.UserIds) -join ';'
                Identity =
                    $Policy.Identity
            }
        }
    )

    Export-CsvEvidence `
        -InputObject $NormalizedPoliciesAfter `
        -Path $PoliciesAfterPath `
        -EmptyMessage (
            'Nenhuma política personalizada de retenção foi encontrada.'
        )

    # ================================================================
    # PESQUISAR EVENTOS COPILOT
    # ================================================================
    if (
        $AfterConfig.
            UnifiedAuditLogIngestionEnabled -eq $true
    ) {
        Write-Host '==> Pesquisando eventos CopilotInteraction'

        $StartDate = (Get-Date).AddDays(-$DiasPesquisa)
        $EndDate = Get-Date
        $SessionId = "AUTO31-$Timestamp"
        $RawEvents = @()
        $MaximumRecords = 50000

        do {
            $Page = @(
                Search-UnifiedAuditLog `
                    -StartDate $StartDate `
                    -EndDate $EndDate `
                    -RecordType CopilotInteraction `
                    -SessionId $SessionId `
                    -SessionCommand ReturnLargeSet `
                    -ResultSize 5000 `
                    -ErrorAction Stop
            )

            if ($Page.Count -gt 0) {
                $RawEvents += $Page
            }
        }
        while (
            $Page.Count -gt 0 -and
            $RawEvents.Count -lt $MaximumRecords
        )

        $RawEvents = @(
            $RawEvents |
                Sort-Object Identity -Unique
        )

        foreach ($AuditRecord in $RawEvents) {
            $AuditJson = $null
            $ParseStatus = 'Não processado'

            try {
                $AuditJson = $AuditRecord.AuditData |
                    ConvertFrom-Json `
                        -ErrorAction Stop

                $ParseStatus = 'Concluído'
            }
            catch {
                $ParseStatus = 'Falha no parsing'
            }

            $ResourceCount = 0
            $AppHost = ''
            $Workload = ''
            $ResultStatus = ''

            if ($null -ne $AuditJson) {
                $Workload =
                    [string]$AuditJson.Workload

                $ResultStatus =
                    [string]$AuditJson.ResultStatus

                if (
                    $null -ne
                    $AuditJson.CopilotEventData
                ) {
                    $AppHost = [string](
                        $AuditJson.
                            CopilotEventData.
                            AppHost
                    )

                    $ResourceCount = @(
                        $AuditJson.
                            CopilotEventData.
                            AccessedResources
                    ).Count
                }
            }

            $NormalizedEvents += [PSCustomObject]@{
                CreationDate =
                    $AuditRecord.CreationDate
                UserId =
                    $AuditRecord.UserIds
                Operation =
                    $AuditRecord.Operations
                RecordType =
                    $AuditRecord.RecordType
                Workload =
                    $Workload
                ApplicationHost =
                    $AppHost
                ResultStatus =
                    $ResultStatus
                AccessedResourceCount =
                    $ResourceCount
                EventId =
                    $AuditRecord.Identity
                JsonParseStatus =
                    $ParseStatus
            }
        }

        $SearchStatus = 'Concluída'

        $SearchMessage = if (
            $NormalizedEvents.Count -gt 0
        ) {
            'Consulta concluída com eventos encontrados.'
        }
        else {
            (
                'Consulta concluída sem eventos. ' +
                'Resultado zero não representa falha.'
            )
        }
    }
    else {
        $SearchStatus = 'Ignorada'
        $SearchMessage = (
            'UAL desabilitada após a ação; ' +
            'pesquisa não executada.'
        )
    }

    Export-CsvEvidence `
        -InputObject $NormalizedEvents `
        -Path $EventsPath `
        -EmptyMessage $SearchMessage

    # ================================================================
    # QUALITY GATE
    # ================================================================
    switch ($Acao) {
        'Consultar' {
            $ValidationApproved =
                $null -ne $AfterConfig -and
                $SearchStatus -in @(
                    'Concluída',
                    'Ignorada'
                )
        }

        'HabilitarUAL' {
            $ValidationApproved =
                $AfterConfig.
                    UnifiedAuditLogIngestionEnabled -eq $true
        }

        'DesabilitarUAL' {
            $ValidationApproved =
                $AfterConfig.
                    UnifiedAuditLogIngestionEnabled -eq $false
        }

        'AplicarRetencao' {
            $AppliedPolicy = $PoliciesAfter |
                Where-Object {
                    [string]::Equals(
                        [string]$_.Name,
                        $NomePolitica,
                        [System.StringComparison]::
                            OrdinalIgnoreCase
                    )
                } |
                Select-Object -First 1

            $ValidationApproved =
                $null -ne $AppliedPolicy -and
                [string]$AppliedPolicy.
                    RetentionDuration -eq
                    $DuracaoRetencao -and
                [int]$AppliedPolicy.Priority -eq
                    $Prioridade -and
                @(
                    $AppliedPolicy.RecordTypes
                ) -contains 'CopilotInteraction'
        }
    }
}
catch {
    $ErrorMessage = $_.Exception.Message

    Write-Host ''
    Write-Host 'A execução encontrou uma falha:' `
        -ForegroundColor Red

    Write-Host $ErrorMessage `
        -ForegroundColor Red
}
finally {
    [PSCustomObject]@{
        DataHoraUtc =
            (Get-Date).ToUniversalTime()
        Item =
            $ItemId
        AcaoSolicitada =
            $Acao
        AlteracaoExecutada =
            $ChangeExecuted
        ValidacaoAprovada =
            $ValidationApproved
        UalAntes = if ($null -ne $BeforeConfig) {
            $BeforeConfig.
                UnifiedAuditLogIngestionEnabled
        }
        else {
            $null
        }
        UalDepois = if ($null -ne $AfterConfig) {
            $AfterConfig.
                UnifiedAuditLogIngestionEnabled
        }
        else {
            $null
        }
        StatusPesquisa =
            $SearchStatus
        MensagemPesquisa =
            $SearchMessage
        EventosEncontrados =
            @($NormalizedEvents).Count
        PoliticasAntes =
            @($PoliciesBefore).Count
        PoliticasDepois =
            @($PoliciesAfter).Count
        NomePolitica =
            $NomePolitica
        DuracaoRetencao =
            $DuracaoRetencao
        Prioridade =
            $Prioridade
        LicencaAuditPremiumCandidata =
            $HasCandidateAuditPremium
        Erro =
            $ErrorMessage
        PastaEvidencias =
            $EvidenceFolder
    } |
        Export-Csv `
            -LiteralPath $SummaryPath `
            -NoTypeInformation `
            -Encoding utf8

    if ($TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Warning (
                'Não foi possível encerrar formalmente o transcript.'
            )
        }
    }
}

Write-Host ''
Write-Host '====================================================='
Write-Host ' RESULTADO DO AUTO-31'
Write-Host '====================================================='
Write-Host "Ação: $Acao"
Write-Host "Alteração executada: $ChangeExecuted"
Write-Host "Validação aprovada: $ValidationApproved"
Write-Host "Status da pesquisa: $SearchStatus"
Write-Host "Eventos Copilot: $(@($NormalizedEvents).Count)"
Write-Host "Políticas antes: $(@($PoliciesBefore).Count)"
Write-Host "Políticas depois: $(@($PoliciesAfter).Count)"
Write-Host "Evidências: $EvidenceFolder"

if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
    Write-Host "Erro: $ErrorMessage" `
        -ForegroundColor Red
}

Write-Host '====================================================='

if (-not $ValidationApproved) {
    throw @"
O AUTO-31 não atingiu o critério de aceite.

Consulte:
$SummaryPath
$TranscriptPath
"@
}