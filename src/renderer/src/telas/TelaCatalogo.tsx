import { useState } from 'react'
import type { ModuloManifesto } from '@shared/tipos'

interface Props {
  modulos: ModuloManifesto[]
  selecionados: string[]
  /** Itens ja instalados nesta sessao. */
  instalados: string[]
  /** Pre-requisitos pendentes por id de modulo. */
  pendencias: Record<string, string[]>
  onAlternar: (id: string) => void
}

/**
 * Catalogo em lista: cada linha mostra so o nome (o catalogo deve passar de 30 itens).
 * Clicar na linha expande os detalhes; a caixa de selecao, a esquerda, escolhe o item.
 */
export function TelaCatalogo({ modulos, selecionados, instalados, pendencias, onAlternar }: Props) {
  const [expandidos, setExpandidos] = useState<string[]>([])
  const alternarExpandido = (id: string): void =>
    setExpandidos((e) => (e.includes(id) ? e.filter((x) => x !== id) : [...e, id]))

  return (
    <>
      <div className="sobretitulo">Boas-vindas ao Readiness Deploy Accelerator</div>
      <h1 className="titulo-tela">O que vamos instalar?</h1>
      <p className="descricao-tela">
        Marque os itens que deseja configurar no seu tenant. Clique no nome para ver o que cada um instala.
      </p>

      <ul className="catalogo-lista">
        {modulos.map((m) => {
          const selecionado = selecionados.includes(m.id)
          const expandido = expandidos.includes(m.id)
          const pendente = pendencias[m.id] ?? []
          const idDetalhes = `detalhes-${m.id}`
          return (
            <li key={m.id} className={`item-lista${selecionado ? ' item-lista--selecionado' : ''}${expandido ? ' item-lista--expandido' : ''}`}>
              <div className="item-lista__linha">
                <label className="item-lista__selecao">
                  <input type="checkbox" checked={selecionado} onChange={() => onAlternar(m.id)} aria-label={`Instalar ${m.nome}`} />
                  <span className="item-lista__check" aria-hidden="true">{selecionado ? '✓' : ''}</span>
                </label>
                <button
                  className="item-lista__cabecalho"
                  aria-expanded={expandido}
                  aria-controls={idDetalhes}
                  onClick={() => alternarExpandido(m.id)}
                >
                  <span className="item-lista__nome">{m.nome}</span>
                  {instalados.includes(m.id) && <span className="etiqueta etiqueta--alerta">✓ Instalado</span>}
                  {pendente.length > 0 && <span className="etiqueta etiqueta--alerta">Pré-requisito pendente</span>}
                  <span className="item-lista__seta" aria-hidden="true" />
                </button>
              </div>
              {expandido && (
                <div id={idDetalhes} className="item-lista__detalhes">
                  <p className="item-lista__resumo">{m.resumo}</p>
                  <p>{m.descricao}</p>
                  {m.oQueInstala && m.oQueInstala.length > 0 && (
                    <>
                      <div className="item-lista__subtitulo">O que será instalado</div>
                      <ul className="item-lista__instala">
                        {m.oQueInstala.map((o) => (
                          <li key={o}>{o}</li>
                        ))}
                      </ul>
                    </>
                  )}
                  <div className="etiquetas">
                    {m.tempoEstimadoMin && <span className="etiqueta">~{m.tempoEstimadoMin} min</span>}
                    <span className="etiqueta">{m.etapas.length} etapas</span>
                    {m.papeisNecessarios?.map((p) => (
                      <span key={p} className="etiqueta">{p}</span>
                    ))}
                    {pendente.length > 0 && <span className="etiqueta etiqueta--alerta">Falta: {pendente.join(', ')}</span>}
                  </div>
                </div>
              )}
            </li>
          )
        })}
      </ul>
      <p className="catalogo-rodape">Outras soluções do COE Bizapp vão aparecer aqui.</p>
    </>
  )
}
