import { useState } from 'react'
import type { CampoDef } from '@shared/tipos'
import { validarCampo } from '../validacao'

interface Props {
  campo: CampoDef
  valor: string
  desabilitado?: boolean
  onChange: (valor: string) => void
}

export function Campo({ campo, valor, desabilitado, onChange }: Props) {
  // So mostra o erro depois que a pessoa sai do campo ou se ele ja veio preenchido
  const [tocado, setTocado] = useState(false)
  const erro = validarCampo(campo, valor)
  const mostrarErro = !!erro && (tocado || valor.trim() !== '')
  const id = `campo-${campo.id}`

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
        onChange={(e) => onChange(e.target.value)}
        onBlur={() => setTocado(true)}
        aria-invalid={mostrarErro}
        aria-describedby={`${id}-info`}
      />
      <div id={`${id}-info`}>
        {mostrarErro ? <div className="campo__erro">{erro}</div> : campo.ajuda && <div className="campo__ajuda">{campo.ajuda}</div>}
      </div>
    </div>
  )
}
