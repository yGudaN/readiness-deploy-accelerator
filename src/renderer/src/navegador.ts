import { createContext, useContext } from 'react'
import type { Navegador } from '@shared/tipos'

export const NAVEGADOR_PADRAO = 'padrao'
const CHAVE = 'bizapp.navegador'

/** Navegador escolhido para logins e links (guardado so neste computador). */
export function lerNavegadorPreferido(): string {
  try {
    return localStorage.getItem(CHAVE) ?? NAVEGADOR_PADRAO
  } catch {
    return NAVEGADOR_PADRAO
  }
}

export function salvarNavegadorPreferido(id: string): void {
  try {
    localStorage.setItem(CHAVE, id)
  } catch {
    // sem armazenamento: a escolha vale so ate fechar o app
  }
}

export interface ContextoNavegador {
  atual: string
  lista: Navegador[]
}

export const NavegadorContexto = createContext<ContextoNavegador>({ atual: NAVEGADOR_PADRAO, lista: [] })

export function useNavegador(): ContextoNavegador & { nomeDe: (id?: string) => string } {
  const ctx = useContext(NavegadorContexto)
  return { ...ctx, nomeDe: (id) => ctx.lista.find((n) => n.id === id)?.nome ?? 'navegador padrão' }
}
