/** Substitui {{Campo}} pelos valores informados. Campos ausentes viram string vazia. */
export function aplicarModelo(texto: string, valores: Record<string, string>): string {
  return texto.replace(/\{\{\s*([A-Za-z0-9_]+)\s*\}\}/g, (_, chave: string) => valores[chave] ?? '')
}

/** Compara versoes no formato 1.2.3 (ignora sufixos como -preview). */
export function compararVersoes(a: string, b: string): number {
  const pa = a.split(/[.-]/).map((p) => parseInt(p, 10) || 0)
  const pb = b.split(/[.-]/).map((p) => parseInt(p, 10) || 0)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0)
    if (d !== 0) return d
  }
  return 0
}
