import { app } from 'electron'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join, resolve, sep } from 'node:path'
import type { ModuloManifesto } from '../shared/tipos'

/** Pasta modules/: no app empacotado fica em resources/, em dev na raiz do projeto. */
export function pastaModulos(): string {
  return app.isPackaged ? join(process.resourcesPath, 'modules') : join(app.getAppPath(), 'modules')
}

let cache: ModuloManifesto[] | null = null

export function listarModulos(): ModuloManifesto[] {
  if (cache) return cache
  const raiz = pastaModulos()
  cache = readdirSync(raiz, { withFileTypes: true })
    .filter((d) => d.isDirectory() && !d.name.startsWith('_'))
    .map((d) => join(raiz, d.name, 'module.json'))
    .filter((arquivo) => existsSync(arquivo))
    .map((arquivo) => JSON.parse(readFileSync(arquivo, 'utf8')) as ModuloManifesto)
  return cache
}

export function obterModulo(id: string): ModuloManifesto {
  const modulo = listarModulos().find((m) => m.id === id)
  if (!modulo) throw new Error(`Modulo desconhecido: ${id}`)
  return modulo
}

/** Resolve um caminho relativo dentro da pasta do modulo, sem deixar sair dela. */
export function caminhoNoModulo(moduloId: string, relativo: string): string {
  const base = resolve(pastaModulos(), obterModulo(moduloId).id)
  const alvo = resolve(base, relativo)
  if (alvo !== base && !alvo.startsWith(base + sep)) {
    throw new Error(`Caminho fora do modulo: ${relativo}`)
  }
  return alvo
}
