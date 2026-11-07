#Requires -Version 7.4
<#
.SYNOPSIS
    Liga os dois recursos que o Creator Kit e o Copilot Agent Kit exigem no ambiente:
      - Power Apps component framework para canvas apps (coluna da tabela organization, no Dataverse);
      - Power Apps code apps (configuracao de gerenciamento do ambiente, na Power Platform API).
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Dataverse.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl'
Connect-Dataverse -Url $entrada.EnvironmentUrl -Token (Get-BizappToken -Entrada $entrada -Nome Dataverse)

# 1) Componentes de codigo em canvas apps (Dataverse)
$org = (Invoke-Dataverse -Caminho 'organizations?$select=organizationid,iscustomcontrolsincanvasappsenabled').value[0]
if ($org.iscustomcontrolsincanvasappsenabled) {
    Write-BizappLog 'Componentes de código em canvas apps: já estava ligado.' -Nivel sucesso
} else {
    Write-BizappLog 'Ligando componentes de código em canvas apps...'
    Invoke-Dataverse -Metodo PATCH -Caminho "organizations($($org.organizationid))" -Corpo '{"iscustomcontrolsincanvasappsenabled":true}' | Out-Null
    Write-BizappLog 'Componentes de código em canvas apps: ligado.' -Nivel sucesso
}

# 2) Code apps (Power Platform API)
$ambiente = (Invoke-Dataverse -Caminho "RetrieveCurrentOrganization(AccessType=@p)?@p=Microsoft.Dynamics.CRM.EndpointAccessType'Default'").Detail
try {
    $ligou = Set-CodeAppsHabilitado -EnvironmentId $ambiente.EnvironmentId -Token (Get-BizappToken -Entrada $entrada -Nome PowerPlatform)
    if ($ligou) { Write-BizappLog 'Power Apps code apps: ligado.' -Nivel sucesso }
    else { Write-BizappLog 'Power Apps code apps: já estava ligado.' -Nivel sucesso }
} catch {
    Write-BizappLog $_.Exception.Message -Nivel erro
    Write-BizappLog 'Ligue manualmente pelo botão "Abrir as configurações do ambiente": em "Power Apps code apps", ative "Ativar code apps", salve e clique em "Executar novamente".' -Nivel aviso
    throw 'Power Apps code apps não foi ligado.'
}
