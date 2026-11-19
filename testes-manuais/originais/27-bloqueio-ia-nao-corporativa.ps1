#requires -Version 7.0
<#
.SYNOPSIS
    Validação controlada e exclusivamente de leitura dos indicadores do
    Microsoft Defender for Endpoint relacionados ao AUTO-27.

.DESCRIPTION
    Versão corrigida 1.2.
    Esta versão usa autenticação delegada por Device Code e aceita somente
    consultas GET. Não cria segredo, não usa client credentials, não cria,
    atualiza ou exclui indicadores e não executa bloqueios.

    FERRAMENTA:
    Microsoft Defender for Endpoint API.

    PERMISSÃO:
    WindowsDefenderATP / Ti.ReadWrite (delegada).
    Observação: a API de indicadores não oferece um escopo delegado separado
    somente para leitura. A segurança desta versão é imposta pelo código, que
    rejeita qualquer método diferente de GET.

    EFEITO:
    Somente leitura. Consulta indicadores associados aos domínios/URLs
    informados e gera evidências locais.

    ATENÇÃO:
    - Não concede consentimento administrativo.
    - Não cria certificado ou segredo.
    - Não habilita ou desabilita bloqueios.
    - Não use a versão original com Habilitar/Desabilitar no tenant Bizapp.
#>

[CmdletBinding()]
param(
    [guid]$ExpectedTenantId = '9471ca37-67dc-4649-96e8-3d5f46209045',

    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$ExpectedAdminUpn = 'pedro.frei@bizapp.com.br',

    [guid]$DefenderAppId = '0c74a387-56c9-495a-aa65-a5fa7b40e240',

    [ValidateNotNullOrEmpty()]
    [string[]]$IndicatorValues = @('chatgpt.com'),

    [string]$EvidenceRoot = (Join-Path $PSScriptRoot 'evidencias'),

    [ValidateRange(1, 10000)]
    [int]$Top = 100,

    [switch]$SkipUserConfirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:TranscriptStarted = $false
$script:EvidenceFolder = $null
$script:Errors = [System.Collections.Generic.List[object]]::new()
$script:Actions = [System.Collections.Generic.List[object]]::new()

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Add-ErrorEvidence {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $script:Errors.Add([pscustomobject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime().ToString('o')
        Etapa       = $Stage
        Tipo        = $ErrorRecord.Exception.GetType().FullName
        Mensagem    = $ErrorRecord.Exception.Message
        ScriptLine  = $ErrorRecord.InvocationInfo.ScriptLineNumber
    })
}

function Add-ActionEvidence {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Result,
        [Parameter(Mandatory)][string]$Details
    )

    $script:Actions.Add([pscustomobject]@{
        DataHoraUtc = (Get-Date).ToUniversalTime().ToString('o')
        Alvo        = $Target
        Operacao    = 'Consultar'
        MetodoHttp  = 'GET'
        Resultado   = $Result
        Detalhes    = $Details
        Alteracao   = $false
    })
}

function Normalize-IndicatorValue {
    param([Parameter(Mandatory)][string]$Value)

    $Normalized = $Value.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($Normalized)) {
        throw 'Foi informado um domínio ou URL vazio.'
    }

    if ($Normalized -match '^https?://') {
        try {
            $Uri = [uri]$Normalized
            $HostValue = $Uri.Host.TrimEnd('.').ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($HostValue)) {
                throw 'URL sem host válido.'
            }
            return $HostValue
        }
        catch {
            throw "URL inválida: $Value"
        }
    }

    $Normalized = $Normalized.TrimEnd('/')
    if ($Normalized -notmatch '^[a-z0-9.-]+$' -or $Normalized -notmatch '\.') {
        throw "Domínio inválido: $Value"
    }

    return $Normalized.TrimEnd('.')
}

