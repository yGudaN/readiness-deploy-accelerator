import { useState } from 'react'
import { api } from '../api'
import { useNavegador } from '../navegador'
import type { EstadoExecucao } from '../useExecucoes'

/**
 * Mostra o login em andamento: em qual navegador abriu e como abrir de novo em outro
 * (ou copiar o link para colar em qualquer navegador ou perfil).
 */
export function CartaoLogin({ execucao }: { execucao: EstadoExecucao }) {
  const { lista, nomeDe } = useNavegador()
  const [copiado, setCopiado] = useState(false)
  const [outro, setOutro] = useState('')
  const login = execucao.login

  if (!login) return null

  if (login.estado === 'concluido') {
    return login.conta ? <div className="login__detalhe" style={{ marginTop: 10 }}>Conectado como {login.conta}</div> : null
  }
  if (!execucao.emAndamento || !login.url) return null

  const copiar = async (): Promise<void> => {
    await navigator.clipboard.writeText(login.url!)
    setCopiado(true)
  }
  const reabrir = (navegadorId: string): void => {
    if (execucao.execucaoId) void api.reabrirLogin(execucao.execucaoId, navegadorId)
  }

  return (
    <div className="cartao login" role="status">
      <div className="girando" />
      <div className="login__texto">
        <div className="login__titulo">Faça o login no {nomeDe(login.navegador)}</div>
        <div className="login__detalhe">
          {login.proposito}. Depois volte para cá: o instalador continua sozinho.
        </div>
      </div>
      <button className="botao botao--texto botao--pequeno" onClick={() => void copiar()}>
        {copiado ? '✓ Link copiado' : 'Copiar link'}
      </button>
      <select
        aria-label="Abrir o login em outro navegador"
        value={outro}
        onChange={(e) => {
          setOutro('')
          if (e.target.value) reabrir(e.target.value)
        }}
      >
        <option value="">Abrir em outro navegador…</option>
        {lista.map((n) => (
          <option key={n.id} value={n.id}>
            {n.nome}
          </option>
        ))}
      </select>
    </div>
  )
}
