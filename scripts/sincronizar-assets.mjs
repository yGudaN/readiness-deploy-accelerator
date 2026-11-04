// Atualiza os arquivos que os modulos trazem de outros repositorios.
// Hoje: o .sppkg da Biblioteca, gerado pelo build do SPFx no repositorio sharepoint-biblioteca-prompt
// (pasta implantacao/). Por padrao, procura esse repositorio ao lado deste; para outro lugar, use
// a variavel de ambiente BIBLIOTECA_REPO. Se a origem nao existir, mantem a copia versionada aqui.
import { copyFileSync, existsSync, mkdirSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const repoBiblioteca = process.env.BIBLIOTECA_REPO ?? join(raiz, '..', 'SharepointBibliotecaPrompt')

const copias = [
  {
    de: join(repoBiblioteca, 'implantacao', 'sharepoint-biblioteca-prompt.sppkg'),
    para: join(raiz, 'modules', 'biblioteca-prompts', 'assets', 'sharepoint-biblioteca-prompt.sppkg')
  }
]

let falhou = false
for (const { de, para } of copias) {
  if (!existsSync(de)) {
    if (existsSync(para)) {
      console.warn(`Origem nao encontrada (${de}). Mantida a copia atual de ${statSync(para).mtime.toISOString().slice(0, 10)}.`)
    } else {
      console.error(`Origem nao encontrada e sem copia local: ${de}`)
      falhou = true
    }
    continue
  }
  mkdirSync(dirname(para), { recursive: true })
  copyFileSync(de, para)
  console.log(`Copiado: ${para}`)
}
process.exit(falhou ? 1 : 0)
