import type { ApiInstalador } from '../shared/tipos'

declare global {
  interface Window {
    /** Ausente quando a interface roda no navegador (modo de desenvolvimento com mock). */
    bizapp?: ApiInstalador
  }
}
