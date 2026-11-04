import { spawn, execFile, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import type { EventoExecucao, NivelLog } from '../shared/tipos'

const PREFIXO_EVENTO = '::bizapp::'
const ANSI = /\x1b\[[0-9;?]*[A-Za-z]/g
const ARGS_BASE = ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass']

export function localizarPwsh(): string {
  const candidatos = [
    join(process.env.ProgramFiles ?? 'C:\\Program Files', 'PowerShell', '7', 'pwsh.exe'),
    join(process.env.LOCALAPPDATA ?? '', 'Microsoft', 'WindowsApps', 'pwsh.exe')
  ]
  return candidatos.find((c) => existsSync(c)) ?? 'pwsh.exe'
}

/** Roda um comando curto e devolve o stdout (pre-requisitos, deteccao de navegadores). */
export function executarComando(comando: string): Promise<string> {
  return new Promise((resolver, rejeitar) => {
    execFile(localizarPwsh(), [...ARGS_BASE, '-Command', comando], { windowsHide: true, timeout: 60_000 }, (erro, stdout, stderr) => {
      if (erro) rejeitar(Object.assign(erro, { stderr }))
      else resolver(stdout)
    })
  })
}

export type Log = (nivel: NivelLog, mensagem: string) => void

/**
 * Trabalho feito antes de iniciar o pwsh (ex.: login). Devolve dados extras para a entrada
 * do script. Deve respeitar o sinal: a pessoa pode cancelar a execucao enquanto ele roda.
 */
export type Preparacao = (execucaoId: string, log: Log, sinal: AbortSignal) => Promise<Record<string, unknown>>

interface Execucao {
  processo?: ChildProcess
  controle: AbortController
}

const execucoes = new Map<string, Execucao>()

/**
 * Inicia o pwsh e repassa a saida como eventos.
 * A entrada vai em JSON pelo stdin (nunca em arquivo, porque pode conter tokens).
 * Linhas "::bizapp::{json}" viram eventos estruturados (ver modules/_compartilhado/BizappInstalador.psm1);
 * o resto vira log comum (stdout = info, stderr = erro).
 */
export function iniciarExecucao(
  args: string[],
  opcoes: { cwd?: string; entrada?: Record<string, unknown>; preparar?: Preparacao },
  emitir: (evento: EventoExecucao) => void
): string {
  const execucaoId = randomUUID()
  const controle = new AbortController()
  const execucao: Execucao = { controle }
  execucoes.set(execucaoId, execucao)

  const saidas: Record<string, string> = {}
  const log: Log = (nivel, mensagem) => emitir({ execucaoId, tipo: 'log', nivel, mensagem })

  let finalizado = false
  const finalizar = (sucesso: boolean, codigo: number | null): void => {
    if (finalizado) return
    finalizado = true
    execucoes.delete(execucaoId)
    emitir({ execucaoId, tipo: 'fim', sucesso, codigo, saidas })
  }

  const tratarLinha = (linha: string, padrao: NivelLog): void => {
    const texto = linha.replace(ANSI, '').replace(/\r$/, '')
    if (texto.startsWith(PREFIXO_EVENTO)) {
      try {
        const ev = JSON.parse(texto.slice(PREFIXO_EVENTO.length))
        if (ev.tipo === 'saida') {
          saidas[ev.nome] = String(ev.valor ?? '')
          emitir({ execucaoId, tipo: 'saida', nome: ev.nome, valor: saidas[ev.nome] })
        } else {
          log(ev.nivel ?? 'info', String(ev.mensagem ?? ''))
        }
        return
      } catch {
        // linha malformada: cai no log comum
      }
    }
    log(padrao, texto)
  }

  const leitorDeLinhas = (padrao: NivelLog) => {
    let resto = ''
    return (pedaco: Buffer): void => {
      const linhas = (resto + pedaco.toString('utf8')).split('\n')
      resto = linhas.pop() ?? ''
      linhas.forEach((l) => tratarLinha(l, padrao))
    }
  }

  const iniciarProcesso = (entrada: Record<string, unknown>): void => {
    const processo = spawn(localizarPwsh(), [...ARGS_BASE, ...args], {
      cwd: opcoes.cwd,
      windowsHide: true,
      env: { ...process.env, NO_COLOR: '1' }
    })
    execucao.processo = processo
    processo.stdout?.on('data', leitorDeLinhas('info'))
    processo.stderr?.on('data', leitorDeLinhas('erro'))
    processo.on('error', (erro) => {
      log('erro', `Não foi possível iniciar o PowerShell 7 (pwsh): ${erro.message}`)
      finalizar(false, null)
    })
    processo.on('close', (codigo) => finalizar(codigo === 0 && !controle.signal.aborted, codigo))
    processo.stdin?.on('error', () => undefined)
    processo.stdin?.end(JSON.stringify(entrada), 'utf8')
  }

  void (async () => {
    try {
      const extra = opcoes.preparar ? await opcoes.preparar(execucaoId, log, controle.signal) : {}
      if (controle.signal.aborted) throw new Error('Execução cancelada.')
      iniciarProcesso({ ...opcoes.entrada, ...extra })
    } catch (erro) {
      log('erro', (erro as Error).message)
      finalizar(false, null)
    }
  })()

  return execucaoId
}

export function cancelarExecucao(execucaoId: string): void {
  const execucao = execucoes.get(execucaoId)
  if (!execucao) return
  execucao.controle.abort()
  const pid = execucao.processo?.pid
  // Mata a arvore inteira (o pwsh pode ter aberto processos filhos)
  if (pid) execFile('taskkill', ['/pid', String(pid), '/T', '/F'], { windowsHide: true }, () => undefined)
}

export function cancelarTodas(): void {
  for (const id of execucoes.keys()) cancelarExecucao(id)
}
