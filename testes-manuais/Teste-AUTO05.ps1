#Requires -Version 5.1
<#
.SYNOPSIS
    Teste manual do AUTO-05 (alocacao de Copilot Credits por ambiente) no tenant de demo, rodando
    o script ORIGINAL sem alteracoes (originais/05-copilot-credits.ps1, cabecalho COE-IA-009).

.DESCRIPTION
    O script original faz tudo sozinho: login (Az.Accounts), token da Power Platform API, lista de
    ambientes (Microsoft.PowerApps.Administration.PowerShell), consulta de MCSMessages em
    licensing/allocationsV2/availability e, se voce quiser, a alocacao (PUT allocationsV2) com a
    confirmacao ALOCAR. E a mesma API do tutorial da Microsoft "Manage Copilot Credits allocations
    programmatically" (api-version 2024-10-01).

    Este teste so envolve o original:
      - grava o log completo (transcript) e um resumo em CSV;
      - roda o original "dot-sourced", para ler depois o ambiente e as quantidades escolhidas;
      - [+] no fim, opcional: devolve a alocacao do ambiente de TESTE para 0 com TenantPool ligado
        (o padrao de um ambiente sem alocacao), digitando DESFAZER. O roteiro nao tem esse passo;
        e so limpeza do laboratorio, e o servico pode recusar a quantidade 0 (o roteiro registra
        que 20 foi recusado com InvalidAllocationRequest). Se recusar, ajuste no admin center.

    Atencao: o original instala Az.Accounts e Microsoft.PowerApps.Administration.PowerShell
    sozinho (Install-Module -Scope CurrentUser) se faltarem, sem perguntar.

    Sugestao: primeiro rode so a leitura (responda NAO para a alocacao). Se houver creditos
    disponiveis, rode de novo e aloque num ambiente de TESTE (o roteiro validou 5000).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Teste-AUTO05.ps1
#>
param(
    [string]$PastaTrabalho = (Join-Path $env:USERPROFILE 'Downloads\AUTO05-Teste'),
    [string]$Original = (Join-Path $PSScriptRoot 'originais\05-copilot-credits.ps1')
)

if ($PSVersionTable.PSEdition -ne 'Desktop') { Write-Host 'Rode no Windows PowerShell 5.1 (powershell.exe), como pede o roteiro.' -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $Original)) { Write-Host "Original nao encontrado: $Original" -ForegroundColor Red; exit 1 }

New-Item -ItemType Directory -Force -Path $PastaTrabalho | Out-Null
$carimbo = Get-Date -Format 'yyyyMMdd-HHmmss'
$Evid = Join-Path $PastaTrabalho "evidencias\$carimbo"
New-Item -ItemType Directory -Force -Path $Evid | Out-Null
$LOG_TESTE = Join-Path $PastaTrabalho "teste-$carimbo.log"
Start-Transcript -LiteralPath $LOG_TESTE -Force | Out-Null

$resultados = New-Object System.Collections.Generic.List[object]
function Registrar([string]$Parte, [string]$Acao, [bool]$Ok, [string]$Detalhe = '') {
    $script:resultados.Add([pscustomobject]@{ Parte = $Parte; Acao = $Acao; Sucesso = $Ok; Detalhe = $Detalhe })
    $cor = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host "  $(if ($Ok) { 'OK' } else { 'FALHOU' }) - $Parte / $Acao$(if ($Detalhe) { ": $Detalhe" })" -ForegroundColor $cor
}

