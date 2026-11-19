#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-27 · Cria (ou atualiza) no Entra ID o app usado para falar com o Defender, como o app
    CoE-AUTO27-Defender do relatorio: single-tenant, cliente publico (retorno http://localhost),
    permissao delegada Ti.ReadWrite do WindowsDefenderATP. Sem segredo nem certificado.
    Se o tenant nao tem Defender for Endpoint, a API WindowsDefenderATP nao existe e nada e criado.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'AppName'

$token = Get-BizappToken -Entrada $entrada -Nome Graph
$id = Get-BizappIdentidade -Token $token
$cab = @{ Authorization = "Bearer $token" }
$GRAPH = 'https://graph.microsoft.com/v1.0'
$DEFENDER = 'fc780465-2017-40d4-a0c5-307022471b92'   # WindowsDefenderATP
$pasta = New-BizappEvidencias -Item 'Bloqueio-IA' -Acao 'RegistrarApp'

function Invoke-Graph([string]$Metodo = 'GET', [string]$Caminho, $Corpo) {
    $p = @{ Method = $Metodo; Uri = "$GRAPH$Caminho"; Headers = $cab; ContentType = 'application/json' }
    if ($null -ne $Corpo) { $p.Body = $Corpo | ConvertTo-Json -Depth 10 -Compress }
    Invoke-RestMethod @p
}

Write-BizappLog "Conta: $($id.Conta)"
Write-BizappLog 'Procurando a API do Microsoft Defender for Endpoint no tenant...' -Nivel discreto
$sp = $null
try { $sp = Invoke-Graph -Caminho "/servicePrincipals(appId='$DEFENDER')?`$select=id,oauth2PermissionScopes" } catch { }
if (-not $sp) {
    Set-BizappSaida -Nome 'DefenderNoTenant' -Valor 'Não encontrado'
    throw 'O tenant não tem o Microsoft Defender for Endpoint (a API WindowsDefenderATP não existe no Entra ID). É preciso Microsoft 365 E5, Defender for Endpoint P2 ou Defender for Business. Nada foi criado.'
}
$escopo = $sp.oauth2PermissionScopes | Where-Object value -eq 'Ti.ReadWrite' | Select-Object -First 1
if (-not $escopo) { throw 'A permissão Ti.ReadWrite não foi encontrada na API do Defender. Nada foi criado.' }

$configuracao = @{
    signInAudience         = 'AzureADMyOrg'
    isFallbackPublicClient = $true
    publicClient           = @{ redirectUris = @('http://localhost') }
    requiredResourceAccess = @(@{ resourceAppId = $DEFENDER; resourceAccess = @(@{ id = $escopo.id; type = 'Scope' }) })
}
$nome = ([string]$entrada.AppName).Trim()
$filtro = [uri]::EscapeDataString("displayName eq '$($nome.Replace("'", "''"))'")
$existentes = @((Invoke-Graph -Caminho "/applications?`$filter=$filtro&`$select=id,appId,displayName").value)
if ($existentes.Count -gt 1) { throw "Existem $($existentes.Count) apps com o nome '$nome'. Use outro nome ou informe o ID do app certo. Nada foi alterado." }
if ($existentes.Count -eq 1) {
    $app = $existentes[0]
    Write-BizappLog "O app '$nome' já existe. Atualizando a configuração..." -Nivel aviso
    Invoke-Graph -Metodo PATCH -Caminho "/applications/$($app.id)" -Corpo $configuracao | Out-Null
} else {
    Write-BizappLog "Criando o app '$nome'..."
    $app = Invoke-Graph -Metodo POST -Caminho '/applications' -Corpo ($configuracao + @{ displayName = $nome })
}
try { Invoke-Graph -Metodo POST -Caminho '/servicePrincipals' -Corpo @{ appId = $app.appId } | Out-Null } catch { }

Export-BizappEvidencia -Pasta $pasta -Nome 'app.csv' -Dados ([pscustomobject]@{ Nome = $nome; ClientId = $app.appId; Permissao = 'WindowsDefenderATP/Ti.ReadWrite (delegada)'; Segredo = 'Nenhum' })
Set-BizappSaida -Nome 'DefenderNoTenant' -Valor 'Encontrado'
Set-BizappSaida -Nome 'DefenderClientId' -Valor $app.appId
Set-BizappSaida -Nome 'Conta' -Valor $id.Conta
Set-BizappSaida -Nome 'TenantId' -Valor $id.TenantId
Write-BizappLog "App pronto. ID do app: $($app.appId)" -Nivel sucesso
Write-BizappLog 'No primeiro login da próxima etapa, aceite as permissões do app para a organização.' -Nivel discreto
