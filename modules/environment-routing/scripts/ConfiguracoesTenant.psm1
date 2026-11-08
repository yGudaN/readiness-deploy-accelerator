# Leitura e alteracao das configuracoes do tenant do Power Platform (servico de administracao
# "BAP", o mesmo usado pelo admin center, pelo Get/Set-TenantSettings e pelo "pac admin").

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

# Mesmos enderecos e versao usados pelo "pac admin list/update-tenant-settings" (conferidos no log do PAC CLI):
# a alteracao fica em /scopes/admin/updateTenantSettings; sem o "scopes/admin" a API responde NotFound.
$script:URL_BAP = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform'
$script:VERSAO = 'api-version=2021-04-01'

function Invoke-Bap {
    param([Parameter(Mandatory)][string]$Acao, [Parameter(Mandatory)][string]$Token, [string]$Corpo)
    $parametros = @{
        Method  = 'Post'
        Uri     = "$script:URL_BAP/$Acao`?$script:VERSAO"
        Headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    }
    if ($Corpo) { $parametros.Body = [System.Text.Encoding]::UTF8.GetBytes($Corpo); $parametros.ContentType = 'application/json; charset=utf-8' }
    try {
        Invoke-RestMethod @parametros
    } catch {
        $codigo = [int]$_.Exception.Response.StatusCode
        $detalhe = try { $e = $_.ErrorDetails.Message | ConvertFrom-Json; "$($e.error.code): $($e.error.message)" } catch { $null }
        if ($codigo -eq 401) { throw 'O acesso ao admin do Power Platform expirou ou foi negado (401). Rode a etapa de novo para fazer login.' }
        if ($codigo -eq 403) { throw "Sem permissão para alterar as configurações do tenant (403). É preciso ser Administrador do Power Platform. $detalhe" }
        throw "Admin do Power Platform: $(if ($detalhe) { $detalhe } else { $_.Exception.Message })"
    }
}

function Get-ConfiguracoesTenant {
    param([Parameter(Mandatory)][string]$Token)
    return Invoke-Bap -Acao 'listTenantSettings' -Token $Token
}

function Set-GovernancaTenant {
    <#
    Envia so as propriedades informadas de powerPlatform.governance ("payload minimo" do
    COE-IA-003): o objeto completo das configuracoes tem propriedades somente leitura e de
    preview que a API recusa (InvalidManagedAppsPreviewValueInTenantSettings, TenantSettingReadOnly).
    #>
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][hashtable]$Valores)
    $corpo = @{ powerPlatform = @{ governance = $Valores } } | ConvertTo-Json -Depth 5 -Compress
    Write-BizappLog "Enviando: $corpo" -Nivel discreto
    Invoke-Bap -Acao 'scopes/admin/updateTenantSettings' -Token $Token -Corpo $corpo | Out-Null
}

function Get-EstadoRoteamento {
    <# Estado atual do roteamento em termos da tela: Ligado/Desligado e quem e roteado ("novos"/"todos"). #>
    param([Parameter(Mandatory)][string]$Token)
    $governanca = (Get-ConfiguracoesTenant -Token $Token).powerPlatform.governance
    $ligado = [bool]$governanca.enableDefaultEnvironmentRouting
    $quem = if ([bool]$governanca.environmentRoutingAllMakers) { 'todos' } else { 'novos' }
    $texto = if (-not $ligado) { 'Desligado' } elseif ($quem -eq 'todos') { 'Ligado, para makers novos e existentes' } else { 'Ligado, só para makers novos' }
    return [pscustomobject]@{ Ligado = $ligado; Quem = $quem; Texto = $texto }
}

function Get-ContaDoToken {
    <# Conta e tenant de quem fez login (lidos do proprio token). #>
    param([Parameter(Mandatory)][string]$Token)
    $parte = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $parte += '=' * ((4 - $parte.Length % 4) % 4)
    $dados = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parte)) | ConvertFrom-Json
    return [pscustomobject]@{ Conta = $(if ($dados.upn) { $dados.upn } else { $dados.unique_name }); TenantId = $dados.tid }
}

Export-ModuleMember -Function Get-ConfiguracoesTenant, Set-GovernancaTenant, Get-EstadoRoteamento, Get-ContaDoToken
