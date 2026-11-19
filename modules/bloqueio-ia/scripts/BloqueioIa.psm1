# Funcoes do item "Bloqueio de IA não corporativa" (AUTO-27): indicadores de dominio no Microsoft
# Defender for Endpoint (API /api/indicators), montado a partir do relatorio
# (testes-manuais/originais/27-bloqueio-ia-relatorio.docx): o script nao veio. Seguindo o relatorio:
#  - login delegado com um app proprio (permissao Ti.ReadWrite do WindowsDefenderATP);
#  - consulta somente leitura por padrao;
#  - bloquear e remover separados, com confirmacao, justificativa e expiracao obrigatoria;
#  - remover so indicadores criados por este item (marca na descricao).
# NAO testado: na prova do relatorio a consulta parou em 403 (RBAC do Defender); o tenant de demo
# nao tem Defender for Endpoint.

Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1')

$script:ITEM = 'Bloqueio-IA'
$script:MARCA = 'Criado pelo Readiness Deploy Accelerator'
$script:API = 'https://api.security.microsoft.com/api/indicators'
$script:Token = $null

function Connect-BloqueioIa {
    param([Parameter(Mandatory)][hashtable]$Entrada)
    $script:Token = Get-BizappToken -Entrada $Entrada -Nome Defender
    # Quem colou o ID de um app ja existente pulou o registro: vale a conta do login
    if (-not $Entrada.TenantId) { return Get-BizappIdentidade -Token $script:Token }
    return Assert-BizappContexto -Token $script:Token -TenantEsperado $Entrada.TenantId -ContaEsperada $Entrada.Conta
}

function Invoke-Defender {
    param([string]$Metodo = 'GET', [Parameter(Mandatory)][string]$Uri, [object]$Corpo)
    $p = @{ Method = $Metodo; Uri = $Uri; Headers = @{ Authorization = "Bearer $script:Token"; Accept = 'application/json' } }
    if ($null -ne $Corpo) { $p.Body = [System.Text.Encoding]::UTF8.GetBytes(($Corpo | ConvertTo-Json -Depth 6 -Compress)); $p.ContentType = 'application/json; charset=utf-8' }
    try { Invoke-RestMethod @p } catch {
        $codigo = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        $msg = try { $e = $_.ErrorDetails.Message | ConvertFrom-Json; "$($e.error.code) $($e.error.message)".Trim() } catch { [string]$_.ErrorDetails.Message }
        if ($codigo -eq 401) { throw "O acesso ao Defender foi negado (401). Confira se o tenant tem Microsoft Defender for Endpoint e se as permissões do app foram aceitas. $msg" }
        if ($codigo -eq 403) { throw "Sem permissão no Defender (403). A conta precisa de uma função do Defender que gerencie indicadores (RBAC do Microsoft Defender), além da permissão do app. $msg" }
        throw "Defender (HTTP $codigo): $(if ($msg) { $msg } else { $_.Exception.Message })"
    }
}

function Get-Dominios {
    <# Lista de dominios do campo (separados por ; , ou espaco), validada. #>
    param([string]$Texto)
    $lista = @(([string]$Texto) -split '[;,\s]+' | ForEach-Object { $_.Trim().ToLowerInvariant() -replace '^https?://', '' -replace '/.*$', '' } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $lista) { throw 'Informe ao menos um domínio. Nada foi alterado.' }
    foreach ($d in $lista) { if ($d -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$') { throw "Domínio inválido: $d. Nada foi alterado." } }
    return , $lista
}

function Get-Indicadores {
    <# Indicadores do Defender para os dominios (GET /api/indicators com filtro por valor). #>
    param([string[]]$Dominios)
    $itens = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $Dominios) {
        $filtro = [uri]::EscapeDataString("indicatorValue eq '$d'")
        $r = Invoke-Defender -Uri "$script:API`?`$filter=$filtro"
        foreach ($i in @($r.value)) {
            if ($i) {
                $itens.Add([pscustomobject]@{
                        Dominio = $d; Id = $i.id; Tipo = $i.indicatorType; Acao = $i.action; Titulo = $i.title; Expira = $i.expirationTime
                        CriadoPor = $i.createdBy; CriadoPorEsteItem = ([string]$i.description).Contains($script:MARCA); Grupos = (@($i.rbacGroupNames) -join ', ')
                    })
            }
        }
    }
    return , $itens.ToArray()
}

function Get-TextoIndicadores([object[]]$Indicadores, [string[]]$Dominios) {
    return (@(foreach ($d in $Dominios) {
                $i = $Indicadores | Where-Object Dominio -eq $d | Select-Object -First 1
                if ($i) { "$d · $($i.Acao)$(if ($i.Expira) { " até $(([datetime]$i.Expira).ToString('dd/MM/yyyy'))" })$(if (-not $i.CriadoPorEsteItem) { ' (de outra origem)' })" } else { "$d · sem indicador" }
            }) -join '; ')
}

function Set-Indicador {
    <# POST /api/indicators (cria ou atualiza pelo valor). #>
    param([string]$Dominio, [string]$Acao, [datetime]$Expira, [string]$Justificativa, [string[]]$Grupos)
    $corpo = [ordered]@{
        indicatorValue = $Dominio; indicatorType = 'DomainName'; action = $Acao
        title = "Bloqueio de IA não corporativa: $Dominio"
        description = "$Justificativa · $script:MARCA"
        expirationTime = $Expira.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        severity = 'Informational'; generateAlert = $false
        application = 'IA não corporativa'
    }
    if ($Grupos) { $corpo.rbacGroupNames = $Grupos }
    return Invoke-Defender -Metodo POST -Uri $script:API -Corpo $corpo
}

function Remove-Indicador([string]$Id) { $null = Invoke-Defender -Metodo DELETE -Uri "$script:API/$Id" }

function Write-ResumoBloqueio {
    param([string]$Pasta, [string]$Acao, [object]$Identidade, [bool]$Aprovada, [bool]$Alterou, [string]$Detalhe, [System.Collections.IDictionary]$Extras = @{})
    $resumo = [ordered]@{
        DataHoraFimUtc = (Get-Date).ToUniversalTime().ToString('o'); Item = 'AUTO-27'; Controle = 'Bloqueio de IA não corporativa'
        AcaoSolicitada = $Acao; TenantId = $Identidade.TenantId; Conta = $Identidade.Conta
    }
    foreach ($k in $Extras.Keys) { $resumo[$k] = $Extras[$k] }
    $resumo.AlteracoesExecutadas = $Alterou
    $resumo.ValidacaoAprovada = $Aprovada
    $resumo.Resultado = $(if ($Aprovada) { 'Validado' } else { 'Falha' })
    $resumo.Detalhe = $Detalhe
    Export-BizappEvidencia -Pasta $Pasta -Nome 'resumo.csv' -Dados ([pscustomobject]$resumo)
    if (-not $Aprovada) { throw $Detalhe }
}

Export-ModuleMember -Variable ITEM, MARCA -Function Connect-BloqueioIa, Get-Dominios, Get-Indicadores, Get-TextoIndicadores, Set-Indicador, Remove-Indicador, Write-ResumoBloqueio
