import { app, BrowserWindow, ipcMain, Menu, shell } from 'electron'
import { join, resolve, sep } from 'node:path'
import { aplicarModelo } from '../shared/modelo'
import type { EventoExecucao, TokenDef } from '../shared/tipos'
import { contaAtual, entrarComOutraConta, obterToken, trocarConta } from './autenticacao'
import { caminhoNoModulo, listarModulos, obterModulo } from './modulos'
import { abrirNoNavegador, listarNavegadores } from './navegadores'
import { cancelarExecucao, cancelarTodas, iniciarExecucao, type Preparacao } from './powershell'
import { modulosPsDeclarados, verificarPreRequisitos } from './prerequisitos'

let janela: BrowserWindow | null = null

/** Pagina de login aberta por execucao (para "abrir de novo" em outro navegador). */
const loginsPendentes = new Map<string, string>()

function criarJanela(): void {
  janela = new BrowserWindow({
    width: 1120,
    height: 760,
    minWidth: 960,
    minHeight: 640,
    title: 'Readiness Deploy Accelerator',
    backgroundColor: '#F3F2F5',
    show: false,
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  })
  janela.once('ready-to-show', () => janela?.show())

  // Links externos nunca abrem dentro do app
  janela.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('https://')) void shell.openExternal(url)
    return { action: 'deny' }
  })

  if (!app.isPackaged && process.env.ELECTRON_RENDERER_URL) {
    void janela.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    void janela.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

function emitir(evento: EventoExecucao): void {
  janela?.webContents.send('execucao:evento', evento)
}

/** Antes do script: faz os logins que ele declara e entrega os tokens em $entrada.Tokens. */
function prepararTokens(defs: TokenDef[], valores: Record<string, string>, navegadorId: string): Preparacao {
  return async (execucaoId, log, sinal) => {
    const tokens: Record<string, string> = {}
    for (const def of defs) {
      const proposito = aplicarModelo(def.proposito, valores)
      tokens[def.nome] = await obterToken(
        {
          tenant: aplicarModelo(def.tenant, valores),
          clientId: aplicarModelo(def.clientId, valores),
          escopo: aplicarModelo(def.escopo, valores),
          proposito
        },
        {
          navegadorId,
          sinal,
          log,
          abrirNoNavegador,
          aoAguardar: (url) => {
            loginsPendentes.set(execucaoId, url)
            const navegador = navegadorId
            emitir({ execucaoId, tipo: 'login', estado: 'aguardando', proposito, url, navegador })
          },
          aoConcluir: (conta) => {
            loginsPendentes.delete(execucaoId)
            emitir({ execucaoId, tipo: 'login', estado: 'concluido', proposito, conta })
          }
        }
      ).finally(() => loginsPendentes.delete(execucaoId))
    }
    return { Tokens: tokens }
  }
}

/** Login feito na tela entre itens (fora de uma execucao); um por vez, cancelavel. */
let loginAvulso: AbortController | null = null

function registrarIpcLogin(): void {
  ipcMain.handle('login:conta-atual', () => contaAtual())
  ipcMain.handle('login:trocar', () => trocarConta())
  ipcMain.handle('login:cancelar', () => loginAvulso?.abort())

  // Troca de conta e ja faz o login do item. Usa o primeiro login declarado nas etapas do item;
  // se ele depender de dados que a pessoa ainda vai preencher (ex.: {{Tenant}}), so troca a conta
  // e o login acontece na primeira etapa.
  ipcMain.handle('login:entrar', async (_e, moduloId: string, navegadorId: string) => {
    const def = obterModulo(moduloId).etapas.flatMap((e) => e.script?.tokens ?? [])[0]
    const pedido = def && {
      tenant: aplicarModelo(def.tenant, {}),
      clientId: aplicarModelo(def.clientId, {}),
      escopo: aplicarModelo(def.escopo, {}),
      proposito: def.proposito
    }
    if (!pedido || [def.tenant, def.clientId, def.escopo].some((t) => /\{\{/.test(t))) {
      trocarConta()
      return { pendente: true }
    }
    loginAvulso?.abort()
    loginAvulso = new AbortController()
    const conta = await entrarComOutraConta(pedido, {
      navegadorId,
      sinal: loginAvulso.signal,
      log: () => undefined,
      abrirNoNavegador,
      aoAguardar: () => undefined,
      aoConcluir: () => undefined
    })
    return { pendente: false, conta }
  })
}

function registrarIpc(): void {
  registrarIpcLogin()
  ipcMain.handle('app:versao', () => app.getVersion())
  ipcMain.handle('modulos:listar', () => listarModulos())
  ipcMain.handle('prerequisitos:verificar', () => verificarPreRequisitos(listarModulos()))
  ipcMain.handle('navegadores:listar', () => listarNavegadores())

  // O renderer so informa ids: o caminho do script e os logins vem sempre do manifesto
  ipcMain.handle('execucao:script', (_e, moduloId: string, etapaId: string, valores: Record<string, string>, navegadorId: string) => {
    const etapa = obterModulo(moduloId).etapas.find((e) => e.id === etapaId)
    if (!etapa?.script) throw new Error(`Etapa sem script: ${moduloId}/${etapaId}`)
    const entrada = etapa.script.entradas
      ? Object.fromEntries(etapa.script.entradas.map((c) => [c, valores[c] ?? '']))
      : valores
    return iniciarExecucao(
      ['-File', caminhoNoModulo(moduloId, etapa.script.arquivo)],
      {
        cwd: caminhoNoModulo(moduloId, '.'),
        entrada,
        preparar: etapa.script.tokens?.length ? prepararTokens(etapa.script.tokens, valores, navegadorId) : undefined
      },
      emitir
    )
  })

  ipcMain.handle('execucao:instalar-modulo-ps', (_e, nomes: string[]) => {
    const declarados = modulosPsDeclarados(listarModulos())
    const lista = [...new Set(Array.isArray(nomes) ? nomes : [nomes])]
    const invalidos = lista.filter((n) => !declarados.includes(n))
    if (!lista.length || invalidos.length) {
      throw new Error(`Modulo PowerShell nao declarado no catalogo: ${invalidos.join(', ')}`)
    }
    // Um modulo por vez, na ordem; para no primeiro erro
    const comando = lista
      .map((nome, i) => [
        `Write-Output '(${i + 1}/${lista.length}) Instalando ${nome} (pode levar alguns minutos)...'`,
        `Install-Module -Name '${nome}' -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop`,
        `Write-Output '${nome} instalado.'`
      ].join('; '))
      .join('; ')
    return iniciarExecucao(['-Command', comando], {}, emitir)
  })

  ipcMain.handle('execucao:cancelar', (_e, execucaoId: string) => cancelarExecucao(execucaoId))

  ipcMain.handle('login:reabrir', async (_e, execucaoId: string, navegadorId: string) => {
    const url = loginsPendentes.get(execucaoId)
    if (url) await abrirNoNavegador(navegadorId, url)
  })

  ipcMain.handle('abrir:arquivo', (_e, moduloId: string, caminho: string) => {
    shell.showItemInFolder(caminhoNoModulo(moduloId, caminho))
  })

  // So abre pastas dentro de Documentos\Readiness Deploy Accelerator\evidencias (gravadas pelos scripts)
  ipcMain.handle('abrir:evidencias', async (_e, caminho: string) => {
    const raiz = resolve(app.getPath('documents'), 'Readiness Deploy Accelerator', 'evidencias')
    const alvo = resolve(caminho)
    if (!alvo.toLowerCase().startsWith(raiz.toLowerCase() + sep)) throw new Error('Pasta fora da área de evidências.')
    const erro = await shell.openPath(alvo)
    if (erro) throw new Error(erro)
  })

  ipcMain.handle('abrir:link', async (_e, url: string, navegadorId: string) => {
    if (!/^https:\/\//i.test(url)) throw new Error('Somente links https são permitidos.')
    await abrirNoNavegador(navegadorId, url)
  })
}

app.whenReady().then(() => {
  Menu.setApplicationMenu(null)
  registrarIpc()
  criarJanela()
})

app.on('before-quit', cancelarTodas)
app.on('window-all-closed', () => app.quit())
