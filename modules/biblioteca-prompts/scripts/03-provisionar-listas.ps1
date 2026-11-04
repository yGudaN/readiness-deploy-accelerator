#Requires -Version 7.4
<#
.SYNOPSIS
    Cria as listas da Biblioteca (prompts e favoritos) e as colunas que faltam.
    Pode rodar de novo: o que ja existe e mantido.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'Tenant', 'SiteUrl', 'ClientId', 'PromptsListTitle', 'FavoritesListTitle'
if (([uri]$entrada.SiteUrl).Host -ne "$($entrada.Tenant).sharepoint.com") {
    throw "O site precisa estar em https://$($entrada.Tenant).sharepoint.com (o tenant informado na primeira etapa)."
}

$ACOES        = @('Analisar','Perguntar','Resumir','Criar','Encontrar','Aprender','Otimizar','Se preparar','Entender')
$SEGMENTOS    = @('Comercial','DP','Financeiro','Infra','Projetos','RH','Analista Funcional','Desenvolvedor(a)','Gerente de Projetos')
$CATEGORIAS   = @('Área','Função')
$FUNCIONA_COM = @('Outlook','Teams','OneNote','Word','Excel','PowerPoint','Power BI','M365 Copilot','Copilot Studio','D365 CCaaS / Customer Service','D365 Customer Insights - Journeys','D365 Sales','Fabric','Power Apps','Power Automate','Power Pages','Whiteboard')

function ChoiceXml {
    param([string]$Name, [string]$DisplayName, [string[]]$Choices, [bool]$Required = $false)
    $cxml = ($Choices | ForEach-Object { "<CHOICE>$([System.Security.SecurityElement]::Escape($_))</CHOICE>" }) -join ''
    $req = if ($Required) { "Required='TRUE'" } else { '' }
    return "<Field Type='Choice' Name='$Name' StaticName='$Name' DisplayName='$DisplayName' Format='Dropdown' $req><CHOICES>$cxml</CHOICES></Field>"
}

function EnsureList {
    param([string]$Title)
    if (Get-PnPList -Identity $Title -ErrorAction SilentlyContinue) {
        Write-BizappLog "  Lista '$Title' ja existe" -Nivel discreto
    } else {
        Write-BizappLog "  Criando lista '$Title'..."
        New-PnPList -Title $Title -Template GenericList -EnableVersioning | Out-Null
    }
}

function EnsureField {
    param([string]$List, [string]$Name, [string]$Xml)
    if (Get-PnPField -List $List -Identity $Name -ErrorAction SilentlyContinue) {
        Write-BizappLog "    Campo '$Name' ja existe" -Nivel discreto
    } else {
        Write-BizappLog "    Criando campo '$Name'"
        Add-PnPFieldFromXml -List $List -FieldXml $Xml | Out-Null
    }
}

function SetDefaultViewFields {
    param([string]$List, [string[]]$Fields)
    try {
        $view = Get-PnPView -List $List | Where-Object { $_.DefaultView } | Select-Object -First 1
        if ($view) {
            Set-PnPView -List $List -Identity $view.Id -Fields $Fields | Out-Null
            Write-BizappLog "    Exibicao padrao: $($Fields -join ', ')" -Nivel discreto
        }
    } catch {
        Write-BizappLog "    Nao foi possivel atualizar a exibicao padrao: $($_.Exception.Message)" -Nivel aviso
    }
}

$xAcao      = ChoiceXml 'acao' 'Ação' $ACOES $true
$xPrompt    = "<Field Type='Note' Name='Prompt' StaticName='Prompt' DisplayName='Prompt' RichText='FALSE' NumLines='6' Required='TRUE' />"
$xSegmento  = ChoiceXml 'Segmento' 'Segmento' $SEGMENTOS $true
$xCategoria = ChoiceXml 'Categoria' 'Categoria' $CATEGORIAS $true
$xFuncCom   = ChoiceXml 'Funcionacom' 'Funciona com' $FUNCIONA_COM $true
$xAtivo     = "<Field Type='Boolean' Name='Ativo' StaticName='Ativo' DisplayName='Ativo'><Default>1</Default></Field>"
$xPromptId  = "<Field Type='Number' Name='PromptID' StaticName='PromptID' DisplayName='PromptID' Required='TRUE' />"

Import-Module PnP.PowerShell
Write-BizappLog "Conectando a $($entrada.SiteUrl)..."
Connect-PnPOnline -Url $entrada.SiteUrl -AccessToken (Get-BizappToken -Entrada $entrada -Nome SharePoint)
Write-BizappLog 'Conectado.' -Nivel sucesso

try {
    $prompts = $entrada.PromptsListTitle
    Write-BizappLog "[1/2] Lista principal: $prompts"
    EnsureList $prompts
    EnsureField $prompts 'acao' $xAcao
    EnsureField $prompts 'Prompt' $xPrompt
    EnsureField $prompts 'Segmento' $xSegmento
    EnsureField $prompts 'Categoria' $xCategoria
    EnsureField $prompts 'Funcionacom' $xFuncCom
    EnsureField $prompts 'Ativo' $xAtivo
    SetDefaultViewFields $prompts @('Title','acao','Segmento','Categoria','Funcionacom','Ativo','Editor','Modified')

    $favoritos = $entrada.FavoritesListTitle
    Write-BizappLog "[2/2] Lista de favoritos: $favoritos"
    EnsureList $favoritos
    EnsureField $favoritos 'PromptID' $xPromptId
    EnsureField $favoritos 'acao' $xAcao
    EnsureField $favoritos 'Prompt' $xPrompt
    EnsureField $favoritos 'Segmento' $xSegmento
    EnsureField $favoritos 'Categoria' $xCategoria
    EnsureField $favoritos 'Funcionacom' $xFuncCom
    SetDefaultViewFields $favoritos @('Title','PromptID','acao','Segmento','Categoria','Funcionacom','Author','Created')

    Write-BizappLog 'Listas prontas.' -Nivel sucesso
} finally {
    try { Disconnect-PnPOnline } catch {}
}
