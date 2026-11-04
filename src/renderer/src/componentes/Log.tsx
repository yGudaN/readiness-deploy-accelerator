import { useEffect, useRef } from 'react'
import type { NivelLog } from '@shared/tipos'

export interface LinhaLog {
  nivel: NivelLog
  mensagem: string
}

export function Log({ linhas, vazio = 'A saída da execução aparece aqui.' }: { linhas: LinhaLog[]; vazio?: string }) {
  const ref = useRef<HTMLDivElement>(null)

  // Acompanha o fim do log enquanto chegam linhas novas
  useEffect(() => {
    const el = ref.current
    if (el) el.scrollTop = el.scrollHeight
  }, [linhas.length])

  return (
    <div className="log" ref={ref} role="log" aria-live="polite">
      {linhas.length === 0 && <div className="log__vazio">{vazio}</div>}
      {linhas.map((l, i) => (
        <div key={i} className={`log__linha--${l.nivel}`}>
          {l.mensagem || ' '}
        </div>
      ))}
    </div>
  )
}
