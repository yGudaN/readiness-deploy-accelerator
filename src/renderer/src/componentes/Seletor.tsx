import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react'

export interface OpcaoSeletor {
  id: string
  nome: string
}

interface Props {
  opcoes: OpcaoSeletor[]
  /** Opcao marcada. Sem valor, o botao mostra o texto de `vazio`. */
  valor?: string
  vazio?: string
  rotulo: string
  /** "escuro" para a barra lateral, "claro" para o conteudo. */
  tema?: 'escuro' | 'claro'
  /** A lista abre para cima (ex.: no rodape da barra lateral). */
  paraCima?: boolean
  onEscolher: (id: string) => void
}

/**
 * Lista de escolha com o visual do app (o <select> nativo usa a lista do Windows,
 * que nao pode ser estilizada). Segue o padrao "listbox" de acessibilidade:
 * setas navegam, Enter/Espaco escolhem, Esc fecha.
 */
export function Seletor({ opcoes, valor, vazio, rotulo, tema = 'claro', paraCima, onEscolher }: Props) {
  const [aberto, setAberto] = useState(false)
  const [ativo, setAtivo] = useState(0)
  const raiz = useRef<HTMLDivElement>(null)
  const botao = useRef<HTMLButtonElement>(null)
  const idLista = useId()
  const atual = opcoes.find((o) => o.id === valor)

  // Fecha ao clicar fora
  useEffect(() => {
    if (!aberto) return
    const fora = (e: MouseEvent): void => {
      if (!raiz.current?.contains(e.target as Node)) setAberto(false)
    }
    document.addEventListener('mousedown', fora)
    return () => document.removeEventListener('mousedown', fora)
  }, [aberto])

  const abrir = (): void => {
    setAtivo(Math.max(0, opcoes.findIndex((o) => o.id === valor)))
    setAberto(true)
  }

  const escolher = (id: string): void => {
    setAberto(false)
    botao.current?.focus()
    onEscolher(id)
  }

  const teclado = (e: KeyboardEvent): void => {
    if (!aberto) {
      if (['ArrowDown', 'ArrowUp', 'Enter', ' '].includes(e.key)) {
        e.preventDefault()
        abrir()
      }
      return
    }
    if (e.key === 'Escape') {
      e.preventDefault()
      setAberto(false)
    } else if (e.key === 'ArrowDown') {
      e.preventDefault()
      setAtivo((i) => Math.min(opcoes.length - 1, i + 1))
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setAtivo((i) => Math.max(0, i - 1))
    } else if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      if (opcoes[ativo]) escolher(opcoes[ativo].id)
    } else if (e.key === 'Tab') {
      setAberto(false)
    }
  }

  return (
    <div ref={raiz} className={`seletor seletor--${tema}${paraCima ? ' seletor--para-cima' : ''}`}>
      <button
        ref={botao}
        type="button"
        className="seletor__botao"
        aria-label={`${rotulo}: ${atual?.nome ?? vazio ?? ''}`}
        aria-haspopup="listbox"
        aria-expanded={aberto}
        aria-controls={idLista}
        aria-activedescendant={aberto ? `${idLista}-${ativo}` : undefined}
        onClick={() => (aberto ? setAberto(false) : abrir())}
        onKeyDown={teclado}
      >
        <span className="seletor__texto">{atual?.nome ?? vazio}</span>
        <span className="seletor__seta" aria-hidden="true" />
      </button>
      {aberto && (
        <ul id={idLista} role="listbox" aria-label={rotulo} className="seletor__lista">
          {opcoes.map((o, i) => (
            <li
              key={o.id}
              id={`${idLista}-${i}`}
              role="option"
              aria-selected={o.id === valor}
              className={`seletor__opcao${i === ativo ? ' seletor__opcao--ativa' : ''}`}
              onMouseEnter={() => setAtivo(i)}
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => escolher(o.id)}
            >
              <span className="seletor__marca" aria-hidden="true">{o.id === valor ? '✓' : ''}</span>
              {o.nome}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
