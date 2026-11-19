// Gera o site de download (site/Bizapp_ReadinessDeployAccelerator.html) a partir de site/modelo.html:
// versao do package.json, tamanho do instalador em dist/, catalogo lido dos module.json e logo
// embutido em base64 (o site vira um arquivo so, para hospedar no Blob). O botao de download aponta
// para o instalador da versao nas Releases do repositorio "repositorioGithub" do package.json
// (publicado com npm run publicar).
// Uso: npm run site (depois de npm run dist, para pegar o tamanho real do instalador).
import { readFileSync, readdirSync, writeFileSync, existsSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'

const raiz = resolve(import.meta.dirname, '..')
const pacote = JSON.parse(readFileSync(join(raiz, 'package.json'), 'utf8'))
const versao = pacote.version

// Mesma ordem de grupos do catalogo do app
const tipos = readFileSync(join(raiz, 'src', 'shared', 'tipos.ts'), 'utf8')
const categorias = [...tipos.match(/CATEGORIAS = \[([\s\S]*?)\]/)[1].matchAll(/'([^']+)'/g)].map((m) => m[1])

const modulos = readdirSync(join(raiz, 'modules'), { withFileTypes: true })
  .filter((d) => d.isDirectory() && existsSync(join(raiz, 'modules', d.name, 'module.json')))
  .map((d) => JSON.parse(readFileSync(join(raiz, 'modules', d.name, 'module.json'), 'utf8')))

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
const grupos = [...categorias, 'Outros']
  .map((c) => ({ titulo: c, itens: modulos.filter((m) => (c === 'Outros' ? !categorias.includes(m.categoria) : m.categoria === c)) }))
  .filter((g) => g.itens.length)
// Os 35 pontos do COE (src/shared/pontos-coe.json, a mesma lista do botao Manual do catalogo do app; mesmos IDs do Loop de acompanhamento): os que apontam para
// um modulo vao para "Automatizado", com os detalhes do module.json (iguais aos do catalogo do app);
// os demais vao para "Manual".
const { pontos } = JSON.parse(readFileSync(join(raiz, 'src', 'shared', 'pontos-coe.json'), 'utf8'))
const porId = new Map(modulos.map((m) => [m.id, m]))
const codigo = (n) => String(n).padStart(2, '0')
const automatizados = pontos.filter((p) => p.modulo)
const manuais = pontos.filter((p) => !p.modulo)
for (const p of automatizados) if (!porId.has(p.modulo)) throw new Error(`Ponto ${p.id}: módulo "${p.modulo}" não existe em modules/.`)
const semPonto = modulos.filter((m) => !automatizados.some((p) => p.modulo === m.id))
if (semPonto.length) console.warn(`Aviso: módulos sem ponto em site/pontos.json: ${semPonto.map((m) => m.id).join(', ')}`)

const htmlAutomatizados = automatizados
  .map((p) => {
    const m = porId.get(p.modulo)
    const etiquetas = [
      m.tempoEstimadoMin ? `~${m.tempoEstimadoMin} min` : null,
      `${m.etapas.length} etapas`,
      ...(m.papeisNecessarios ?? []),
      ...(m.dependeDe ?? []).map((d) => `Depende de: ${porId.get(d.id)?.nome ?? d.id}`)
    ].filter(Boolean)
    return [
      '          <details class="ponto">',
      `            <summary><span class="ponto__id">${codigo(p.id)}</span><span class="ponto__texto"><strong>${esc(p.item)}</strong><span>${esc(p.pilar)} · no app: ${esc(m.nome)}</span></span></summary>`,
      '            <div class="ponto__detalhes">',
      `              <p class="ponto__resumo">${esc(m.resumo)}</p>`,
      `              <p>${esc(m.descricao)}</p>`,
      ...(m.oQueInstala?.length
        ? ['              <div class="ponto__subtitulo">O que será instalado</div>', '              <ul>', ...m.oQueInstala.map((o) => `                <li>${esc(o)}</li>`), '              </ul>']
        : []),
      `              <div class="etiquetas">${etiquetas.map((e) => `<span class="etiqueta">${esc(e)}</span>`).join('')}</div>`,
      '            </div>',
      '          </details>'
    ].join('\n')
  })
  .join('\n')
const htmlManuais = manuais
  .map((p) => [
    '            <li class="ponto ponto--manual">',
    `              <span class="ponto__id">${codigo(p.id)}</span><span class="ponto__texto"><strong>${esc(p.item)}</strong><span>${esc(p.pilar)} · ${esc(p.automacao)}</span>${p.pendencia ? `<em>Decisão pendente: ${esc(p.pendencia)}</em>` : ''}</span>`,
    '            </li>'
  ].join('\n'))
  .join('\n')

const arquivo = `Readiness-Deploy-Accelerator-Setup-${versao}.exe`
const exe = join(raiz, 'dist', arquivo)
const tamanho = existsSync(exe) ? `${Math.round(statSync(exe).size / 1048576)} MB` : 'cerca de 120 MB'
if (!existsSync(exe)) console.warn(`Aviso: ${arquivo} não está em dist/. Rode npm run dist para usar o tamanho real.`)
const minutos = modulos.reduce((t, m) => t + (m.tempoEstimadoMin ?? 0), 0)
const logo = `data:image/png;base64,${readFileSync(join(raiz, 'site', 'logo-bizapp-branco.png')).toString('base64')}`

const valores = {
  VERSAO: versao,
  ARQUIVO: `https://github.com/${pacote.repositorioGithub}/releases/download/v${versao}/${arquivo}`,
  TAMANHO: tamanho,
  QTD_ITENS: String(modulos.length),
  QTD_GRUPOS: String(grupos.length),
  TEMPO_HORAS: String(Math.round(minutos / 60)),
  QTD_PONTOS: String(pontos.length),
  QTD_AUTOMATIZADOS: String(automatizados.length),
  QTD_MANUAIS: String(manuais.length),
  AUTOMATIZADOS: htmlAutomatizados,
  MANUAIS: htmlManuais,
  LOGO: logo,
  REPOSITORIO: `https://github.com/${pacote.repositorioGithub}`
}
let html = readFileSync(join(raiz, 'site', 'modelo.html'), 'utf8')
html = html.replace(/\{\{([A-Z_]+)\}\}/g, (m, k) => {
  if (!(k in valores)) throw new Error(`Marcador sem valor: ${m}`)
  return valores[k]
})
const saida = join(raiz, 'site', 'Bizapp_ReadinessDeployAccelerator.html')
writeFileSync(saida, html, 'utf8')
console.log(`Site gerado: ${saida} (versão ${versao}, ${modulos.length} itens, ${grupos.length} grupos, instalador ${tamanho}, ~${Math.round(minutos / 60)} h)`)
