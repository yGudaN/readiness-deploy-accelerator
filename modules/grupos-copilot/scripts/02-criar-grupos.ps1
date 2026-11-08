#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-22 · CriarGrupos: cria Copilot-Premium e/ou Copilot-Geral como grupos de seguranca
    (sem e-mail), com a conta administrativa como owner. Idempotente: grupo existente e unico
    e "ignorado"; nome duplicado bloqueia. Nao atribui licenca e nao exclui grupos.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GruposCopilot.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'GrupoAlvo'
$inicio = Get-Date

$ctx = Connect-GruposCopilot -Entrada $entrada -EscoposExtras @('Group.ReadWrite.All')
$id = $ctx.Identidade
$pasta = New-BizappEvidencias -Item $ITEM -Acao 'CriarGrupos'
$licencas = Get-InventarioLicencas
$defs = Get-DefinicoesGrupos -GrupoAlvo $entrada.GrupoAlvo

$antes = @(Get-GroupSnapshot -GroupDefinitions $defs -SubscribedSkus $licencas.Skus)
Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-antes.csv' -Dados $antes
$duplicados = @($antes | Where-Object QuantidadeCorrespondencias -gt 1)
if ($duplicados) {
    throw "Existe mais de um grupo com o nome $(($duplicados.NomeConsultado | Sort-Object -Unique) -join ', '). Revise no Entra ID antes de continuar: nada foi alterado."
}

$acoes = [System.Collections.Generic.List[object]]::new()
$alterou = $false
foreach ($d in $defs) {
    $existente = @(Get-ExactGroups -DisplayName $d.DisplayName)
    if ($existente.Count -eq 1) {
        Write-BizappLog "$($d.DisplayName): já existia; criação ignorada." -Nivel discreto
        $acoes.Add([pscustomobject]@{ DataHora = (Get-Date).ToString('o'); Acao = 'CriarGrupos'; Grupo = $d.DisplayName; ObjetoId = $existente[0].Id; Resultado = 'Grupo já existia; criação ignorada' })
        continue
    }
    $apelido = ConvertTo-ODataStringLiteral -Value $d.MailNickname
    if (@(Get-MgGroup -Filter "mailNickname eq '$apelido'" -Property @('Id', 'DisplayName', 'MailNickname') -All -ErrorAction Stop).Count) {
        throw "O apelido (mailNickname) $($d.MailNickname) já está em uso por outro grupo."
    }

    Write-BizappLog "Criando $($d.DisplayName)..."
    $novo = New-MgGroup -DisplayName $d.DisplayName -Description $d.Description -MailEnabled:$false -MailNickname $d.MailNickname `
        -SecurityEnabled:$true -GroupTypes @() -ErrorAction Stop
    $alterou = $true
    Wait-ForGroupReplication -GroupId $novo.Id

    $referencia = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($ctx.Admin.Id)" }
    for ($tentativa = 1; $tentativa -le 8; $tentativa++) {
        try { New-MgGroupOwnerByRef -GroupId $novo.Id -BodyParameter $referencia -ErrorAction Stop; break }
        catch { if ($tentativa -eq 8) { throw "O grupo $($d.DisplayName) foi criado, mas a conta administrativa não pôde ser adicionada como owner: $($_.Exception.Message)" }; Start-Sleep -Seconds 5 }
    }
    Write-BizappLog "$($d.DisplayName) criado (owner: $($id.Conta))." -Nivel sucesso
    $acoes.Add([pscustomobject]@{ DataHora = (Get-Date).ToString('o'); Acao = 'CriarGrupos'; Grupo = $d.DisplayName; ObjetoId = $novo.Id; Resultado = 'Grupo criado e conta administrativa adicionada como owner' })
}
Export-BizappEvidencia -Pasta $pasta -Nome 'acoes.csv' -Dados $acoes

# Quality gate: reconsulta e compara com o estado pedido
$depois = @(Get-GroupSnapshot -GroupDefinitions $defs -SubscribedSkus $licencas.Skus)
$membros = @(Get-MemberSnapshot -GroupDefinitions $defs)
Export-BizappEvidencia -Pasta $pasta -Nome 'configuracao-depois.csv' -Dados $depois
Export-BizappEvidencia -Pasta $pasta -Nome 'membros-depois.csv' -Dados $membros
$notas = foreach ($d in $defs) {
    $l = @($depois | Where-Object NomeConsultado -eq $d.DisplayName)
    if ($l.Count -ne 1 -or $l[0].QuantidadeCorrespondencias -ne 1) { "O grupo $($d.DisplayName) não ficou único."; continue }
    if ($l[0].SecurityEnabled -ne $true -or $l[0].MailEnabled -ne $false -or $l[0].MailNickname -ne $d.MailNickname -or $l[0].QuantidadeOwners -lt 1) {
        "As propriedades de $($d.DisplayName) não correspondem ao esperado."
    }
}
Write-ResumoGrupos -Snapshot $depois -Membros $membros
if (-not $alterou) { Write-BizappLog 'Os grupos já existiam: nada foi alterado.' -Nivel sucesso }
Write-ResumoExecucao -Pasta $pasta -Acao 'CriarGrupos' -Identidade $id -Alterou $alterou -Aprovada (-not $notas) -Notas @($notas) -Inicio $inicio -Extra $entrada.GrupoAlvo
