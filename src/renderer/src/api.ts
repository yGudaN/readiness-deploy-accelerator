import type { ApiInstalador, EventoExecucao, ModuloManifesto } from '@shared/tipos'

/**
 * Dentro do Electron a API vem do preload. No navegador (npm run dev:web) usamos um
 * simulador, para desenvolver as telas sem rodar PowerShell nem tocar no tenant.
 */
function criarSimulador(): ApiInstalador {
  const manifestos = import.meta.glob<ModuloManifesto>('../../../modules/*/module.json', { eager: true, import: 'default' })
  const ouvintes = new Set<(e: EventoExecucao) => void>()
  const emitir = (e: EventoExecucao): void => ouvintes.forEach((o) => o(e))
  const espera = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))
  let pnpInstalado = false

  const simular = (saidas: Record<string, string>, login?: { proposito: string; navegador: string }, comProgresso = false): string => {
    const execucaoId = crypto.randomUUID()
    void (async () => {
      if (login) {
        await espera(300)
        emitir({ execucaoId, tipo: 'login', estado: 'aguardando', proposito: login.proposito, url: 'https://login.microsoftonline.com/simulador', navegador: login.navegador })
        emitir({ execucaoId, tipo: 'log', nivel: 'discreto', mensagem: `Login: ${login.proposito}. A página de login foi aberta no navegador.` })
        await espera(2500)
        emitir({ execucaoId, tipo: 'login', estado: 'concluido', proposito: login.proposito, conta: 'admin@contoso.onmicrosoft.com' })
        emitir({ execucaoId, tipo: 'log', nivel: 'sucesso', mensagem: 'Login concluído como admin@contoso.onmicrosoft.com.' })
      }
      const passos = ['Conectando...', 'Conectado.', 'Executando etapa simulada...', 'Concluido.']
      for (const [i, mensagem] of passos.entries()) {
        await espera(400)
        emitir({ execucaoId, tipo: 'log', nivel: i === passos.length - 1 ? 'sucesso' : i === 0 ? 'discreto' : 'info', mensagem })
        // Imita a curva real: sobe rapido ate ~93% e anda devagar no final
        if (comProgresso && i === 2) {
          for (const p of [0, 12, 35, 61, 88, 93.1, 93.5, 94.2, 95.8, 97.6, 99.4]) {
            emitir({ execucaoId, tipo: 'progresso', percentual: p, fase: p < 90 ? 'Importando componentes' : 'Finalizando: publicando apps e fluxos' })
            await espera(p < 90 ? 500 : 1200)
          }
          emitir({ execucaoId, tipo: 'progresso', percentual: 100, fase: 'Concluído' })
        }
      }
      for (const [nome, valor] of Object.entries(saidas)) emitir({ execucaoId, tipo: 'saida', nome, valor })
      emitir({ execucaoId, tipo: 'fim', sucesso: true, codigo: 0, saidas })
    })()
    return execucaoId
  }

  return {
    versaoApp: async () => '0.0.0-simulador',
    listarModulos: async () => Object.values(manifestos),
    verificarPreRequisitos: async () => {
      await espera(600)
      return [
        { chave: 'pwsh', rotulo: 'PowerShell 7.4 ou superior', ok: true, versaoEncontrada: '7.6.0', exigidoPor: ['Biblioteca de Prompts e Skills'] },
        pnpInstalado
          ? { chave: 'modulo-ps:PnP.PowerShell', rotulo: 'Módulo PnP.PowerShell 3.0 ou superior', ok: true, versaoEncontrada: '3.4.0', exigidoPor: ['Biblioteca de Prompts e Skills'] }
          : { chave: 'modulo-ps:PnP.PowerShell', rotulo: 'Módulo PnP.PowerShell 3.0 ou superior', ok: false, detalhe: 'Módulo não instalado.', acao: { tipo: 'instalar-modulo', nome: 'PnP.PowerShell' }, exigidoPor: ['Biblioteca de Prompts e Skills'] }
      ]
    },
    listarNavegadores: async () => [
      { id: 'padrao', nome: 'Padrão do Windows' },
      { id: 'Google Chrome', nome: 'Google Chrome' },
      { id: 'Microsoft Edge', nome: 'Microsoft Edge' }
    ],
    executarScript: async (moduloId, etapaId, valores, navegadorId) => {
      const etapa = Object.values(manifestos).find((m) => m.id === moduloId)?.etapas.find((e) => e.id === etapaId)
      const token = etapa?.script?.tokens?.[0]
      const saidas: Record<string, Record<string, string>> = {
        'app-registration': { ClientId: '00000000-0000-4000-8000-000000000000' },
        paginas: { BibliotecaUrl: `${(valores.SiteUrl ?? '').replace(/\/$/, '')}/SitePages/${valores.BibliotecaPageName}.aspx` },
        ambiente: { NomeAmbiente: 'Contoso Demo', EnvironmentId: '00000000-0000-4000-8000-0000000000aa' },
        'creator-kit': { VersaoCreatorKit: '1.0.20250310.1' },
        'agent-kit': { VersaoAgentKit: '20261030.2' },
        // Simula um tenant que ja esta com o roteamento ligado para todos
        tenant: {
          Conta: 'admin@contoso.onmicrosoft.com',
          TenantId: '00000000-0000-4000-8000-0000000000bb',
          RoteamentoAntes: 'Ligado, para makers novos e existentes',
          EstadoAtual: 'Ligado, para makers novos e existentes',
          QuemRotear: 'todos'
        },
        ativar: { RoteamentoDepois: valores.QuemRotear === 'todos' ? 'Ligado, para makers novos e existentes' : 'Ligado, só para makers novos' }
      }
      return simular(
        saidas[etapaId] ?? {},
        token ? { proposito: token.proposito, navegador: navegadorId } : undefined,
        etapaId.endsWith('-kit')
      )
    },
    instalarModuloPs: async () => {
      pnpInstalado = true
      return simular({})
    },
    cancelarExecucao: async () => undefined,
    reabrirLogin: async (_id, navegadorId) => console.info('[simulador] reabrir login em', navegadorId),
    onEventoExecucao: (callback) => {
      ouvintes.add(callback)
      return () => ouvintes.delete(callback)
    },
    abrirArquivoDoModulo: async (_m, caminho) => console.info('[simulador] abrir arquivo', caminho),
    abrirLink: async (url) => void window.open(url, '_blank')
  }
}

export const api: ApiInstalador = window.bizapp ?? criarSimulador()
export const emSimulador = !window.bizapp
