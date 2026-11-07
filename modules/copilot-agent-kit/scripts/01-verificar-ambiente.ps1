#Requires -Version 7.4
<#
.SYNOPSIS
    Confere o ambiente de destino: nome, versao, se quem esta logado e Administrador do
    sistema e quais kits ja estao instalados. Nao altera nada.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Dataverse.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl'
Connect-Dataverse -Url $entrada.EnvironmentUrl -Token (Get-BizappToken -Entrada $entrada -Nome Dataverse)

Write-BizappLog "Conectando a $($entrada.EnvironmentUrl)..."
$org = (Invoke-Dataverse -Caminho "RetrieveCurrentOrganization(AccessType=@p)?@p=Microsoft.Dynamics.CRM.EndpointAccessType'Default'").Detail
$eu = Invoke-Dataverse -Caminho 'WhoAmI'
Write-BizappLog "Ambiente: $($org.FriendlyName) (versão $($org.OrganizationVersion))" -Nivel sucesso
Set-BizappSaida -Nome 'NomeAmbiente' -Valor $org.FriendlyName
Set-BizappSaida -Nome 'EnvironmentId' -Valor $org.EnvironmentId

# Papel Administrador do sistema (id fixo do papel padrao em todos os ambientes)
$ADMIN_SISTEMA = '627090ff-40a3-4053-8790-584edc5be201'
$papeis = Invoke-Dataverse -Caminho "systemusers($($eu.UserId))/systemuserroles_association?`$select=name,_roletemplateid_value"
$usuario = Invoke-Dataverse -Caminho "systemusers($($eu.UserId))?`$select=domainname"
if ($papeis.value | Where-Object { $_._roletemplateid_value -eq $ADMIN_SISTEMA }) {
    Write-BizappLog "Conta $($usuario.domainname) é Administrador do sistema." -Nivel sucesso
} else {
    # O papel tambem pode vir de uma equipe (grupo do Entra), que nao aparece aqui: so avisa
    $nomes = ($papeis.value.name | Sort-Object -Unique) -join ', '
    Write-BizappLog "A conta $($usuario.domainname) não tem o papel Administrador do sistema atribuído diretamente (papéis: $(if ($nomes) { $nomes } else { 'nenhum' }))." -Nivel aviso
    Write-BizappLog 'Sem esse papel a importação vai falhar. Se o papel vem de uma equipe, pode seguir; senão, entre com uma conta administradora.' -Nivel aviso
}

foreach ($kit in @(@{ Nome = 'Creator Kit'; Unico = 'CreatorKitCore' }, @{ Nome = 'Copilot Agent Kit'; Unico = 'CopilotStudioAccelerator' })) {
    $s = Get-SolucaoInstalada -NomeUnico $kit.Unico
    if ($s) { Write-BizappLog "$($kit.Nome): já instalado (versão $($s.version))." -Nivel discreto }
    else { Write-BizappLog "$($kit.Nome): não instalado." -Nivel discreto }
}
