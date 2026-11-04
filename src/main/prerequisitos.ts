import { compararVersoes } from '../shared/modelo'
import type { ModuloManifesto, StatusPreRequisito } from '../shared/tipos'
import { executarComando } from './powershell'

const URL_PWSH = 'https://learn.microsoft.com/pt-br/powershell/scripting/install/installing-powershell-on-windows'
const NOME_MODULO_VALIDO = /^[A-Za-z0-9._-]+$/

/** Modulos PowerShell declarados no catalogo: a unica lista que o app aceita instalar. */
export function modulosPsDeclarados(modulos: ModuloManifesto[]): string[] {
  const nomes = modulos.flatMap((m) => m.preRequisitos.flatMap((p) => (p.tipo === 'modulo-ps' ? [p.nome] : [])))
  return [...new Set(nomes)].filter((n) => NOME_MODULO_VALIDO.test(n))
}

function maiorVersao(versoes: string[]): string | undefined {
  return [...versoes].sort(compararVersoes).at(-1)
}

export async function verificarPreRequisitos(modulos: ModuloManifesto[]): Promise<StatusPreRequisito[]> {
  const nomesPs = modulosPsDeclarados(modulos)
  const script = [
    '$r = @{ pwsh = $PSVersionTable.PSVersion.ToString(); modulos = @{} }',
    `foreach ($n in @(${nomesPs.map((n) => `'${n}'`).join(',')})) {`,
    '  $m = Get-Module -ListAvailable -Name $n | Sort-Object Version -Descending | Select-Object -First 1',
    '  $r.modulos[$n] = if ($m) { $m.Version.ToString() } else { $null }',
    '}',
    '$r | ConvertTo-Json -Compress'
  ].join('\n')

  let pwsh: string | undefined
  let versoesModulos: Record<string, string | null> = {}
  let falhaPwsh: string | undefined
  try {
    const saida = JSON.parse((await executarComando(script)).trim())
    pwsh = saida.pwsh
    versoesModulos = saida.modulos ?? {}
  } catch (erro) {
    falhaPwsh = (erro as NodeJS.ErrnoException).code === 'ENOENT'
      ? 'PowerShell 7 (pwsh) não encontrado nesta máquina.'
      : `Falha ao consultar o PowerShell: ${(erro as Error).message}`
  }

  const exigidoPor = (filtro: (m: ModuloManifesto) => boolean): string[] => modulos.filter(filtro).map((m) => m.nome)

  // PowerShell: vale a maior versao minima exigida pelo catalogo
  const minimaPwsh = maiorVersao(modulos.flatMap((m) => m.preRequisitos.flatMap((p) => (p.tipo === 'pwsh' ? [p.versaoMinima] : [])))) ?? '7.0'
  const pwshOk = !!pwsh && compararVersoes(pwsh, minimaPwsh) >= 0
  const resultado: StatusPreRequisito[] = [{
    chave: 'pwsh',
    rotulo: `PowerShell ${minimaPwsh} ou superior`,
    ok: pwshOk,
    versaoEncontrada: pwsh,
    detalhe: falhaPwsh ?? (pwshOk ? undefined : `Versão encontrada (${pwsh}) é anterior a ${minimaPwsh}.`),
    acao: pwshOk ? undefined : { tipo: 'abrir-link', url: URL_PWSH },
    exigidoPor: exigidoPor((m) => m.preRequisitos.some((p) => p.tipo === 'pwsh'))
  }]

  for (const nome of nomesPs) {
    const declaracoes = modulos.flatMap((m) => m.preRequisitos.flatMap((p) => (p.tipo === 'modulo-ps' && p.nome === nome ? [p] : [])))
    const minima = maiorVersao(declaracoes.flatMap((p) => (p.versaoMinima ? [p.versaoMinima] : [])))
    const encontrada = versoesModulos[nome] ?? undefined
    const ok = !!encontrada && (!minima || compararVersoes(encontrada, minima) >= 0)
    const instalavel = declaracoes.some((p) => p.instalavel !== false)
    resultado.push({
      chave: `modulo-ps:${nome}`,
      rotulo: minima ? `Módulo ${nome} ${minima} ou superior` : `Módulo ${nome}`,
      ok,
      versaoEncontrada: encontrada,
      detalhe: ok || !pwshOk ? undefined : encontrada ? `Versão encontrada (${encontrada}) é anterior a ${minima}.` : 'Módulo não instalado.',
      acao: !ok && pwshOk && instalavel ? { tipo: 'instalar-modulo', nome } : undefined,
      exigidoPor: exigidoPor((m) => m.preRequisitos.some((p) => p.tipo === 'modulo-ps' && p.nome === nome))
    })
  }
  return resultado
}
