#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-26 · Consultar (somente leitura): conta, funcao (Administrador Global ou do Intune),
    licenca do Intune e politicas do Edge criadas por este item.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'EdgeCopilot.psm1') -Force
$entrada = Read-BizappEntrada

$id = Connect-EdgeCopilot -Entrada $entrada -PrimeiraEtapa
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'Consultar'
Write-BizappLog "Conta: $($id.Conta)"

$ctx = Get-Contexto
Export-BizappEvidencia -Pasta $pasta -Nome 'licencas-intune.csv' -Dados @($ctx.Planos)
if ($ctx.Papeis) { Write-BizappLog "Função: $($ctx.Papeis -join ', ')" -Nivel sucesso }
else { Write-BizappLog 'A conta não é Administrador Global nem Administrador do Intune: a criação deve ser recusada.' -Nivel aviso }

$estado = ''
$doItem = @()
if (-not $ctx.TemIntune) {
    Write-BizappLog 'O tenant não tem licença do Microsoft Intune ativa (a mobilidade básica do Office 365 não basta). A política do Edge não poderá ser criada.' -Nivel aviso
    $estado = 'Bloqueado: tenant sem Intune'
} else {
    Write-BizappLog "Licença do Intune: $((@($ctx.Planos | Where-Object Status -eq 'Success').Plano | Select-Object -Unique) -join ', ')" -Nivel sucesso
    $todas = Get-Lista 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$select=id,name,description,isAssigned'
    $doItem = @($todas | Where-Object { Test-PoliticaDoItem $_ })
    Export-BizappEvidencia -Pasta $pasta -Nome 'politicas-do-item.csv' -Dados @($doItem | Select-Object id, name, isAssigned)
    $estado = if ($doItem) { ($doItem | ForEach-Object { "$($_.name)$(if ($_.isAssigned) { ' (atribuída)' } else { ' (sem atribuição)' })" }) -join '; ' } else { 'Nenhuma' }
    Write-BizappLog "Políticas do Edge criadas por este item: $estado"
}

Set-BizappSaida -Nome 'Conta' -Valor $id.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $id.TenantId
Set-BizappSaida -Nome 'LicencaIntune' -Valor $(if ($ctx.TemIntune) { 'Encontrada' } else { 'Não encontrada' })
Set-BizappSaida -Nome 'FuncaoIntune' -Valor $(if ($ctx.Papeis) { $ctx.Papeis -join ', ' } else { 'Sem a função' })
Set-BizappSaida -Nome 'EstadoPolitica' -Valor $estado
Write-ResumoEdge -Pasta $pasta -Acao 'Consultar' -Identidade $id -Aprovada $true -Alterou $false -Detalhe 'Consulta concluída.' `
    -Extras ([ordered]@{ TemIntune = $ctx.TemIntune; Funcao = ($ctx.Papeis -join ', '); PoliticasDoItem = $doItem.Count })
