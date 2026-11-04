import { app, BrowserWindow, ipcMain, Menu, shell } from 'electron'
import { join } from 'node:path'
import { aplicarModelo } from '../shared/modelo'
import type { EventoExecucao, TokenDef } from '../shared/tipos'
import { obterToken } from './autenticacao'
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

function registrarIpc(): void {
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

  ipcMain.handle('execucao:instalar-modulo-ps', (_e, nome: string) => {
    if (!modulosPsDeclarados(listarModulos()).includes(nome)) {
      throw new Error(`Modulo PowerShell nao declarado no catalogo: ${nome}`)
    }
    const comando = [
      `Write-Output 'Instalando ${nome} (pode levar alguns minutos)...'`,
      `Install-Module -Name '${nome}' -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop`,
      `Write-Output '${nome} instalado.'`
    ].join('; ')
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
