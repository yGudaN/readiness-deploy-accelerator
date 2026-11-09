import { aplicarModelo } from '@shared/modelo'
import type { SituacaoDef } from '@shared/tipos'

type Tom = 'ok' | 'alerta' | 'neutro'

const comeca = (valor: string, lista?: string[]): boolean =>
  !!lista?.some((p) => valor.toLowerCase().startsWith(p.toLowerCase()))

/**
 * Quadro "situação atual": uma linha por informação (rótulo à esquerda, valor à direita),
 * com marcador de ok/alerta. Linhas cujo valor fica vazio não aparecem; sem linhas, não aparece.
 */
export function Situacao({ def, valores }: { def: SituacaoDef; valores: Record<string, string> }) {
  const linhas = def.itens
    .map((i) => {
      const valor = aplicarModelo(i.valor, valores).trim()
      const tom: Tom = comeca(valor, i.alertaQuando) ? 'alerta' : comeca(valor, i.okQuando) ? 'ok' : 'neutro'
      return { rotulo: i.rotulo, valor, tom }
    })
    .filter((l) => l.valor)
  if (!linhas.length) return null
  const nota = def.nota ? aplicarModelo(def.nota, valores).trim() : ''

  return (
    <section className="cartao situacao" aria-label={def.titulo ?? 'Situação atual'}>
      <div className="situacao__titulo">{def.titulo ?? 'Situação atual'}</div>
      <dl className="situacao__lista">
        {linhas.map((l) => (
          <div key={l.rotulo} className={`situacao__linha situacao__linha--${l.tom}`}>
            <dt>{l.rotulo}</dt>
            <dd>
              {l.tom !== 'neutro' && (
                <span className="situacao__marca" aria-label={l.tom === 'ok' ? 'OK' : 'Atenção'}>
                  {l.tom === 'ok' ? '✓' : '!'}
                </span>
              )}
              {l.valor}
            </dd>
          </div>
        ))}
      </dl>
      {nota && <p className="situacao__nota">{nota}</p>}
    </section>
  )
}
