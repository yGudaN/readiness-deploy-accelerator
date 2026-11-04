#Requires -Version 7.4
<#
.SYNOPSIS
    Confere se as permissoes do app foram concedidas, acessando o site raiz do SharePoint.

.NOTES
    O login desta etapa (feito pelo instalador, com o ClientId do app) e o momento em que
    o Entra ID pede o consentimento. Se ele falhar por falta de aprovacao, o script nem
    chega a rodar e o instalador mostra o motivo no log.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'Tenant', 'ClientId'

Import-Module PnP.PowerShell

$url = "https://$($entrada.Tenant).sharepoint.com"
Write-BizappLog "Conectando a $url..."
try {
    Connect-PnPOnline -Url $url -AccessToken (Get-BizappToken -Entrada $entrada -Nome SharePoint)
    $web = Get-PnPWeb
    Write-BizappLog "Acesso confirmado ao site '$($web.Title)'." -Nivel sucesso
    Write-BizappLog 'As permissões do app estão concedidas. Pode avançar.' -Nivel sucesso
} finally {
    try { Disconnect-PnPOnline } catch {}
}
