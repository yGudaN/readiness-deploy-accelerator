# Funcoes de apoio para os scripts dos modulos do Readiness Deploy Accelerator.
#
# Protocolo com o app:
# - A entrada (valores dos campos e, em .Tokens, os tokens de acesso dos logins declarados
#   no manifesto) chega em JSON pelo stdin. Leia com Read-BizappEntrada.
# - Cada linha de stdout que comeca com "::bizapp::" carrega um evento JSON. Qualquer outra
#   linha (Write-Output / Write-Host) aparece como log comum e o que vai para stderr aparece
#   como erro. O codigo de saida 0 indica sucesso.

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if ($PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

function Send-BizappEvento {
    param([hashtable]$Evento)
    [Console]::Out.WriteLine('::bizapp::' + ($Evento | ConvertTo-Json -Compress -Depth 5))
    [Console]::Out.Flush()
}

function Read-BizappEntrada {
    <# Le o JSON de entrada que o app envia pelo stdin. So pode ser chamada uma vez. #>
    $texto = [Console]::In.ReadToEnd()
    if (-not $texto.Trim()) { return @{ Tokens = @{} } }
    $entrada = $texto | ConvertFrom-Json -AsHashtable
    if (-not $entrada.Tokens) { $entrada.Tokens = @{} }
    return $entrada
}

function Write-BizappLog {
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Mensagem,
        [ValidateSet('info', 'sucesso', 'aviso', 'erro', 'discreto')][string]$Nivel = 'info'
    )
    Send-BizappEvento @{ tipo = 'log'; nivel = $Nivel; mensagem = $Mensagem }
}

function Set-BizappSaida {
    <# Devolve um valor ao app (ex.: ClientId). Campos do modulo com o mesmo id sao preenchidos. #>
    param([Parameter(Mandatory)][string]$Nome, [AllowEmptyString()][string]$Valor)
    Send-BizappEvento @{ tipo = 'saida'; nome = $Nome; valor = $Valor }
}

function Write-BizappProgresso {
    <# Atualiza a barra de progresso da etapa (0 a 100) e o texto da fase atual. #>
    param([Parameter(Mandatory)][double]$Percentual, [Parameter(Mandatory)][string]$Fase)
    Send-BizappEvento @{ tipo = 'progresso'; percentual = [math]::Round($Percentual, 2); fase = $Fase }
}

function Assert-BizappEntrada {
    <# Falha cedo se algum campo obrigatorio nao veio preenchido. #>
    param([Parameter(Mandatory)][hashtable]$Entrada, [Parameter(Mandatory)][string[]]$Campos)
    $faltando = $Campos | Where-Object { -not $Entrada[$_] }
    if ($faltando) { throw "Campos obrigatorios nao informados: $($faltando -join ', ')" }
}

function Get-BizappToken {
    <# Token de acesso obtido pelo app para o login declarado no manifesto (script.tokens[].nome). #>
    param([Parameter(Mandatory)][hashtable]$Entrada, [Parameter(Mandatory)][string]$Nome)
    $token = $Entrada.Tokens[$Nome]
    if (-not $token) { throw "Token '$Nome' nao recebido. Declare-o em script.tokens no module.json." }
    return $token
}

function Get-BizappIdentidade {
    <#
    Conta (upn), tenant (tid) e escopos (scp) gravados no proprio token de acesso.
    Usado para validar o contexto antes de qualquer acao (guia de automacoes: "Validar contexto").
    #>
    param([Parameter(Mandatory)][string]$Token)
    $parte = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $parte += '=' * ((4 - $parte.Length % 4) % 4)
    $dados = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parte)) | ConvertFrom-Json
    return [pscustomobject]@{
        Conta    = $(if ($dados.upn) { $dados.upn } elseif ($dados.preferred_username) { $dados.preferred_username } else { $dados.unique_name })
        TenantId = $dados.tid
        Escopos  = @("$($dados.scp)".Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    }
}

function Assert-BizappContexto {
    <#
    Confere se o login atual e do mesmo tenant e da mesma conta confirmados na primeira etapa
    do item. Divergencia = aborta antes de qualquer alteracao.
    #>
    param([Parameter(Mandatory)][string]$Token, [string]$TenantEsperado, [string]$ContaEsperada)
    $id = Get-BizappIdentidade -Token $Token
    if ($TenantEsperado -and $id.TenantId -ne $TenantEsperado) {
        throw "Tenant diferente do confirmado na primeira etapa (esperado $TenantEsperado, conectado $($id.TenantId)). Nada foi alterado."
    }
    if ($ContaEsperada -and -not [string]::Equals($id.Conta, $ContaEsperada, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Conta diferente da confirmada na primeira etapa (esperada $ContaEsperada, conectada $($id.Conta)). Nada foi alterado."
    }
    return $id
}

function Get-BizappPastaEvidencias {
    <# Pasta raiz das evidencias de um item: Documentos\Readiness Deploy Accelerator\evidencias\<Item>. #>
    param([Parameter(Mandatory)][string]$Item)
    return Join-Path ([Environment]::GetFolderPath('MyDocuments')) "Readiness Deploy Accelerator\evidencias\$Item"
}

function New-BizappEvidencias {
    <#
    Cria a pasta de evidencias desta execucao (<raiz do item>\<data-hora>-<acao>) e avisa o app
    (saida PastaEvidencias, usada no botao "Abrir evidencias" do resumo).
    #>
    param([Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][string]$Acao)
    $raiz = Get-BizappPastaEvidencias -Item $Item
    $pasta = Join-Path $raiz "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$Acao"
    New-Item -ItemType Directory -Force -Path $pasta | Out-Null
    Set-BizappSaida -Nome 'PastaEvidencias' -Valor $raiz
    Write-BizappLog "Evidências desta execução: $pasta" -Nivel discreto
    return $pasta
}

function Export-BizappEvidencia {
    <# Grava um CSV na pasta de evidencias (mesmo formato dos scripts validados no laboratorio). #>
    param([Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)][AllowEmptyCollection()][object]$Dados)
    @($Dados) | Export-Csv -LiteralPath (Join-Path $Pasta $Nome) -Encoding utf8
}

Export-ModuleMember -Function Read-BizappEntrada, Write-BizappLog, Write-BizappProgresso, Set-BizappSaida, Assert-BizappEntrada, Get-BizappToken, `
    Get-BizappIdentidade, Assert-BizappContexto, Get-BizappPastaEvidencias, New-BizappEvidencias, Export-BizappEvidencia
