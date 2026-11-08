import type { CampoDef, EtapaDef } from '@shared/tipos'

const GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

/** Mensagem de erro do campo, ou null se valido. */
export function validarCampo(campo: CampoDef, valor: string): string | null {
  const v = valor.trim()
  if (!v) return campo.obrigatorio ? (campo.tipo === 'escolha' ? 'Escolha uma opção.' : 'Campo obrigatório.') : null
  if (campo.tipo === 'escolha') return campo.opcoes?.some((o) => o.valor === v) ? null : 'Escolha uma opção.'
  if (campo.tipo === 'guid' && !GUID.test(v)) return `Formato esperado: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (${v.length} de 36 caracteres).`
  if (campo.tipo === 'url' && !/^https:\/\/\S+$/i.test(v)) return 'Informe uma URL começando com https://'
  if (campo.padraoRegex && !new RegExp(campo.padraoRegex).test(v)) return campo.mensagemRegex ?? 'Formato inválido.'
  return null
}

/** Assinatura das entradas do script: se mudar depois de uma execucao bem-sucedida, a etapa precisa rodar de novo. */
export function assinaturaEntradas(etapa: EtapaDef, valores: Record<string, string>): string {
  const chaves = etapa.script?.entradas ?? Object.keys(valores).sort()
  return JSON.stringify(chaves.map((c) => (valores[c] ?? '').trim()))
}

/** Valores com espacos removidos, como sao enviados aos scripts. */
export function valoresLimpos(valores: Record<string, string>): Record<string, string> {
  return Object.fromEntries(Object.entries(valores).map(([k, v]) => [k, v.trim()]))
}
