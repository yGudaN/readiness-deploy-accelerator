#Requires -Version 7.4
<#
.SYNOPSIS
    Instala o Copilot Agent Kit (CopilotStudioAccelerator) a partir da ultima release
    oficial da Microsoft no GitHub.

.NOTES
    A importacao e feita sem preencher as referencias de conexao: os fluxos ficam desligados
    e sao configurados depois pelo Setup Wizard do kit. No teste manual (ambiente de demo,
    nov/2026) a importacao levou 34 min e terminou com sucesso.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Dataverse.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'EnvironmentUrl'
Connect-Dataverse -Url $entrada.EnvironmentUrl -Token (Get-BizappToken -Entrada $entrada -Nome Dataverse)

if (-not (Get-SolucaoInstalada -NomeUnico 'CreatorKitCore')) {
    throw 'O Creator Kit não está instalado neste ambiente. Volte e conclua a etapa "Instalar o Creator Kit".'
}

$versao = Install-SolucaoDaRelease -Repositorio 'microsoft/Power-CAT-Copilot-Studio-Kit' -PadraoArquivo '^(CopilotAgentKit|CopilotStudioKit)_.*_managed\.zip$' `
    -NomeUnico 'CopilotStudioAccelerator' -Nome 'Copilot Agent Kit' -LimiteMinutos 90
Set-BizappSaida -Nome 'VersaoAgentKit' -Valor $versao
