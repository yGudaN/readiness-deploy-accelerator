import { contextBridge, ipcRenderer, type IpcRendererEvent } from 'electron'
import type { ApiInstalador, EventoExecucao } from '../shared/tipos'

const api: ApiInstalador = {
  versaoApp: () => ipcRenderer.invoke('app:versao'),
  listarModulos: () => ipcRenderer.invoke('modulos:listar'),
  verificarPreRequisitos: () => ipcRenderer.invoke('prerequisitos:verificar'),
  listarNavegadores: () => ipcRenderer.invoke('navegadores:listar'),
  executarScript: (moduloId, etapaId, valores, navegadorId) => ipcRenderer.invoke('execucao:script', moduloId, etapaId, valores, navegadorId),
  instalarModuloPs: (nome) => ipcRenderer.invoke('execucao:instalar-modulo-ps', nome),
  cancelarExecucao: (execucaoId) => ipcRenderer.invoke('execucao:cancelar', execucaoId),
  reabrirLogin: (execucaoId, navegadorId) => ipcRenderer.invoke('login:reabrir', execucaoId, navegadorId),
  onEventoExecucao: (callback) => {
    const ouvinte = (_e: IpcRendererEvent, evento: EventoExecucao): void => callback(evento)
    ipcRenderer.on('execucao:evento', ouvinte)
    return () => ipcRenderer.removeListener('execucao:evento', ouvinte)
  },
  abrirArquivoDoModulo: (moduloId, caminho) => ipcRenderer.invoke('abrir:arquivo', moduloId, caminho),
  abrirLink: (url, navegadorId) => ipcRenderer.invoke('abrir:link', url, navegadorId)
}

contextBridge.exposeInMainWorld('bizapp', api)
