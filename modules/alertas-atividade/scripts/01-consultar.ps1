#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-30 · Consultar (somente leitura): conta, funcoes, licencas e as politicas de alerta do
    tenant, destacando as criadas por este item.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AlertasAtividade.psm1') -Force
$entrada = Read-BizappEntrada

# Primeira etapa: ainda nao ha conta confirmada, entao vale a do login
$id = Get-BizappIdentidade -Token (Get-BizappToken -Entrada $entrada -Nome Graph)
$entrada.TenantId = $id.TenantId
$entrada.Conta = $id.Conta

try {
    $ctx = Connect-AlertasAtividade -Entrada $entrada
    $pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
    Write-ContextoAlertas -Pasta $pasta -Ctx $ctx -Acao 'Consultar'

    Write-BizappLog 'Lendo as políticas de alerta...'
    $todas = Get-AlertasTenant
    $doItem = @($todas | Where-Object { Test-AlertaDoItem $_ })
    $personalizadas = @($todas | Where-Object { (ConvertTo-SafeText $_.IsSystemRule) -ne 'True' })
    $lista = @(foreach ($a in $todas) {
            [pscustomobject]@{
                Name = ConvertTo-SafeText $a.Name; Padrao = ConvertTo-SafeText $a.IsSystemRule; CriadaPorEsteItem = (Test-AlertaDoItem $a)
                AggregationType = ConvertTo-SafeText $a.AggregationType; Operation = ConvertTo-SafeText $a.Operation
                Severity = ConvertTo-SafeText $a.Severity; Disabled = ConvertTo-SafeText $a.Disabled
            }
        })
    Export-BizappEvidencia -Pasta $pasta -Nome 'politicas-alerta.csv' -Dados $lista
    Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-antes.csv' -Dados @($(if ($doItem) { $doItem | ForEach-Object { Get-AlertSnapshot -Alert $_ -Stage 'Antes' } } else { Get-AlertSnapshot -Alert $null -Stage 'Antes' -Nome '' }))

    $textoItem = if ($doItem) { ($doItem | ForEach-Object { "$($_.Name) ($(Get-TextoEstadoAlerta $_))" }) -join '; ' } else { 'Nenhuma' }
    Write-BizappLog "Políticas de alerta no tenant: $($todas.Count) ($($personalizadas.Count) personalizadas)"
    Write-BizappLog "Criadas por este item: $textoItem"
    if (-not $ctx.TemLicenca) {
        Write-BizappLog 'O tenant não tem licença com alertas avançados (ex.: Microsoft 365 E5 ou Office 365 E5): a política não poderá ser criada.' -Nivel aviso
    }
    if (-not $ctx.PodeCriar) {
        Write-BizappLog 'A conta pode ver, mas não criar políticas de alerta (falta a função Manage Alerts ou Organization Configuration no Microsoft Purview).' -Nivel aviso
    }

    Set-BizappSaida -Nome 'Conta' -Valor $ctx.Identidade.Conta
    Set-BizappSaida -Nome 'TenantId' -Valor $ctx.Identidade.TenantId
    Set-BizappSaida -Nome 'LicencaAlertas' -Valor $(if ($ctx.TemLicenca) { 'Encontrada' } else { 'Não encontrada' })
    Set-BizappSaida -Nome 'PoliticasAlerta' -Valor "$($todas.Count) ($($personalizadas.Count) personalizadas)"
    Set-BizappSaida -Nome 'AlertasDoItem' -Valor $textoItem

    Write-ResumoAlertas -Pasta $pasta -Acao 'Consultar' -Ctx $ctx -Aprovada $true -Alterou $false -Resultado 'Validado' `
        -Detalhe 'Consulta concluída.' -Extras ([ordered]@{ PoliticasNoTenant = $todas.Count; PoliticasDoItem = $doItem.Count })
} finally {
    Disconnect-AlertasAtividade
}
