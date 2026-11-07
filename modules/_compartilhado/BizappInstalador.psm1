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

Export-ModuleMember -Function Read-BizappEntrada, Write-BizappLog, Write-BizappProgresso, Set-BizappSaida, Assert-BizappEntrada, Get-BizappToken
