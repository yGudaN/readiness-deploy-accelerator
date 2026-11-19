import { useState } from 'react'
import type { CampoDef } from '@shared/tipos'
import { validarCampo } from '../validacao'

interface Props {
  campo: CampoDef
  valor: string
  desabilitado?: boolean
  /** Itens sugeridos enquanto a pessoa digita (campo.sugestoesDe). */
  sugestoes?: string[]
  onChange: (valor: string) => void
}

export function Campo({ campo, valor, desabilitado, sugestoes, onChange }: Props) {
  // So mostra o erro depois que a pessoa sai do campo ou se ele ja veio preenchido
  const [tocado, setTocado] = useState(false)
  const erro = validarCampo(campo, valor)
  const mostrarErro = !!erro && (tocado || valor.trim() !== '')
  const id = `campo-${campo.id}`

  if (campo.tipo === 'escolha') {
    return (
      <fieldset className="campo campo--escolha" disabled={desabilitado} aria-describedby={`${id}-info`}>
        <legend>{campo.rotulo}</legend>
        <div className="opcoes">
          {campo.opcoes?.map((o) => (
            <label key={o.valor} className={`opcao${valor === o.valor ? ' opcao--marcada' : ''}`}>
              <input type="radio" name={id} value={o.valor} checked={valor === o.valor} onChange={() => onChange(o.valor)} />
              <span className="opcao__marca" aria-hidden="true" />
              <span>
                <span className="opcao__rotulo">{o.rotulo}</span>
                {o.descricao && <span className="opcao__descricao">{o.descricao}</span>}
              </span>
            </label>
          ))}
        </div>
        <div id={`${id}-info`}>{campo.ajuda && <div className="campo__ajuda">{campo.ajuda}</div>}</div>
      </fieldset>
    )
  }

  return (
    <div className={`campo${mostrarErro ? ' campo--invalido' : ''}`}>
      <label htmlFor={id}>{campo.rotulo}</label>
      <input
        id={id}
        type="text"
        value={valor}
        placeholder={campo.placeholder}
        disabled={desabilitado}
        spellCheck={false}
        list={sugestoes?.length ? `${id}-sugestoes` : undefined}
        autoComplete="off"
        onChange={(e) => onChange(e.target.value)}
        onBlur={() => setTocado(true)}
        aria-invalid={mostrarErro}
        aria-describedby={`${id}-info`}
      />
      {sugestoes?.length ? (
        <datalist id={`${id}-sugestoes`}>
          {sugestoes.map((s) => (
            <option key={s} value={s} />
          ))}
        </datalist>
      ) : null}
      <div id={`${id}-info`}>
        {mostrarErro ? <div className="campo__erro">{erro}</div> : campo.ajuda && <div className="campo__ajuda">{campo.ajuda}</div>}
      </div>
    </div>
  )
}
