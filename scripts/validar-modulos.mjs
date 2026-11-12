// Valida os manifestos em modules/: estrutura, ids, referencias a campos e arquivos,
// e a sintaxe dos scripts PowerShell (via parser do pwsh).
import { execFileSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const pastaModulos = join(dirname(fileURLToPath(import.meta.url)), '..', 'modules')
const erros = []
const avisos = []
const scripts = [join(pastaModulos, '_compartilhado', 'BizappInstalador.psm1')]
const idsModulos = new Set()

for (const dir of readdirSync(pastaModulos, { withFileTypes: true })) {
  if (!dir.isDirectory() || dir.name.startsWith('_')) continue
  const base = join(pastaModulos, dir.name)
  const arquivo = join(base, 'module.json')
  const erro = (msg) => erros.push(`${dir.name}: ${msg}`)
  if (!existsSync(arquivo)) { erro('module.json nao encontrado'); continue }

  let m
  try { m = JSON.parse(readFileSync(arquivo, 'utf8')) } catch (e) { erro(`JSON invalido: ${e.message}`); continue }

  for (const chave of ['id', 'nome', 'versao', 'resumo', 'descricao']) if (!m[chave]) erro(`"${chave}" obrigatorio`)
  if (m.id !== dir.name) erro(`id "${m.id}" deve ser igual ao nome da pasta`)
  if (idsModulos.has(m.id)) erro(`id duplicado: ${m.id}`)
  idsModulos.add(m.id)
  if (!Array.isArray(m.preRequisitos)) erro('"preRequisitos" deve ser uma lista')
  if (!Array.isArray(m.etapas) || m.etapas.length === 0) { erro('"etapas" deve ter ao menos uma etapa'); continue }

  const campos = new Set()
  const saidas = new Set()
  const idsEtapas = new Set()
  // Saidas gravadas por modulos auxiliares (.psm1 do item e compartilhados, ex.: PastaEvidencias)
  const pastasAux = [join(base, 'scripts'), join(pastaModulos, '_compartilhado')]
  for (const pasta of pastasAux.filter(existsSync)) {
    for (const f of readdirSync(pasta).filter((n) => n.endsWith('.psm1'))) {
      const caminhoAux = join(pasta, f)
      if (!scripts.includes(caminhoAux)) scripts.push(caminhoAux)
      for (const s of readFileSync(caminhoAux, 'utf8').matchAll(/Set-BizappSaida\s+-Nome\s+'([^']+)'/g)) saidas.add(s[1])
    }
  }
  for (const etapa of m.etapas) {
    if (!etapa.id || !etapa.titulo) erro('toda etapa precisa de "id" e "titulo"')
    if (idsEtapas.has(etapa.id)) erro(`etapa duplicada: ${etapa.id}`)
    idsEtapas.add(etapa.id)
    for (const c of etapa.campos ?? []) {
      if (campos.has(c.id)) erro(`campo duplicado: ${c.id}`)
      campos.add(c.id)
      if (!['texto', 'url', 'guid', 'escolha'].includes(c.tipo)) erro(`campo ${c.id}: tipo "${c.tipo}" invalido`)
      if (c.tipo === 'escolha') {
        if (!Array.isArray(c.opcoes) || c.opcoes.length < 2) erro(`campo ${c.id}: "escolha" precisa de pelo menos 2 opcoes`)
        else if (c.padrao && !c.opcoes.some((o) => o.valor === c.padrao)) erro(`campo ${c.id}: padrao "${c.padrao}" nao e uma das opcoes`)
      }
      if (c.padraoRegex) { try { new RegExp(c.padraoRegex) } catch { erro(`campo ${c.id}: regex invalida`) } }
    }
    for (const a of etapa.arquivos ?? []) {
      if (!existsSync(join(base, a.caminho))) avisos.push(`${dir.name}: arquivo ausente ${a.caminho} (rode "npm run sincronizar")`)
    }
    if (etapa.script) {
      const caminho = join(base, etapa.script.arquivo)
      if (!existsSync(caminho)) erro(`script nao encontrado: ${etapa.script.arquivo}`)
      else {
        scripts.push(caminho)
        // Saidas declaradas via Set-BizappSaida ficam disponiveis para o resumo
        for (const s of readFileSync(caminho, 'utf8').matchAll(/Set-BizappSaida\s+-Nome\s+'([^']+)'/g)) saidas.add(s[1])
      }
      for (const t of etapa.script.tokens ?? []) {
        for (const chave of ['nome', 'clientId', 'tenant', 'escopo', 'proposito']) if (!t[chave]) erro(`etapa ${etapa.id}: token sem "${chave}"`)
        if (t.clientId && !/^(@[a-z-]+|\{\{\s*\w+\s*\}\}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i.test(t.clientId)) {
          erro(`etapa ${etapa.id}: clientId "${t.clientId}" deve ser um GUID, {{Campo}} ou cliente conhecido (@azure-powershell, @power-platform-cli, @graph-cli, @exchange-online)`)
        }
        // O token pode ser lido no proprio script ou num .psm1 auxiliar do item
        const auxiliares = existsSync(join(base, 'scripts'))
          ? readdirSync(join(base, 'scripts')).filter((n) => n.endsWith('.psm1')).map((n) => readFileSync(join(base, 'scripts', n), 'utf8'))
          : []
        const conteudo = [existsSync(caminho) ? readFileSync(caminho, 'utf8') : '', ...auxiliares].join('\n')
        if (!new RegExp(`-Nome\\s+'?${t.nome}'?`).test(conteudo)) avisos.push(`${dir.name}: etapa ${etapa.id} declara o token "${t.nome}", mas o script nao chama Get-BizappToken -Nome ${t.nome}`)
      }
      for (const entrada of etapa.script.entradas ?? []) {
        if (!campos.has(entrada) && !saidas.has(entrada)) erro(`etapa ${etapa.id}: entrada "${entrada}" nao e um campo nem uma saida desta etapa ou de uma anterior`)
      }
    }
  }
  const resumo = JSON.stringify(m.resumoFinal ?? {}) + JSON.stringify(m.etapas)
  for (const ref of resumo.matchAll(/\{\{\s*([A-Za-z0-9_]+)\s*\}\}/g)) {
    if (!campos.has(ref[1]) && !saidas.has(ref[1])) erro(`referencia {{${ref[1]}}} nao corresponde a nenhum campo ou saida`)
  }
}

// Dependencias entre itens: o id precisa existir no catalogo
for (const dir of readdirSync(pastaModulos, { withFileTypes: true })) {
  if (!dir.isDirectory() || dir.name.startsWith('_')) continue
  const arquivo = join(pastaModulos, dir.name, 'module.json')
  if (!existsSync(arquivo)) continue
  let m
  try { m = JSON.parse(readFileSync(arquivo, 'utf8')) } catch { continue }
  for (const d of m.dependeDe ?? []) {
    if (!d.id || !d.precisaDe) erros.push(`${dir.name}: dependeDe precisa de "id" e "precisaDe"`)
    else if (!idsModulos.has(d.id)) erros.push(`${dir.name}: dependeDe "${d.id}" nao e um item do catalogo`)
    else if (d.id === m.id) erros.push(`${dir.name}: o item nao pode depender de si mesmo`)
  }
}

// Sintaxe dos scripts PowerShell
const lista = scripts.map((s) => `'${s.replace(/'/g, "''")}'`).join(',')
try {
  const saida = execFileSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
    foreach ($s in @(${lista})) {
      $erros = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($s, [ref]$null, [ref]$erros)
      foreach ($e in $erros) { "$($s):$($e.Extent.StartLineNumber): $($e.Message)" }
    }`], { encoding: 'utf8' })
  saida.split(/\r?\n/).filter(Boolean).forEach((l) => erros.push(`sintaxe PowerShell: ${l}`))
} catch (e) {
  avisos.push(`nao foi possivel validar a sintaxe PowerShell: ${e.message}`)
}

avisos.forEach((a) => console.warn(`AVISO  ${a}`))
erros.forEach((e) => console.error(`ERRO   ${e}`))
console.log(`${idsModulos.size} modulo(s), ${scripts.length} script(s) verificados. ${erros.length} erro(s), ${avisos.length} aviso(s).`)
process.exit(erros.length ? 1 : 0)