try {
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host ' SCRIPT ORIGINAL (sem alteracoes)' -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host "Arquivo: $Original" -ForegroundColor DarkGray
    Write-Host "SHA-256: $((Get-FileHash -Algorithm SHA256 -LiteralPath $Original).Hash)" -ForegroundColor DarkGray

    # Dot-source: as variaveis do original ($EnvironmentId, $AvailableQuantity...) ficam visiveis aqui
    . $Original

    # O original trata os proprios erros (catch) e zera $Token e $Headers no finally
    $ambienteEscolhido = if ($EnvironmentId) { "$EnvironmentName ($EnvironmentId)" } else { '' }
    Registrar 'Original' 'Login e tenant' ([bool]$TenantId) "$Account / $TenantId"
    Registrar 'Original' 'Ambiente escolhido' ([bool]$EnvironmentId) $ambienteEscolhido
    Registrar 'Original' 'Consulta MCSMessages' ($null -ne $AvailableQuantity) "Disponivel antes: $AvailableQuantity"
    if ($AllocationResult -or $After) {
        Registrar 'Original' 'Alocacao (PUT allocationsV2)' $true "Quantidade $CreditQuantity, TenantPool $TenantPool"
        $depois = @($After.entitlementAllocationsAvailable) | Where-Object { $_.entitlementId -eq 'MCSMessages' } | Select-Object -First 1
        if ($depois) { Registrar 'Original' 'Reconsulta' $true "Disponivel depois: $($depois.availableQuantity)" }
    } elseif ($Allocate -eq 'SIM') {
        Registrar 'Original' 'Alocacao (PUT allocationsV2)' $false 'Nao concluida (veja o log)'
    } else {
        Write-Host 'Alocacao nao pedida: so leitura.' -ForegroundColor DarkGray
    }
    [pscustomobject]@{ TenantId = $TenantId; Conta = $Account; Ambiente = $EnvironmentName; EnvironmentId = $EnvironmentId; Tipo = $EnvironmentType
        DisponivelAntes = $AvailableQuantity; Alocou = [bool]($AllocationResult -or $After); Quantidade = $CreditQuantity; TenantPool = $TenantPool
    } | Export-Csv -Path (Join-Path $Evid 'resultado-original.csv') -NoTypeInformation -Encoding UTF8

    # ------------------------------------------------------------------
    if ($AllocationResult -or $After) {
        Write-Host ''
        Write-Host ('=' * 70) -ForegroundColor DarkMagenta
        Write-Host ' [+] LIMPEZA DO LABORATORIO (opcional)' -ForegroundColor Magenta
        Write-Host ('=' * 70) -ForegroundColor DarkMagenta
        Write-Host "Devolve a alocacao de $EnvironmentName para 0 com TenantPool ligado (padrao de ambiente sem alocacao)." -ForegroundColor DarkGray
        if ((Read-Host 'Digite DESFAZER para devolver (Enter = manter a alocacao)') -ceq 'DESFAZER') {
            try {
                $at = Get-AzAccessToken -ResourceUrl 'https://api.powerplatform.com/' -TenantId $TenantId
                $tk = if ($at.Token -is [System.Security.SecureString]) { [System.Net.NetworkCredential]::new('', $at.Token).Password } else { [string]$at.Token }
                $cab = @{ Authorization = "Bearer $tk"; Accept = 'application/json' }
                $corpo = @{ scope = @{ environmentId = $EnvironmentId }
                    allocatedEntitlements = @(@{ entitlementId = 'MCSMessages'; allocation = @{ quantity = 0 }; enforcementRules = @(@{ ruleType = 'TenantPool'; enabled = $true }) }) } | ConvertTo-Json -Depth 10
                Invoke-RestMethod -Method PUT -Uri "https://api.powerplatform.com/licensing/allocationsV2?api-version=2024-10-01" -Headers $cab -ContentType 'application/json' -Body $corpo | Out-Null
                $volta = Invoke-RestMethod -Method GET -Uri $AvailabilityUri -Headers $cab
                $mcs = @($volta.entitlementAllocationsAvailable) | Where-Object { $_.entitlementId -eq 'MCSMessages' } | Select-Object -First 1
                Registrar 'Limpeza' 'Devolver para 0' $true "Disponivel agora: $($mcs.availableQuantity)"
            } catch {
                $det = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
                Registrar 'Limpeza' 'Devolver para 0' $false $det
                Write-Host 'Ajuste no admin center: Licenciamento > Copilot Studio > Gerenciar Copilot Credits.' -ForegroundColor Yellow
            } finally { $tk = $null; $cab = $null }
        } else { Write-Host 'Alocacao mantida.' }
    }
} catch {
    Write-Host ''
    Write-Host "PAROU: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    Write-Host ' RESUMO DO TESTE' -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor DarkMagenta
    if ($resultados.Count) {
        $resultados | Format-Table -AutoSize -Wrap | Out-Host
        $resultados | Export-Csv -Path (Join-Path $Evid 'resumo.csv') -NoTypeInformation -Encoding UTF8
    } else { Write-Host 'Nada foi registrado.' }
    Write-Host "Evidencias: $Evid" -ForegroundColor DarkGray
    Write-Host "Log completo do teste: $LOG_TESTE" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
}
