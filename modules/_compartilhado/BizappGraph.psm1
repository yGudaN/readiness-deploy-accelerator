# Conexao ao Microsoft Graph PowerShell com o token do login do instalador (sem novo login no
# navegador e sem codigo de dispositivo). Usado pelos itens de identidade (AUTO-22, AUTO-33...).

Import-Module (Join-Path $PSScriptRoot 'BizappInstalador.psm1')

function Import-BizappModulosGraph {
    <#
    Importa os submodulos do Graph na MESMA versao. Versoes misturadas (ex.: Authentication 2.41
    e Groups 2.30) quebram com erros de tipo ao carregar; por isso escolhe a maior versao
    instalada em comum a todos os modulos pedidos.
    #>
    param([Parameter(Mandatory)][string[]]$Modulos)
    $todos = @('Microsoft.Graph.Authentication') + $Modulos | Select-Object -Unique
    $versoesPorModulo = foreach ($m in $todos) {
        , @(Get-Module -ListAvailable -Name $m | ForEach-Object { $_.Version.ToString() })
    }
    $comuns = $versoesPorModulo[0]
    foreach ($v in $versoesPorModulo) { $comuns = @($comuns | Where-Object { $_ -in $v }) }
    if (-not $comuns) {
        throw "Os módulos do Microsoft Graph precisam estar instalados na mesma versão ($($todos -join ', ')). Reinstale-os pela tela de pré-requisitos."
    }
    $versao = $comuns | Sort-Object { [version]$_ } | Select-Object -Last 1
    # -Global: sem ele os comandos ficam so dentro deste .psm1 e o script da etapa acabaria
    # carregando outra versao do Graph por autoload (ou nao achando o comando)
    foreach ($m in $todos) { Import-Module $m -RequiredVersion $versao -Global -ErrorAction Stop }
    Write-BizappLog "Microsoft Graph PowerShell $versao" -Nivel discreto
}

function Connect-BizappGraph {
    <#
    Conecta o Graph PowerShell com o token recebido do instalador e confere tenant, conta e
    escopos. Devolve a identidade (Conta, TenantId, Escopos).
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string[]]$EscoposNecessarios,
        [string]$TenantEsperado,
        [string]$ContaEsperada
    )
    $id = Assert-BizappContexto -Token $Token -TenantEsperado $TenantEsperado -ContaEsperada $ContaEsperada
    $faltando = @($EscoposNecessarios | Where-Object { $_ -notin $id.Escopos })
    if ($faltando) {
        throw "O login não tem as permissões necessárias: $($faltando -join ', '). Um administrador precisa aceitar essas permissões na tela de login."
    }
    if (Get-MgContext -ErrorAction SilentlyContinue) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
    Connect-MgGraph -AccessToken (ConvertTo-SecureString $Token -AsPlainText -Force) -NoWelcome -ErrorAction Stop
    return $id
}

Export-ModuleMember -Function Import-BizappModulosGraph, Connect-BizappGraph