function ConvertFrom-Base64Url {
    param([Parameter(Mandatory)][string]$Value)

    $Text = $Value.Replace('-', '+').Replace('_', '/')
    switch ($Text.Length % 4) {
        2 { $Text += '==' }
        3 { $Text += '=' }
    }

    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

function Get-JwtPayload {
    param([Parameter(Mandatory)][string]$Token)

    $Parts = $Token.Split('.')
    if (@($Parts).Count -lt 2) {
        throw 'O token retornado não possui formato JWT válido.'
    }

    $Json = ConvertFrom-Base64Url -Value $Parts[1]
    $Json | ConvertFrom-Json -Depth 20
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $Property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $Property) {
        return $null
    }
    return $Property.Value
}

function Test-ExpectedUser {
    param(
        [Parameter(Mandatory)][object]$Payload,
        [Parameter(Mandatory)][string]$ExpectedUpn
    )

    $Candidates = @(
        [string](Get-ObjectPropertyValue -InputObject $Payload -Name 'preferred_username'),
        [string](Get-ObjectPropertyValue -InputObject $Payload -Name 'upn'),
        [string](Get-ObjectPropertyValue -InputObject $Payload -Name 'unique_name'),
        [string](Get-ObjectPropertyValue -InputObject $Payload -Name 'email')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($Candidate in $Candidates) {
        if ($Candidate.Equals(
            $ExpectedUpn,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            return $true
        }
    }

    return $false
}

function Get-DelegatedDefenderToken {
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$ClientId
    )

    $Resource = 'https://api.securitycenter.microsoft.com'
    $BaseUri = "https://login.microsoftonline.com/$TenantId/oauth2"

    $DeviceResponse = Invoke-RestMethod `
        -Method POST `
        -Uri "$BaseUri/devicecode" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            client_id = $ClientId.ToString()
            resource  = $Resource
        }

    if ([string]::IsNullOrWhiteSpace([string]$DeviceResponse.device_code)) {
        throw 'O Entra ID não retornou um código de dispositivo.'
    }

    Write-Host ''
    Write-Host $DeviceResponse.message -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Use exclusivamente a conta esperada informada no script.' `
        -ForegroundColor Yellow

    $Interval = [Math]::Max([int]$DeviceResponse.interval, 5)
    $ExpiresAt = (Get-Date).ToUniversalTime().AddSeconds(
        [int]$DeviceResponse.expires_in
    )

    do {
        Start-Sleep -Seconds $Interval
        try {
            $TokenResponse = Invoke-RestMethod `
                -Method POST `
                -Uri "$BaseUri/token" `
                -ContentType 'application/x-www-form-urlencoded' `
                -Body @{
                    grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id  = $ClientId.ToString()
                    code       = [string]$DeviceResponse.device_code
                    resource   = $Resource
                }

            if (-not [string]::IsNullOrWhiteSpace(
                [string]$TokenResponse.access_token
            )) {
                return $TokenResponse
            }
        }
        catch {
            $ResponseText = $_.ErrorDetails.Message
            if ($ResponseText -match 'authorization_pending') {
                continue
            }
            if ($ResponseText -match 'slow_down') {
                $Interval += 5
                continue
            }
            if ($ResponseText -match 'authorization_declined') {
                throw 'A autenticação foi recusada pelo usuário.'
            }
            if ($ResponseText -match 'expired_token') {
                throw 'O código de dispositivo expirou antes da autenticação.'
            }
            throw
        }
    } while ((Get-Date).ToUniversalTime() -lt $ExpiresAt)

    throw 'O tempo disponível para autenticação por dispositivo expirou.'
}

function Invoke-DefenderReadOnlyApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET')][string]$Method,
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    if ($Method -ne 'GET') {
        throw "Método HTTP bloqueado nesta versão: $Method"
    }

    Invoke-RestMethod `
        -Method GET `
        -Uri $Uri `
        -Headers $Headers `
        -ContentType 'application/json'
}

