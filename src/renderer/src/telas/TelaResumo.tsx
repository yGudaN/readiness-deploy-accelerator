import { useState } from 'react'
import { aplicarModelo } from '@shared/modelo'
import type { ModuloManifesto } from '@shared/tipos'
import { api } from '../api'
import { useNavegador } from '../navegador'

interface Props {
  modulos: ModuloManifesto[]
  valores: Record<string, Record<string, string>>
}

function itensDoModulo(m: ModuloManifesto, valores: Record<string, string>) {
  const itens = (m.resumoFinal?.itens ?? [])
    .map((i) => ({ rotulo: i.rotulo, valor: aplicarModelo(i.valor, valores) }))
    .filter((i) => i.valor.trim())
  const links = (m.resumoFinal?.links ?? [])
    .map((l) => ({ rotulo: l.rotulo, url: aplicarModelo(l.url, valores) }))
    .filter((l) => /^https:\/\/\S+$/i.test(l.url))
  return { itens, links }
}

export function TelaResumo({ modulos, valores }: Props) {
  const [copiado, setCopiado] = useState(false)
  const { atual: navegador } = useNavegador()

  const copiar = async (): Promise<void> => {
    const texto = modulos
      .map((m) => {
        const { itens, links } = itensDoModulo(m, valores[m.id] ?? {})
        return [m.nome, ...itens.map((i) => `  ${i.rotulo}: ${i.valor}`), ...links.map((l) => `  ${l.rotulo}: ${l.url}`)].join('\n')
      })
      .join('\n\n')
    await navigator.clipboard.writeText(texto)
    setCopiado(true)
  }

  return (
    <>
      <div className="sobretitulo">Instalação concluída</div>
      <h1 className="titulo-tela">Tudo pronto.</h1>
      <p className="descricao-tela">Confira o que foi configurado. Guarde este resumo: ele traz dados que você vai precisar em manutenções futuras.</p>

      {modulos.map((m) => {
        const { itens, links } = itensDoModulo(m, valores[m.id] ?? {})
        return (
          <section key={m.id} className="cartao resumo-modulo">
            <h3>{m.nome}</h3>
            <dl className="resumo-tabela">
              {itens.map((i) => (
                <div key={i.rotulo} style={{ display: 'contents' }}>
                  <dt>{i.rotulo}</dt>
                  <dd>{i.valor}</dd>
                </div>
              ))}
            </dl>
            {links.length > 0 && (
              <div className="linha-botoes" style={{ marginBottom: 0 }}>
                {links.map((l) => (
                  <button key={l.url} className="botao botao--secundario botao--pequeno" onClick={() => void api.abrirLink(l.url, navegador)}>
                    {l.rotulo}
                  </button>
                ))}
              </div>
            )}
          </section>
        )
      })}

      <div className="linha-botoes">
        <button className="botao botao--texto" onClick={() => void copiar()}>
          {copiado ? '✓ Resumo copiado' : 'Copiar resumo'}
        </button>
      </div>
    </>
  )
}
