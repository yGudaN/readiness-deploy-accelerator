import { useEffect, useState } from 'react'
import type { EstadoExecucao } from '../useExecucoes'

function formatarDuracao(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000))
  const min = Math.floor(s / 60)
  return `${min}:${String(s % 60).padStart(2, '0')}`
}

/**
 * Barra de progresso de operacoes longas. Mostra a fase e o tempo decorrido alem da
 * porcentagem, porque o progresso nem sempre e linear (uma importacao pode chegar a 90%
 * em minutos e levar meia hora para terminar).
 */
export function BarraProgresso({ execucao }: { execucao: EstadoExecucao }) {
  const [agora, setAgora] = useState(Date.now())
  const ativa = execucao.emAndamento && !!execucao.progresso

  useEffect(() => {
    if (!ativa) return
    const t = setInterval(() => setAgora(Date.now()), 1000)
    return () => clearInterval(t)
  }, [ativa])

  if (!execucao.progresso) return null
  const { percentual, fase } = execucao.progresso
  const concluida = execucao.resultado === 'sucesso'
  const valor = concluida ? 100 : percentual

  return (
    <div className="cartao progresso">
      <div className="progresso__cabecalho">
        <span className="progresso__fase">{concluida ? 'Concluído' : fase}</span>
        <span className="progresso__numeros">
          {valor.toFixed(valor < 100 && valor % 1 !== 0 ? 1 : 0)}%
          {execucao.inicio && ativa && ` · ${formatarDuracao(agora - execucao.inicio)}`}
        </span>
      </div>
      <div
        className="progresso__trilho"
        role="progressbar"
        aria-label={fase}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={Math.round(valor)}
      >
        <div className={`progresso__barra${ativa ? ' progresso__barra--ativa' : ''}`} style={{ width: `${valor}%` }} />
      </div>
    </div>
  )
}
