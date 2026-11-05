import { useState } from 'react'
import { api } from '../api'
import { useNavegador } from '../navegador'
import { Seletor } from './Seletor'
import type { EstadoExecucao } from '../useExecucoes'

/**
 * Mostra o login em andamento: em qual navegador abriu e como abrir de novo em outro
 * (ou copiar o link para colar em qualquer navegador ou perfil).
 */
export function CartaoLogin({ execucao }: { execucao: EstadoExecucao }) {
  const { lista, nomeDe } = useNavegador()
  const [copiado, setCopiado] = useState(false)
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
      <Seletor rotulo="Abrir o login em outro navegador" vazio="Abrir em outro navegador" opcoes={lista} onEscolher={reabrir} />
    </div>
  )
}
