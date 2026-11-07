#Requires -Version 7.4
<#
.SYNOPSIS
    Instala o Creator Kit (CreatorKitCore), dependencia obrigatoria do Copilot Agent Kit,
    a partir da ultima release oficial da Microsoft no GitHub.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Dataverse.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl'
Connect-Dataverse -Url $entrada.EnvironmentUrl -Token (Get-BizappToken -Entrada $entrada -Nome Dataverse)

$versao = Install-SolucaoDaRelease -Repositorio 'microsoft/powercat-creator-kit' -PadraoArquivo '^CreatorKitCore_.*_managed\.zip$' `
    -NomeUnico 'CreatorKitCore' -Nome 'Creator Kit' -LimiteMinutos 30
Set-BizappSaida -Nome 'VersaoCreatorKit' -Valor $versao
