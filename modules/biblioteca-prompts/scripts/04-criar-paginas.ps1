#Requires -Version 7.4
<#
.SYNOPSIS
    Cria as paginas da Biblioteca e do Dashboard, insere as web parts, aplica
    o layout de tela cheia e desliga a barra social do site.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'Tenant', 'SiteUrl', 'ClientId', 'PromptsListTitle', 'FavoritesListTitle', 'BibliotecaPageName'
if (([uri]$entrada.SiteUrl).Host -ne "$($entrada.Tenant).sharepoint.com") {
    throw "O site precisa estar em https://$($entrada.Tenant).sharepoint.com (o tenant informado na primeira etapa)."
}

$BIB_WEBPART_ID  = 'c8e4a1f2-7b3d-4e9a-8f5c-6d2b1a9e3f4c'
$DASH_WEBPART_ID = 'd3f7a2e4-6b91-4c8f-a5d2-1c9e4b7f3a8b'

$siteUrl  = $entrada.SiteUrl.TrimEnd('/')
$bibPage  = $entrada.BibliotecaPageName -replace '\.aspx$', ''
$dashPage = "$($entrada.DashboardPageName)" -replace '\.aspx$', ''

$bibProps = @{
    targetListTitle    = $entrada.PromptsListTitle
    favoritesListTitle = $entrada.FavoritesListTitle
    promptIdField      = 'PromptID'
    copyFields         = 'acao,Prompt,Segmento,Categoria,Funcionacom'
    extraToolColors    = ''
} | ConvertTo-Json -Compress

$dashProps = @{
    targetListTitle    = $entrada.PromptsListTitle
    favoritesListTitle = $entrada.FavoritesListTitle
    promptIdField      = 'PromptID'
    topN               = 10
} | ConvertTo-Json -Compress

function Setup-Page {
    param([string]$PageName, [string]$WebPartId, [string]$Label, [string]$PropsJson)
    $file = "$PageName.aspx"
    if (Get-PnPPage -Identity $file -ErrorAction SilentlyContinue) {
        Write-BizappLog "  A pagina '$PageName' ja existe e foi mantida (exclua manualmente para recriar)." -Nivel aviso
        return
    }
    Write-BizappLog "  [1/7] Criando a pagina '$PageName'..."
    Add-PnPPage -Name $PageName | Out-Null

    Write-BizappLog "  [2/7] Procurando a web part '$Label' no site..."
    $wpIdNorm = $WebPartId.ToLower()
    $comp = Get-PnPAvailablePageComponents -Page $file -ErrorAction SilentlyContinue | Where-Object {
        ($_.Id.ToString() -replace '[{}]', '').ToLower() -eq $wpIdNorm -or $_.Name -eq $Label
    } | Select-Object -First 1

    if (-not $comp) {
        Write-BizappLog "  A web part '$Label' nao foi encontrada. Confira se o app foi adicionado ao site (etapa anterior)." -Nivel erro
        try {
            $apps = Get-PnPApp -Scope Site -ErrorAction SilentlyContinue
            Write-BizappLog '  Apps instalados neste site:' -Nivel discreto
            if ($apps) { $apps | ForEach-Object { Write-BizappLog "    $($_.Title) (implantado: $($_.Deployed))" -Nivel discreto } }
            else { Write-BizappLog '    (nenhum)' -Nivel discreto }
        } catch {}
        # Remove a pagina em branco recem-criada para que a etapa possa ser repetida
        Remove-PnPPage -Identity $file -Force -ErrorAction SilentlyContinue
        throw "Web part '$Label' nao encontrada no site."
    }

    Write-BizappLog "  [3/7] Componente encontrado: $($comp.Name)"
    Write-BizappLog '  [4/7] Adicionando a web part na pagina...'
    Add-PnPPageWebPart -Page $file -Component $comp | Out-Null

    Write-BizappLog '  [5/7] Configurando as propriedades da web part...'
    try {
        $instancia = Get-PnPPageComponent -Page $file | Where-Object {
            ($_.WebPartId.ToString() -replace '[{}]', '').ToLower() -eq $wpIdNorm
        } | Select-Object -First 1
        if ($instancia) {
            Set-PnPPageWebPart -Page $file -Identity $instancia.InstanceId -PropertiesJson $PropsJson | Out-Null
        } else {
            Write-BizappLog '     Instancia da web part nao encontrada para configurar.' -Nivel aviso
        }
    } catch {
        Write-BizappLog "     Falha ao configurar as propriedades: $($_.Exception.Message)" -Nivel aviso
    }

    Write-BizappLog '  [6/7] Aplicando o layout de tela cheia...'
    try {
        Set-PnPPage -Identity $file -LayoutType SingleWebPartAppPage | Out-Null
    } catch {
        Write-BizappLog "     Falha ao aplicar o layout: $($_.Exception.Message)" -Nivel aviso
    }

    Write-BizappLog '  [7/7] Publicando...'
    Set-PnPPage -Identity $file -Publish | Out-Null
    Write-BizappLog "  Pagina '$PageName' pronta." -Nivel sucesso
}

Import-Module PnP.PowerShell
Write-BizappLog "Conectando a $siteUrl..."
Connect-PnPOnline -Url $siteUrl -AccessToken (Get-BizappToken -Entrada $entrada -Nome SharePoint)
Write-BizappLog 'Conectado.' -Nivel sucesso

try {
    Write-BizappLog "[1/3] Pagina da Biblioteca: $bibPage"
    Setup-Page -PageName $bibPage -WebPartId $BIB_WEBPART_ID -Label 'Biblioteca de Prompts e Skills' -PropsJson $bibProps
    Set-BizappSaida -Nome 'BibliotecaUrl' -Valor "$siteUrl/SitePages/$bibPage.aspx"

    if ($dashPage) {
        Write-BizappLog "[2/3] Pagina do Dashboard: $dashPage"
        Setup-Page -PageName $dashPage -WebPartId $DASH_WEBPART_ID -Label 'Dashboard — Biblioteca de Prompts e Skills' -PropsJson $dashProps
        Set-BizappSaida -Nome 'DashboardUrl' -Valor "$siteUrl/SitePages/$dashPage.aspx"
    } else {
        Write-BizappLog '[2/3] Dashboard nao informado, etapa pulada.' -Nivel discreto
    }

    Write-BizappLog '[3/3] Desligando a barra social das paginas...'
    Set-PnPSite -SocialBarOnSitePagesDisabled $true
    Write-BizappLog 'Paginas criadas e configuradas.' -Nivel sucesso
} finally {
    try { Disconnect-PnPOnline } catch {}
}
