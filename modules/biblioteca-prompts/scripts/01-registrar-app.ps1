#Requires -Version 7.4
<#
.SYNOPSIS
    Cria (ou atualiza) no Entra ID o app usado pela Biblioteca e devolve o ClientId.

.NOTES
    Usa o token do Microsoft Graph obtido pelo instalador (login no navegador escolhido).
    Faz o mesmo que o Register-PnPEntraIDAppForInteractiveLogin: app de cliente publico,
    redirecionamento http://localhost e permissoes delegadas AllSites.FullControl
    (SharePoint) e User.Read (Graph). As permissoes sao aceitas na etapa seguinte.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'Tenant', 'AppName'
$cabecalhos = @{ Authorization = "Bearer $(Get-BizappToken -Entrada $entrada -Nome Graph)" }

$GRAPH_URL      = 'https://graph.microsoft.com/v1.0'
$APP_SHAREPOINT = '00000003-0000-0ff1-ce00-000000000000'
$APP_GRAPH      = '00000003-0000-0000-c000-000000000000'

function Invoke-Graph {
    param([string]$Metodo = 'GET', [Parameter(Mandatory)][string]$Caminho, $Corpo)
    $parametros = @{ Method = $Metodo; Uri = "$GRAPH_URL$Caminho"; Headers = $cabecalhos; ContentType = 'application/json' }
    if ($null -ne $Corpo) { $parametros.Body = $Corpo | ConvertTo-Json -Depth 10 -Compress }
    Invoke-RestMethod @parametros
}

function Get-IdPermissao {
    <# Id da permissao delegada publicada pelo recurso (SharePoint ou Graph) neste tenant. #>
    param([string]$AppIdRecurso, [string]$Permissao)
    $sp = Invoke-Graph -Caminho "/servicePrincipals(appId='$AppIdRecurso')?`$select=oauth2PermissionScopes"
    $id = ($sp.oauth2PermissionScopes | Where-Object value -eq $Permissao).id
    if (-not $id) { throw "Permissao '$Permissao' nao encontrada no recurso $AppIdRecurso." }
    return $id
}

Write-BizappLog 'Lendo as permissões do SharePoint e do Microsoft Graph...' -Nivel discreto
$configuracao = @{
    signInAudience         = 'AzureADMyOrg'
    isFallbackPublicClient = $true
    publicClient           = @{ redirectUris = @('https://login.microsoftonline.com/common/oauth2/nativeclient', 'http://localhost') }
    requiredResourceAccess = @(
        @{ resourceAppId = $APP_SHAREPOINT; resourceAccess = @(@{ id = (Get-IdPermissao $APP_SHAREPOINT 'AllSites.FullControl'); type = 'Scope' }) },
        @{ resourceAppId = $APP_GRAPH; resourceAccess = @(@{ id = (Get-IdPermissao $APP_GRAPH 'User.Read'); type = 'Scope' }) }
    )
}

$nome = $entrada.AppName
$filtro = [uri]::EscapeDataString("displayName eq '$($nome.Replace("'", "''"))'")
$existentes = @((Invoke-Graph -Caminho "/applications?`$filter=$filtro&`$select=id,appId,displayName").value)
if ($existentes.Count -gt 1) {
    throw "Existem $($existentes.Count) apps com o nome '$nome' no tenant. Use outro nome ou cole o ClientId do app certo."
}

if ($existentes.Count -eq 1) {
    $app = $existentes[0]
    Write-BizappLog "O app '$nome' já existe. Atualizando a configuração..." -Nivel aviso
    Invoke-Graph -Metodo PATCH -Caminho "/applications/$($app.id)" -Corpo $configuracao | Out-Null
} else {
    Write-BizappLog "Criando o app '$nome'..."
    $app = Invoke-Graph -Metodo POST -Caminho '/applications' -Corpo ($configuracao + @{ displayName = $nome })
}

# Aplicativo empresarial (service principal): e onde o administrador concede o consentimento
try {
    Invoke-Graph -Metodo POST -Caminho '/servicePrincipals' -Corpo @{ appId = $app.appId } | Out-Null
} catch {
    if ("$($_.Exception.Response.StatusCode)" -notmatch 'Conflict' -and "$_" -notmatch 'already exists') {
        Write-BizappLog "Não foi possível criar o aplicativo empresarial agora: $($_.Exception.Message)" -Nivel aviso
    }
}

Set-BizappSaida -Nome 'ClientId' -Valor $app.appId
Write-BizappLog "App pronto. ClientId: $($app.appId)" -Nivel sucesso
Write-BizappLog 'As permissões do app são aceitas na próxima etapa.' -Nivel discreto
