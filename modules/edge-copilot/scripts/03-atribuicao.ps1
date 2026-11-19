#Requires -Version 7.4
<#
.SYNOPSIS
    AUTO-26 · Atribuir a um grupo piloto (AtribuirPiloto), remover as atribuicoes sem excluir a
    politica (Desabilitar) ou excluir a politica (Reverter). So vale para a politica criada por
    este item. Exige digitar CONFIRMO.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'EdgeCopilot.psm1') -Force
$entrada = Read-BizappEntrada
Assert-BizappEntrada -Entrada $entrada -Campos 'TenantId', 'Conta', 'NomePolitica', 'AcaoAtribuicao'

$confirmou = ([string]$entrada.ConfirmacaoAtribuicao).Trim() -ceq 'CONFIRMO'
Set-BizappSaida -Nome 'ConfirmacaoAtribuicao' -Valor ''
if (-not $confirmou) { throw 'Esta ação afeta dispositivos ou apaga a política: digite CONFIRMO no campo de confirmação. Nada foi alterado.' }
$acao = [string]$entrada.AcaoAtribuicao
$grupo = ([string]$entrada.GrupoPiloto).Trim()
if ($acao -eq 'atribuir' -and $grupo -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Informe o Object ID do grupo piloto. Nada foi alterado.' }

$id = Connect-EdgeCopilot -Entrada $entrada
$pasta = New-BizappEvidencias -Item $ITEM -Acao $(switch ($acao) { 'atribuir' { 'AtribuirPiloto' } 'remover' { 'Desabilitar' } 'excluir' { 'Reverter' } default { throw "Ação inválida: $acao" } })
$nome = ([string]$entrada.NomePolitica).Trim()
$politica = Find-Politica -Nome $nome
if (-not $politica) { throw "A política '$nome' não existe. Nada foi alterado." }
if (-not (Test-PoliticaDoItem $politica)) { throw "A política '$nome' não foi criada por este item. Ela não será alterada." }

$antes = Get-Atribuicoes $politica.id
Export-BizappEvidencia -Pasta $pasta -Nome 'atribuicoes-antes.csv' -Dados @($antes | ForEach-Object { [pscustomobject]@{ Grupo = $_.target.groupId; Tipo = $_.target.'@odata.type' } })
$alterou = $true
switch ($acao) {
    'atribuir' {
        $g = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/groups/$grupo`?`$select=id,displayName,securityEnabled"
        $grupos = @(@($antes | ForEach-Object { $_.target.groupId }) + $grupo | Where-Object { $_ } | Select-Object -Unique)
        Write-BizappLog "Atribuindo ao grupo '$($g.displayName)'..."
        Set-Atribuicoes -PolicyId $politica.id -Grupos $grupos
        $depois = Get-Atribuicoes $politica.id
        $aprovada = [bool]($depois | Where-Object { $_.target.groupId -eq $grupo })
        $detalhe = "Política atribuída ao grupo '$($g.displayName)'."
        if ($aprovada) {
            Write-BizappLog "$detalhe Conferido no Intune." -Nivel sucesso
            Write-BizappLog 'Nos dispositivos do grupo: sincronize no Intune e no Windows, abra edge://policy, clique em Recarregar políticas e confira HomepageLocation e NewTabPageLocation.' -Nivel discreto
        }
    }
    'remover' {
        if (-not $antes.Count) { $alterou = $false; Write-BizappLog 'A política não tinha atribuições; nada foi alterado.' -Nivel sucesso }
        else { Write-BizappLog "Removendo $($antes.Count) atribuição(ões)..."; Set-Atribuicoes -PolicyId $politica.id -Grupos @() }
        $depois = Get-Atribuicoes $politica.id
        $aprovada = $depois.Count -eq 0
        $detalhe = 'Atribuições removidas; a política foi mantida, sem efeito nos dispositivos.'
        if ($aprovada -and $alterou) { Write-BizappLog "$detalhe Conferido no Intune." -Nivel sucesso }
    }
    'excluir' {
        Write-BizappLog "Excluindo a política '$nome'..."
        $null = Invoke-Graph -Metodo DELETE -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($politica.id)"
        Start-Sleep -Seconds 3
        $resta = Find-Politica -Nome $nome
        $aprovada = -not $resta
        $depois = @()
        $detalhe = "Política '$nome' excluída."
        if ($aprovada) {
            Write-BizappLog "$detalhe Conferido no Intune." -Nivel sucesso
            $politica = $null
            Remove-Item -LiteralPath (Join-Path (Get-BizappPastaEvidencias -Item $ITEM) 'referencia-politica.json') -ErrorAction SilentlyContinue
        }
    }
}
Export-BizappEvidencia -Pasta $pasta -Nome 'atribuicoes-depois.csv' -Dados @($depois | ForEach-Object { [pscustomobject]@{ Grupo = $_.target.groupId; Tipo = $_.target.'@odata.type' } })
Set-BizappSaida -Nome 'EstadoPolitica' -Valor (Get-TextoPolitica $politica $depois.Count)
Write-ResumoEdge -Pasta $pasta -Acao $acao -Identidade $id -Aprovada $aprovada -Alterou $alterou `
    -Detalhe $(if ($aprovada) { $detalhe } else { 'A conferência no Intune não confirmou a alteração. Confira a política no Intune admin center.' }) `
    -Extras ([ordered]@{ Politica = $nome; Grupo = $grupo; AtribuicoesAntes = $antes.Count; AtribuicoesDepois = $depois.Count })
