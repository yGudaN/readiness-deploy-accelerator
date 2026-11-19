#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-09 · Preflight (secoes 4 e 5 do roteiro, somente leitura): confere DEV, HML e PROD
    (Dataverse nos tres, gerenciado em HML e PROD) e compara a regiao de cada um com a regiao do
    tenant (o host da plataforma fica nela; outra regiao exige Cross-Geo, secao 8). Exige digitar
    SIM para confirmar os ambientes, como o roteiro.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AlmPipelines.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta'

$confirmou = ([string]$entrada.ConfirmacaoAmbientes).Trim() -ceq 'SIM'
Set-BizappSaida -Nome 'ConfirmacaoAmbientes' -Valor ''
if (-not $confirmou) { throw 'Confira os três ambientes e digite SIM no campo de confirmação. Nada foi alterado.' }

$id = Connect-AlmPipelines -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Preflight'
$ambientes = Get-Ambientes
$camadas = [ordered]@{
    DEV  = Find-Ambiente -Ambientes $ambientes -Texto $entrada.AmbienteDev -Camada 'DEV'
    HML  = Find-Ambiente -Ambientes $ambientes -Texto $entrada.AmbienteHml -Camada 'HML'
    PROD = Find-Ambiente -Ambientes $ambientes -Texto $entrada.AmbienteProd -Camada 'PROD'
}
if (@($camadas.Values.EnvironmentId | Select-Object -Unique).Count -lt 3) { throw 'DEV, HML e PROD precisam ser três ambientes diferentes. Nada foi alterado.' }
$padrao = $ambientes | Where-Object Tipo -eq 'Default' | Select-Object -First 1
$regiaoTenant = if ($padrao) { $padrao.Regiao } else { '' }

$linhas = foreach ($c in @($camadas.Keys)) {
    $a = $camadas[$c]
    Write-BizappLog "$c : $(Get-TextoAmbiente $a)"
    [pscustomobject]@{
        Camada = $c; Nome = $a.Nome; EnvironmentId = $a.EnvironmentId; Tipo = $a.Tipo; Regiao = $a.Regiao; Dataverse = [bool]$a.UrlDataverse
        Gerenciado = $a.Gerenciado; GerenciadoObrigatorio = ($c -ne 'DEV'); RegiaoDiferenteDoTenant = ($regiaoTenant -and $a.Regiao -ne $regiaoTenant)
    }
}
Export-BizappEvidencia -Pasta $pasta -Nome 'preflight.csv' -Dados @($linhas)

$falhas = @()
foreach ($l in $linhas) { if (-not $l.Dataverse) { $falhas += "$($l.Camada) sem Dataverse" } }
$naoGerenciados = @($linhas | Where-Object { $_.GerenciadoObrigatorio -and -not $_.Gerenciado } | ForEach-Object Camada)
$foraDaRegiao = @($linhas | Where-Object RegiaoDiferenteDoTenant)
if ($naoGerenciados) { Write-BizappLog "$($naoGerenciados -join ' e ') não $(if ($naoGerenciados.Count -gt 1) { 'são' } else { 'é' }) gerenciado: o pipeline não aceita destino não gerenciado. Use a próxima etapa para corrigir." -Nivel aviso }
if ($foraDaRegiao) {
    Write-BizappLog "Em região diferente do tenant ($regiaoTenant): $(($foraDaRegiao | ForEach-Object { "$($_.Camada) em $($_.Regiao)" }) -join ', '). O pipeline só funciona com esses ambientes se o Cross-Geo Solution Deployment estiver ligado, com aprovação do CoE (seção 8 do roteiro). No teste, sem Cross-Geo, a fase deu o erro 0x80040265." -Nivel aviso
} else { Write-BizappLog "Os três estão na região do tenant ($regiaoTenant): não precisa de Cross-Geo." -Nivel sucesso }
if ($camadas.PROD.Tipo -ne 'Production') { Write-BizappLog "O PROD ($($camadas.PROD.Nome)) é do tipo $($camadas.PROD.Tipo). Para produção, o recomendado é um ambiente do tipo Produção." -Nivel aviso }

Set-BizappSaida -Nome 'IdDev' -Valor $camadas.DEV.EnvironmentId
Set-BizappSaida -Nome 'IdHml' -Valor $camadas.HML.EnvironmentId
Set-BizappSaida -Nome 'IdProd' -Valor $camadas.PROD.EnvironmentId
Set-BizappSaida -Nome 'NomeDev' -Valor $camadas.DEV.Nome
Set-BizappSaida -Nome 'NomeHml' -Valor $camadas.HML.Nome
Set-BizappSaida -Nome 'NomeProd' -Valor $camadas.PROD.Nome
Set-BizappSaida -Nome 'EstadoDev' -Valor (Get-TextoAmbiente $camadas.DEV)
Set-BizappSaida -Nome 'EstadoHml' -Valor (Get-TextoAmbiente $camadas.HML)
Set-BizappSaida -Nome 'EstadoProd' -Valor (Get-TextoAmbiente $camadas.PROD)
Set-BizappSaida -Nome 'CrossGeo' -Valor $(if ($foraDaRegiao) { "Necessário ($(($foraDaRegiao | ForEach-Object Camada) -join ', ') fora de $regiaoTenant)" } else { 'Não necessário' })
Set-BizappSaida -Nome 'Gerenciados' -Valor $(if ($naoGerenciados) { "Falta: $($naoGerenciados -join ', ')" } else { 'HML e PROD gerenciados' })

$aprovada = -not $falhas
$detalhe = if ($aprovada) { 'Preflight concluído.' } else { "O pipeline exige Dataverse nos três ambientes: $($falhas -join '; '). Escolha outros ambientes." }
if ($aprovada) { Write-BizappLog 'Preflight concluído.' -Nivel sucesso }
Write-ResumoAlm -Pasta $pasta -Acao 'Preflight' -Identidade $id -Aprovada $aprovada -Alterou $false -Detalhe $detalhe `
    -Extras ([ordered]@{ Dev = $camadas.DEV.EnvironmentId; Hml = $camadas.HML.EnvironmentId; Prod = $camadas.PROD.EnvironmentId; CrossGeo = [bool]$foraDaRegiao; FaltaGerenciado = ($naoGerenciados -join ',') })
