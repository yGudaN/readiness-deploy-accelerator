import { useState } from 'react'
import { CATEGORIAS, type ModuloManifesto } from '@shared/tipos'

interface Props {
  modulos: ModuloManifesto[]
  selecionados: string[]
  /** Itens ja instalados nesta sessao. */
  instalados: string[]
  /** Pre-requisitos pendentes por id de modulo. */
  pendencias: Record<string, string[]>
  onAlternar: (id: string) => void
  /** Marca todos os itens (true) ou nenhum (false). */
  onSelecionarTodos: (todos: boolean) => void
}

/**
 * Catalogo em lista: cada linha mostra so o nome (o catalogo deve passar de 30 itens).
 * Clicar na linha expande os detalhes; a caixa de selecao, a esquerda, escolhe o item.
 */
export function TelaCatalogo({ modulos, selecionados, instalados, pendencias, onAlternar, onSelecionarTodos }: Props) {
  const [expandidos, setExpandidos] = useState<string[]>([])
  const alternarExpandido = (id: string): void =>
    setExpandidos((e) => (e.includes(id) ? e.filter((x) => x !== id) : [...e, id]))
  const nomeDe = (id: string): string => modulos.find((m) => m.id === id)?.nome ?? id
  const marcados = modulos.filter((m) => selecionados.includes(m.id)).length
  const todos = modulos.length > 0 && marcados === modulos.length
  const alguns = marcados > 0 && !todos
  // Grupos na ordem do checklist do COE; itens sem categoria vao para "Outros", no fim
  const grupos = [
    ...CATEGORIAS.map((c) => ({ titulo: c as string, itens: modulos.filter((m) => m.categoria === c) })),
    { titulo: 'Outros', itens: modulos.filter((m) => !m.categoria || !(CATEGORIAS as readonly string[]).includes(m.categoria)) }
  ].filter((g) => g.itens.length > 0)

  return (
    <>
      <div className="sobretitulo">Boas-vindas ao Readiness Deploy Accelerator</div>
      <h1 className="titulo-tela">O que vamos instalar?</h1>
      <p className="descricao-tela">
        Marque os itens que deseja configurar no seu tenant. Clique no nome para ver o que cada um instala.
      </p>

      <div className="catalogo-barra">
        <label className={`item-lista__selecao catalogo-barra__todos${todos ? ' catalogo-barra__todos--marcado' : ''}`}>
          <input
            type="checkbox"
            checked={todos}
            ref={(el) => { if (el) el.indeterminate = alguns }}
            onChange={() => onSelecionarTodos(!todos)}
          />
          <span className="item-lista__check" aria-hidden="true">{todos ? '✓' : alguns ? '–' : ''}</span>
          <span>Selecionar todos</span>
        </label>
        <span className="catalogo-barra__contagem">
          {marcados} de {modulos.length} selecionado{modulos.length === 1 ? '' : 's'}
        </span>
      </div>

      {/* Duas colunas independentes (pares e impares): abrir um card nao estica o vizinho. Em janela
          estreita as colunas somem (display: contents) e "order" devolve a ordem original. */}
      {grupos.map((grupo) => (
      <section key={grupo.titulo} className="catalogo-grupo" aria-label={grupo.titulo}>
      <h2 className="catalogo-grupo__titulo">{grupo.titulo}</h2>
      <div className="catalogo-lista">
        {[0, 1].map((coluna) => (
        <ul key={coluna} className="catalogo-coluna">
        {grupo.itens.map((m, i) => {
          if (i % 2 !== coluna) return null
          const selecionado = selecionados.includes(m.id)
          const expandido = expandidos.includes(m.id)
          const pendente = pendencias[m.id] ?? []
          const idDetalhes = `detalhes-${m.id}`
          // Dependencias que nao estao marcadas nem foram instaladas nesta sessao
          const faltam = selecionado
            ? (m.dependeDe ?? []).filter((d) => !selecionados.includes(d.id) && !instalados.includes(d.id))
            : []
          return (
            <li key={m.id} style={{ order: i }} className={`item-lista${selecionado ? ' item-lista--selecionado' : ''}${expandido ? ' item-lista--expandido' : ''}`}>
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
                  {instalados.includes(m.id) && <span className="etiqueta etiqueta--alerta">✓ Concluído</span>}
                  {pendente.length > 0 && <span className="etiqueta etiqueta--alerta">Pré-requisito pendente</span>}
                  <span className="item-lista__seta" aria-hidden="true" />
                </button>
              </div>
              {faltam.map((d) => (
                <div key={d.id} className="dependencia" role="note">
                  <div className="dependencia__icone" aria-hidden="true">!</div>
                  <div className="dependencia__texto">
                    <p>
                      Este item precisa d{/^(o|a)s? /.test(d.precisaDe) ? '' : 'e '}{d.precisaDe}, criados pelo item <strong>{nomeDe(d.id)}</strong>.
                      Se já existem no tenant, pode seguir sem ele.
                    </p>
                    {d.dica && <p className="dependencia__dica">{d.dica}</p>}
                    <div className="dependencia__botoes">
                      <button className="botao botao--secundario botao--pequeno" onClick={() => onAlternar(d.id)}>
                        Marcar também
                      </button>
                      <button
                        className="botao botao--texto botao--pequeno"
                        onClick={() => setExpandidos((e) => (e.includes(d.id) ? e : [...e, d.id]))}
                      >
                        Ver o que ele faz
                      </button>
                    </div>
                  </div>
                </div>
              ))}
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
                    {m.dependeDe?.map((d) => (
                      <span key={d.id} className="etiqueta">Depende de: {nomeDe(d.id)}</span>
                    ))}
                    {pendente.length > 0 && <span className="etiqueta etiqueta--alerta">Falta: {pendente.join(', ')}</span>}
                  </div>
                </div>
              )}
            </li>
          )
        })}
        </ul>
        ))}
      </div>
      </section>
      ))}
      <p className="catalogo-rodape">Outras soluções do COE Bizapp vão aparecer aqui.</p>
    </>
  )
}
