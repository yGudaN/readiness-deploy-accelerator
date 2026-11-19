// Publica o instalador da versao atual nas Releases do repositorio do GitHub ("repositorioGithub" do
// package.json). O site de download aponta para o .exe publicado aqui.
// Uso: npm run dist, depois npm run publicar (precisa do GitHub CLI logado: gh auth login).
import { readFileSync, existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { execFileSync } from 'node:child_process'

const raiz = resolve(import.meta.dirname, '..')
const pacote = JSON.parse(readFileSync(join(raiz, 'package.json'), 'utf8'))
const { version: versao, repositorioGithub: repo } = pacote
const exe = join(raiz, 'dist', `Readiness-Deploy-Accelerator-Setup-${versao}.exe`)
if (!repo) throw new Error('Preencha "repositorioGithub" no package.json.')
if (!existsSync(exe)) throw new Error(`Instalador não encontrado: ${exe}. Rode npm run dist antes.`)

const tag = `v${versao}`
const notas = `Readiness Deploy Accelerator ${versao}. Baixe o arquivo Readiness-Deploy-Accelerator-Setup-${versao}.exe abaixo e execute. Requer Windows 10 ou 11 (64 bits) e PowerShell 7.4 ou superior.`
execFileSync('gh', ['release', 'create', tag, exe, '--repo', repo, '--title', `Readiness Deploy Accelerator ${versao}`, '--notes', notas, '--latest'], { stdio: 'inherit' })
console.log(`Versão publicada: https://github.com/${repo}/releases/tag/${tag}`)
