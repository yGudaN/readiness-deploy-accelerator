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

export function TelaCatalogo({ modulos, selecionados, instalados, pendencias, onAlternar }: Props) {
  return (
    <>
      <div className="sobretitulo">Boas-vindas ao Readiness Deploy Accelerator</div>
      <h1 className="titulo-tela">O que vamos instalar?</h1>
      <p className="descricao-tela">
        Escolha os itens que deseja configurar no seu tenant. Para cada item, você preenche alguns dados e o instalador faz o resto.
      </p>

      <div className="catalogo">
        {modulos.map((m) => {
          const selecionado = selecionados.includes(m.id)
          const pendente = pendencias[m.id] ?? []
          return (
            <button
              key={m.id}
              className={`cartao item-catalogo${selecionado ? ' item-catalogo--selecionado' : ''}`}
              aria-pressed={selecionado}
              onClick={() => onAlternar(m.id)}
            >
              <span className="item-catalogo__check">{selecionado ? '✓' : ''}</span>
              <h3>{m.nome}</h3>
              <p>{m.resumo}</p>
              <div className="etiquetas">
                {instalados.includes(m.id) && <span className="etiqueta etiqueta--alerta">✓ Instalado nesta sessão</span>}
                {m.tempoEstimadoMin && <span className="etiqueta">~{m.tempoEstimadoMin} min</span>}
                <span className="etiqueta">{m.etapas.length} etapas</span>
                {m.papeisNecessarios?.map((p) => (
                  <span key={p} className="etiqueta">{p}</span>
                ))}
                {pendente.length > 0 && <span className="etiqueta etiqueta--alerta">Falta: {pendente.join(', ')}</span>}
              </div>
            </button>
          )
        })}
        <div className="cartao item-catalogo item-catalogo--embreve">
          <h3>Novos itens em breve</h3>
          <p>Outras soluções do COE Bizapp vão aparecer aqui.</p>
        </div>
      </div>
    </>
  )
}