function Get-IndicatorsForTarget {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][int]$PageSize
    )

    $EscapedValue = $Value.Replace("'", "''")
    $Filter = [uri]::EscapeDataString("indicatorValue eq '$EscapedValue'")
    $Uri = [uri](
        'https://api.security.microsoft.com/api/indicators' +
        "?`$filter=$Filter&`$top=$PageSize"
    )

    $Rows = [System.Collections.Generic.List[object]]::new()
    $PageCount = 0

    while ($null -ne $Uri) {
        $PageCount++
        if ($PageCount -gt 100) {
            throw 'Paginação interrompida após 100 páginas por segurança.'
        }

        $Response = Invoke-DefenderReadOnlyApi `
            -Method GET `
            -Uri $Uri `
            -Headers $Headers

        foreach ($Item in @($Response.value)) {
            $Rows.Add($Item)
        }

        $NextLink = [string](
            Get-ObjectPropertyValue `
                -InputObject $Response `
                -Name '@odata.nextLink'
        )
        if ([string]::IsNullOrWhiteSpace($NextLink)) {
            $Uri = $null
        }
        else {
            $NextUri = [uri]$NextLink
            if ($NextUri.Scheme -ne 'https' -or
                $NextUri.Host -notin @(
                    'api.security.microsoft.com',
                    'api.securitycenter.microsoft.com'
                )) {
                throw 'A API retornou uma URL de paginação fora dos hosts permitidos.'
            }
            $Uri = $NextUri
        }
    }

    return @($Rows)
}

function Convert-IndicatorToEvidence {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][object[]]$Indicators
    )

    if (@($Indicators).Count -eq 0) {
        return [pscustomobject]@{
            Alvo               = $Target
            Encontrado         = $false
            Id                 = $null
            Tipo               = $null
            Acao               = $null
            Titulo             = $null
            Aplicacao          = $null
            CriadoPor          = $null
            CriadoEmUtc        = $null
            ExpiraEmUtc        = $null
            GruposRbac         = $null
            GeraAlerta         = $null
            Observacao         = 'Nenhum indicador encontrado.'
        }
    }

    foreach ($Indicator in $Indicators) {
        [pscustomobject]@{
            Alvo               = $Target
            Encontrado         = $true
            Id                 = $Indicator.id
            Tipo               = $Indicator.indicatorType
            Acao               = $Indicator.action
            Titulo             = $Indicator.title
            Aplicacao          = $Indicator.application
            CriadoPor          = $Indicator.createdBy
            CriadoEmUtc        = $Indicator.creationTimeDateTimeUtc
            ExpiraEmUtc        = $Indicator.expirationTime
            GruposRbac         = @($Indicator.rbacGroupNames) -join '; '
            GeraAlerta         = $Indicator.generateAlert
            Observacao         = 'Consulta somente leitura.'
        }
    }
}

$Stage = 'Inicialização'
$ExitCode = 1
$TokenResponse = $null
$TokenPayload = $null

try {
    $Stage = 'Preparação das evidências'
    Write-Step '1. Preparando evidências locais'

    $Timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $script:EvidenceFolder = Join-Path `
        $EvidenceRoot `
        "AUTO-27-CONSULTA-$Timestamp"
    New-Item -ItemType Directory -Path $script:EvidenceFolder -Force |
        Out-Null

    $TranscriptPath = Join-Path $script:EvidenceFolder 'execucao.log'
    Start-Transcript -Path $TranscriptPath -Force | Out-Null
    $script:TranscriptStarted = $true

    $Stage = 'Validação de parâmetros'
    Write-Step '2. Validando parâmetros e trava de somente leitura'

    $Targets = @(
        $IndicatorValues |
            ForEach-Object { Normalize-IndicatorValue -Value $_ } |
            Sort-Object -Unique
    )

    if (@($Targets).Count -eq 0) {
        throw 'Informe pelo menos um domínio ou URL para consultar.'
    }

    Write-Host "Tenant esperado: $ExpectedTenantId"
    Write-Host "Conta esperada: $ExpectedAdminUpn"
    Write-Host "Aplicativo cliente: $DefenderAppId"
    Write-Host "Alvos: $($Targets -join ', ')"
    Write-Host 'Modo: SOMENTE LEITURA — GET /api/indicators' `
        -ForegroundColor Green

    if (-not $SkipUserConfirmation) {
        $Confirmation = Read-Host (
            'Digite CONSULTAR para iniciar autenticação e consulta somente leitura'
        )
        if ($Confirmation -cne 'CONSULTAR') {
            throw 'Execução cancelada: confirmação CONSULTAR não recebida.'
        }
    }

    $Stage = 'Autenticação delegada'
    Write-Step '3. Autenticando no Defender por Device Code'

    $TokenResponse = Get-DelegatedDefenderToken `
        -TenantId $ExpectedTenantId `
        -ClientId $DefenderAppId

    $TokenPayload = Get-JwtPayload -Token $TokenResponse.access_token

    $TokenTenantId = [string](
        Get-ObjectPropertyValue -InputObject $TokenPayload -Name 'tid'
    )
    if ($TokenTenantId -ne $ExpectedTenantId.ToString()) {
        throw (
            "Token emitido para tenant incorreto. Esperado: " +
            "$ExpectedTenantId; recebido: $TokenTenantId."
        )
    }

    $Azp = [string](
        Get-ObjectPropertyValue -InputObject $TokenPayload -Name 'azp'
    )
    $AppIdClaim = [string](
        Get-ObjectPropertyValue -InputObject $TokenPayload -Name 'appid'
    )
    $TokenClientId = if (-not [string]::IsNullOrWhiteSpace($Azp)) {
        $Azp
    }
    else {
        $AppIdClaim
    }

    if ($TokenClientId -ne $DefenderAppId.ToString()) {
        throw (
            "Token emitido para outro aplicativo. Esperado: " +
            "$DefenderAppId; recebido: $TokenClientId."
        )
    }

    if (-not (Test-ExpectedUser `
        -Payload $TokenPayload `
        -ExpectedUpn $ExpectedAdminUpn
    )) {
        throw (
            'A conta autenticada não corresponde ao ExpectedAdminUpn. ' +
            'A execução foi interrompida antes da consulta.'
        )
    }

    $Audience = ([string](
        Get-ObjectPropertyValue -InputObject $TokenPayload -Name 'aud'
    )).TrimEnd('/')
    if ($Audience -ne 'https://api.securitycenter.microsoft.com') {
        throw "Audiência de token inesperada: $Audience"
    }

    $ScopeClaim = [string](
        Get-ObjectPropertyValue -InputObject $TokenPayload -Name 'scp'
    )
    $DelegatedScopes = $ScopeClaim.Split(
        ' ',
        [System.StringSplitOptions]::RemoveEmptyEntries
    )
    if ($DelegatedScopes -notcontains 'Ti.ReadWrite') {
        throw (
            'O token delegado não contém Ti.ReadWrite. ' +
            'Revise a permissão WindowsDefenderATP do aplicativo.'
        )
    }

    $ApplicationRoles = @(
        @(
            Get-ObjectPropertyValue -InputObject $TokenPayload -Name 'roles'
        ) | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        }
    )
    if (@($ApplicationRoles).Count -gt 0) {
        throw (
            'Foi recebido um token com roles de aplicação. ' +
            'Esta versão exige token delegado e foi interrompida.'
        )
    }

    $Stage = 'Consulta dos indicadores'
    Write-Step '4. Consultando indicadores sem executar alterações'

    $Headers = @{
        Authorization = 'Bearer ' + [string]$TokenResponse.access_token
        Accept        = 'application/json'
    }

    $EvidenceRows = [System.Collections.Generic.List[object]]::new()

    foreach ($Target in $Targets) {
        $Indicators = @(
            Get-IndicatorsForTarget `
                -Value $Target `
                -Headers $Headers `
                -PageSize $Top
        )

        foreach ($Row in @(
            Convert-IndicatorToEvidence `
                -Target $Target `
                -Indicators $Indicators
        )) {
            $EvidenceRows.Add($Row)
        }

        Add-ActionEvidence `
            -Target $Target `
            -Result 'Sucesso' `
            -Details "$(@($Indicators).Count) indicador(es) encontrado(s)."

        Write-Host (
            "${Target}: $(@($Indicators).Count) indicador(es) encontrado(s)."
        )
    }

    $EvidenceRows |
        Export-Csv `
            -Path (Join-Path $script:EvidenceFolder 'indicadores.csv') `
            -Encoding UTF8

    $script:Actions |
        Export-Csv `
            -Path (Join-Path $script:EvidenceFolder 'acoes.csv') `
            -Encoding UTF8

    $TokenAccount = @(
        [string](Get-ObjectPropertyValue -InputObject $TokenPayload -Name 'preferred_username'),
        [string](Get-ObjectPropertyValue -InputObject $TokenPayload -Name 'upn'),
        [string](Get-ObjectPropertyValue -InputObject $TokenPayload -Name 'unique_name')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1

    $ContextEvidence = [pscustomobject]@{
        DataHoraUtc            = (Get-Date).ToUniversalTime().ToString('o')
        TenantEsperado         = $ExpectedTenantId
        TenantToken            = $TokenTenantId
        ContaEsperada          = $ExpectedAdminUpn
        ContaToken             = $TokenAccount
        DefenderAppIdEsperado  = $DefenderAppId
        DefenderAppIdToken     = $TokenClientId
        Audiencia              = $Audience
        EscoposDelegados       = $DelegatedScopes -join '; '
        MetodoPermitido        = 'GET'
        EndpointConsultado     = '/api/indicators'
        AlteracoesExecutadas   = $false
        SegredoUtilizado       = $false
        TokenPersistido        = $false
    }

    $ContextEvidence |
        Export-Csv `
            -Path (Join-Path $script:EvidenceFolder 'contexto.csv') `
            -Encoding UTF8

    $Summary = [pscustomobject]@{
        DataHoraUtc          = (Get-Date).ToUniversalTime().ToString('o')
        Item                 = 'AUTO-27'
        Acao                 = 'Consultar'
        Status               = 'APROVADO - consulta somente leitura'
        QuantidadeAlvos      = @($Targets).Count
        QuantidadeRegistros  = @($EvidenceRows | Where-Object Encontrado).Count
        AlteracoesExecutadas = $false
        PermissaoToken       = 'Delegada / Ti.ReadWrite'
        Aplicacao            = $DefenderAppId
        Tenant               = $ExpectedTenantId
        Conta                = $ExpectedAdminUpn
        PastaEvidencias      = $script:EvidenceFolder
    }

    $Summary |
        Export-Csv `
            -Path (Join-Path $script:EvidenceFolder 'resumo.csv') `
            -Encoding UTF8

    Write-Step '5. Consulta concluída'
    Write-Host 'Status: APROVADO - consulta somente leitura' `
        -ForegroundColor Green
    Write-Host 'Alterações executadas: False' -ForegroundColor Green
    Write-Host "Evidências: $script:EvidenceFolder"

    $ExitCode = 0
}
catch {
    Add-ErrorEvidence -Stage $Stage -ErrorRecord $_

    Write-Host ''
    Write-Host "FALHA em '$Stage': $($_.Exception.Message)" `
        -ForegroundColor Red

    if ($null -ne $script:EvidenceFolder) {
        $script:Errors |
            Export-Csv `
                -Path (Join-Path $script:EvidenceFolder 'erros.csv') `
                -Encoding UTF8

        [pscustomobject]@{
            DataHoraUtc          = (Get-Date).ToUniversalTime().ToString('o')
            Item                 = 'AUTO-27'
            Acao                 = 'Consultar'
            Status               = 'REPROVADO'
            EtapaFalha           = $Stage
            Mensagem             = $_.Exception.Message
            AlteracoesExecutadas = $false
        } |
            Export-Csv `
                -Path (Join-Path $script:EvidenceFolder 'resumo.csv') `
                -Encoding UTF8
    }

    $ExitCode = 1
}
finally {
    $TokenResponse = $null
    $TokenPayload = $null

    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Warning 'Não foi possível encerrar o transcript normalmente.'
        }
    }
}

exit $ExitCode