import { useCallback, useEffect, useRef, useState } from 'react'
import type { EventoExecucao } from '@shared/tipos'
import { api } from './api'
import type { LinhaLog } from './componentes/Log'

export interface EstadoLogin {
  estado: 'aguardando' | 'concluido'
  proposito: string
  url?: string
  navegador?: string
  conta?: string
}

export interface EstadoExecucao {
  linhas: LinhaLog[]
  emAndamento: boolean
  resultado?: 'sucesso' | 'erro' | 'cancelado'
  /** Login mais recente desta execucao (o instalador pede antes de rodar o script). */
  login?: EstadoLogin
  /** Ultimo progresso informado pelo script (Write-BizappProgresso). */
  progresso?: { percentual: number; fase: string }
  /** Momento em que a execucao comecou (para mostrar o tempo decorrido). */
  inicio?: number
  execucaoId?: string
}

type AoTerminar = (sucesso: boolean, saidas: Record<string, string>) => void

/**
 * Guarda o log e o estado de cada execucao por "chave" (ex.: "biblioteca-prompts/listas"),
 * para que o log continue visivel quando a pessoa volta para uma etapa.
 */
export function useExecucoes(aoReceberSaida: (chave: string, nome: string, valor: string) => void) {
  const [estados, setEstados] = useState<Record<string, EstadoExecucao>>({})
  const chavePorId = useRef(new Map<string, string>())
  const aoTerminarPorId = useRef(new Map<string, AoTerminar>())
  const canceladas = useRef(new Set<string>())
  const pendentes = useRef(new Map<string, EventoExecucao[]>())
  const execucaoPorChave = useRef(new Map<string, string>())
  const saidaRef = useRef(aoReceberSaida)
  saidaRef.current = aoReceberSaida

  const atualizar = (chave: string, f: (e: EstadoExecucao) => EstadoExecucao): void =>
    setEstados((atual) => ({ ...atual, [chave]: f(atual[chave] ?? { linhas: [], emAndamento: false }) }))

  const processar = useCallback((ev: EventoExecucao): void => {
    const chave = chavePorId.current.get(ev.execucaoId)
    if (!chave) {
      // O evento pode chegar antes de a chamada que iniciou a execucao retornar o id
      pendentes.current.set(ev.execucaoId, [...(pendentes.current.get(ev.execucaoId) ?? []), ev])
      return
    }
    if (ev.tipo === 'log') {
      atualizar(chave, (e) => ({ ...e, linhas: [...e.linhas, { nivel: ev.nivel, mensagem: ev.mensagem }] }))
    } else if (ev.tipo === 'saida') {
      saidaRef.current(chave, ev.nome, ev.valor)
    } else if (ev.tipo === 'login') {
      const login: EstadoLogin = ev.estado === 'aguardando'
        ? { estado: ev.estado, proposito: ev.proposito, url: ev.url, navegador: ev.navegador }
        : { estado: ev.estado, proposito: ev.proposito, conta: ev.conta }
      atualizar(chave, (e) => ({ ...e, login }))
    } else if (ev.tipo === 'progresso') {
      atualizar(chave, (e) => ({ ...e, progresso: { percentual: ev.percentual, fase: ev.fase } }))
    } else {
      const cancelada = canceladas.current.has(ev.execucaoId)
      atualizar(chave, (e) => ({ ...e, emAndamento: false, resultado: cancelada ? 'cancelado' : ev.sucesso ? 'sucesso' : 'erro' }))
      aoTerminarPorId.current.get(ev.execucaoId)?.(ev.sucesso && !cancelada, ev.saidas)
      aoTerminarPorId.current.delete(ev.execucaoId)
      execucaoPorChave.current.delete(chave)
    }
  }, [])

  useEffect(() => api.onEventoExecucao(processar), [processar])

  const iniciar = useCallback(async (chave: string, disparar: () => Promise<string>, aoTerminar?: AoTerminar) => {
    atualizar(chave, () => ({ linhas: [], emAndamento: true, inicio: Date.now() }))
    try {
      const id = await disparar()
      chavePorId.current.set(id, chave)
      execucaoPorChave.current.set(chave, id)
      atualizar(chave, (e) => ({ ...e, execucaoId: id }))
      if (aoTerminar) aoTerminarPorId.current.set(id, aoTerminar)
      const atrasados = pendentes.current.get(id) ?? []
      pendentes.current.delete(id)
      atrasados.forEach(processar)
    } catch (erro) {
      atualizar(chave, (e) => ({
        ...e,
        emAndamento: false,
        resultado: 'erro',
        linhas: [...e.linhas, { nivel: 'erro', mensagem: (erro as Error).message }]
      }))
    }
  }, [processar])

  const cancelar = useCallback((chave: string) => {
    const id = execucaoPorChave.current.get(chave)
    if (!id) return
    canceladas.current.add(id)
    void api.cancelarExecucao(id)
  }, [])

  /** Apaga o log e o estado das execucoes cujas chaves comecam com o prefixo. */
  const limpar = useCallback((prefixo: string) => {
    setEstados((atual) => Object.fromEntries(Object.entries(atual).filter(([chave]) => !chave.startsWith(prefixo))))
  }, [])

  const algumaEmAndamento = Object.values(estados).some((e) => e.emAndamento)
  return { estados, iniciar, cancelar, limpar, algumaEmAndamento }
}
