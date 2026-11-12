#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-20 · Consultar (somente leitura): conta, funcoes, licencas e os 5 objetos do modelo
    (DLP da Power Platform, Acesso Condicional, DLP do Purview, rotulo e politica de rotulos).
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ModeloProtecao.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'Prefixo'
$nomes = Get-NomesModelo -Prefixo ([string]$entrada.Prefixo).Trim()

# Primeira etapa: ainda nao ha conta confirmada, entao vale a do login
$id = Get-BizappIdentidade -Token (Get-BizappToken -Entrada $entrada -Nome Graph)
$entrada.TenantId = $id.TenantId
$entrada.Conta = $id.Conta

try {
    $ctx = Connect-ModeloProtecao -Entrada $entrada
    $pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
    Write-EvidenciasModelo -Pasta $pasta -Ctx $ctx -Acao 'Consultar' -Nomes $nomes

    Write-BizappLog 'Lendo DLP da Power Platform, Acesso Condicional, DLP do Purview e rótulos...'
    $estado = Read-EstadoModelo -Ctx $ctx -Nomes $nomes
    Save-EstadoJson -Pasta $pasta -Nome 'configuracao-antes.json' -Estado $estado
    Save-EstadoJson -Pasta $pasta -Nome 'configuracao-depois.json' -Estado $estado

    Write-BizappLog "No tenant: $(@($estado.PowerPlatformPolicies).Count) DLP da Power Platform, $(@($estado.ConditionalAccessPolicies).Count) de Acesso Condicional$(if ($ctx.Purview) { ", $(@($estado.PurviewDlpPolicies).Count) DLP do Purview e $(@($estado.Labels).Count) rótulos" })."
    $t = Write-EstadoSaidas -Estado $estado -Ctx $ctx
    foreach ($k in $t.Keys) { Write-BizappLog "$($k -replace '^Estado', ''): $($t[$k])" -Nivel discreto }
    if (-not $ctx.TemP1) { Write-BizappLog 'Sem licença Microsoft Entra ID P1 ou P2: o Acesso Condicional não poderá ser criado.' -Nivel aviso }

    Set-BizappSaida -Nome 'Conta' -Valor $ctx.Identidade.Conta
    Set-BizappSaida -Nome 'TenantId' -Valor $ctx.Identidade.TenantId
    Set-BizappSaida -Nome 'LicencaEntra' -Valor $(if ($ctx.TemP1) { 'Encontrada' } else { 'Não encontrada' })
    Set-BizappSaida -Nome 'Purview' -Valor $(if ($ctx.Purview) { 'Conectado' } else { 'Não disponível' })

    $acoes = [System.Collections.Generic.List[object]]::new()
    $acoes.Add([pscustomobject]@{ DataHora = Get-Date; Componente = 'Todos'; Operacao = 'Consultar'; Status = 'Sucesso'; Detalhe = 'Consulta sem alteração administrativa.' })
    if (-not $ctx.Purview) {
        foreach ($c in 'DLP do Microsoft Purview', 'Rótulo de sensibilidade', 'Política de rótulos') {
            $acoes.Add([pscustomobject]@{ DataHora = Get-Date; Componente = $c; Operacao = 'Validar acesso'; Status = 'Bloqueado'; Detalhe = $ctx.PurviewMotivo })
        }
    }
    Write-ResumoModelo -Pasta $pasta -Acao 'Consultar' -Ctx $ctx -Acoes $acoes -ResultadoEsperado 'Consulta concluída; configuração antes e depois equivalente.'
} finally {
    Disconnect-ModeloProtecao
}
