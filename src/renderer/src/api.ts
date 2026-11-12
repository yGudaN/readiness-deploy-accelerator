import type { ApiInstalador, EventoExecucao, ModuloManifesto, StatusPreRequisito } from '@shared/tipos'

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
  let conta: { conta: string; tenantId: string } | null = null

  const simular = (saidas: Record<string, string>, login?: { proposito: string; navegador: string }, comProgresso = false): string => {
    const execucaoId = crypto.randomUUID()
    void (async () => {
      if (login) {
        await espera(300)
        emitir({ execucaoId, tipo: 'login', estado: 'aguardando', proposito: login.proposito, url: 'https://login.microsoftonline.com/simulador', navegador: login.navegador })
        emitir({ execucaoId, tipo: 'log', nivel: 'discreto', mensagem: `Login: ${login.proposito}. A página de login foi aberta no navegador.` })
        await espera(2500)
        conta = conta ?? { conta: 'admin@contoso.onmicrosoft.com', tenantId: '00000000-0000-4000-8000-0000000000bb' }
        emitir({ execucaoId, tipo: 'login', estado: 'concluido', proposito: login.proposito, conta: conta.conta })
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
      const modulo = (nome: string, minima: string, usadoPor: string[]): StatusPreRequisito => ({
        chave: `modulo-ps:${nome}`,
        rotulo: `Módulo ${nome} ${minima} ou superior`,
        linkOficial: `https://www.powershellgallery.com/packages/${nome}`,
        exigidoPor: usadoPor,
        ...(pnpInstalado
          ? { ok: true, versaoEncontrada: minima }
          : { ok: false, detalhe: 'Módulo não instalado.', acao: { tipo: 'instalar-modulo' as const, nome } })
      })
      return [
        { chave: 'pwsh', rotulo: 'PowerShell 7.4 ou superior', ok: true, versaoEncontrada: '7.6.0', exigidoPor: ['Biblioteca de Prompts e Skills'], linkOficial: 'https://learn.microsoft.com/pt-br/powershell/scripting/install/installing-powershell-on-windows' },
        modulo('PnP.PowerShell', '3.0', ['Biblioteca de Prompts e Skills']),
        modulo('Microsoft.Graph.Identity.SignIns', '2.41.2', ['MFA para o Copilot'])
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
        consultar: {
          Conta: 'admin@contoso.onmicrosoft.com',
          TenantId: '00000000-0000-4000-8000-0000000000bb',
          EstadoCopilotPremium: 'Não existe',
          EstadoCopilotGeral: 'Não existe',
          PastaEvidencias: 'C:\\Users\\voce\\Documents\\Readiness Deploy Accelerator\\evidencias\\Grupos-Copilot'
        },
        criar: { EstadoCopilotPremium: 'Existe (0 membro(s), 1 owner(s))', EstadoCopilotGeral: 'Existe (0 membro(s), 1 owner(s))' },
        ativar: { RoteamentoDepois: valores.QuemRotear === 'todos' ? 'Ligado, para makers novos e existentes' : 'Ligado, só para makers novos' }
      }
      // Etapas do item de MFA (ids repetidos com outros itens)
      const saidasMfa: Record<string, Record<string, string>> = {
        consultar: {
          Conta: 'admin@contoso.onmicrosoft.com',
          TenantId: '00000000-0000-4000-8000-0000000000bb',
          LicencaEntra: 'Encontrada',
          PadroesSeguranca: 'Desligados',
          EstadoPolitica: 'Não existe',
          PastaEvidencias: 'C:\\Users\\voce\\Documents\\Readiness Deploy Accelerator\\evidencias\\MFA-Copilot'
        },
        criar: { EstadoPolitica: 'Modo de relatório (não exige MFA, só registra)', PolicyId: '00000000-0000-4000-8000-0000000000dd' },
        estado: {
          EstadoPolitica:
            ({ habilitar: 'Ligada (exige MFA)', desabilitar: 'Desligada', excluir: 'Não existe' } as Record<string, string>)[valores.NovoEstado] ??
            'Modo de relatório (não exige MFA, só registra)'
        }
      }
      // Item do SharePoint: simula um tenant sem SharePoint Advanced Management
      const saidasSharePoint: Record<string, Record<string, string>> = {
        consultar: {
          Conta: 'admin@contoso.onmicrosoft.com',
          TenantId: '00000000-0000-4000-8000-0000000000bb',
          EnderecoSharePoint: 'https://contoso.sharepoint.com',
          CompartilhamentoTenant: 'Qualquer pessoa (links sem login e novos convidados)',
          SitesLidos: '14 sites · 3 com links para qualquer pessoa liberados',
          RecursoSam: 'Não encontrado (licença ou recurso)',
          ColetaAtividade: 'Não disponível',
          FuncaoSam: 'Não',
          PastaEvidencias: 'C:\Users\voce\Documents\Readiness Deploy Accelerator\evidencias\SharePoint-Compartilhamento'
        },
        site: { CompartilhamentoSite: 'Projetos · Somente convidados existentes' }
      }
      // Item de auditoria: auditoria ligada, sem politica do Copilot ainda
      const saidasAuditoria: Record<string, Record<string, string>> = {
        consultar: {
          Conta: 'admin@contoso.onmicrosoft.com',
          TenantId: '00000000-0000-4000-8000-0000000000bb',
          Auditoria: 'Ligada',
          LicencaAuditoria: 'Encontrada',
          PoliticaCopilot: 'Não existe',
          PoliticasRetencao: '0',
          EventosCopilot: `0 nos últimos ${valores.DiasPesquisa ?? '7'} dias`,
          PastaEvidencias: 'C:\\Users\\voce\\Documents\\Readiness Deploy Accelerator\\evidencias\\Auditoria-Copilot'
        },
        auditoria: { Auditoria: valores.AcaoAuditoria === 'desligar' ? 'Desligada' : 'Ligada' },
        retencao: valores.AcaoRetencao === 'remover'
          ? { PoliticaCopilot: 'Não existe', PoliticasRetencao: '0' }
          : { PoliticaCopilot: `${({ ThreeMonths: '3 meses', SixMonths: '6 meses', NineMonths: '9 meses', TwelveMonths: '12 meses', TenYears: '10 anos' } as Record<string, string>)[valores.DuracaoRetencao] ?? '12 meses'} · prioridade ${valores.Prioridade ?? '100'}`, PoliticasRetencao: '1' }
      }
      const porModulo: Record<string, Record<string, Record<string, string>>> = {
        'mfa-copilot': saidasMfa,
        'sharepoint-compartilhamento': saidasSharePoint,
        'auditoria-copilot': saidasAuditoria,
        'descoberta-restrita': {
          consultar: {
            Conta: 'admin@contoso.onmicrosoft.com',
            TenantId: '00000000-0000-4000-8000-0000000000bb',
            EnderecoSharePoint: 'https://contoso.sharepoint.com',
            SitesRcd: '13 sites · 0 com descoberta restrita',
            SitesRestritos: 'Nenhum',
            LicencaSam: 'Não encontrada',
            PastaEvidencias: 'C:\\Users\\voce\\Documents\\Readiness Deploy Accelerator\\evidencias\\Descoberta-Restrita'
          },
          site: {
            EstadoSite: valores.AcaoRcd === 'desligar'
              ? 'Projetos · Desligada (aparece normalmente na pesquisa e no Copilot)'
              : 'Projetos · Ligada (fora da pesquisa da organização e do Copilot)'
          }
        },
        'modelo-protecao': {
          consultar: {
            Conta: 'admin@contoso.onmicrosoft.com',
            TenantId: '00000000-0000-4000-8000-0000000000bb',
            LicencaEntra: 'Encontrada',
            Purview: 'Conectado',
            EstadoDlpPowerPlatform: 'Não existe',
            EstadoAcessoCondicional: 'Não existe',
            EstadoDlpPurview: 'Não existe',
            EstadoRotulo: 'Não existe',
            PastaEvidencias: 'C:\\Users\\voce\\Documents\\Readiness Deploy Accelerator\\evidencias\\Modelo-Protecao'
          },
          criar: {
            EstadoDlpPowerPlatform: 'Existe (todos os ambientes)',
            EstadoAcessoCondicional: 'Modo de relatório (não exige MFA)',
            EstadoDlpPurview: 'Em teste (sem notificações)',
            EstadoRotulo: 'Criado e publicado para a conta admin'
          },
          estado: valores.AcaoModelo === 'remover'
            ? { EstadoDlpPowerPlatform: 'Não existe', EstadoAcessoCondicional: 'Não existe', EstadoDlpPurview: 'Não existe', EstadoRotulo: 'Não existe' }
            : valores.AcaoModelo === 'ligar'
              ? { EstadoAcessoCondicional: 'Ligada (exige MFA da conta admin)', EstadoDlpPurview: 'Ligada', EstadoRotulo: 'Criado e publicado para a conta admin' }
              : { EstadoAcessoCondicional: 'Desligada', EstadoDlpPurview: 'Desligada', EstadoRotulo: 'Criado, não publicado' }
        },
        'alertas-atividade': {
          consultar: {
            Conta: 'admin@contoso.onmicrosoft.com',
            TenantId: '00000000-0000-4000-8000-0000000000bb',
            LicencaAlertas: 'Encontrada',
            PoliticasAlerta: '34 (2 personalizadas)',
            AlertasDoItem: 'Nenhuma',
            PastaEvidencias: 'C:\\Users\\voce\\Documents\\Readiness Deploy Accelerator\\evidencias\\Alertas-Atividade'
          },
          criar: {
            EstadoAlerta: valores.TipoAlerta === 'simples'
              ? `Ligada · volume (${valores.Limite ?? '50'} em ${valores.Janela ?? '120'} min)`
              : 'Ligada · atividade incomum'
          },
          estado: {
            EstadoAlerta: ({ desligar: 'Desligada · atividade incomum', ligar: 'Ligada · atividade incomum', remover: 'Não existe' } as Record<string, string>)[valores.NovoEstado] ?? ''
          }
        }
      }
      return simular(
        (porModulo[moduloId] ?? saidas)[etapaId] ?? {},
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
    abrirEvidencias: async (caminho) => console.info('[simulador] abrir evidencias', caminho),
    contaAtual: async () => conta,
    trocarConta: async () => { conta = null },
    entrarComOutraConta: async () => {
      await espera(2000)
      conta = { conta: 'outra.conta@fabrikam.onmicrosoft.com', tenantId: '00000000-0000-4000-8000-0000000000cc' }
      return { pendente: false, conta }
    },
    cancelarLogin: async () => undefined,
    abrirLink: async (url) => void window.open(url, '_blank')
  }
}

export const api: ApiInstalador = window.bizapp ?? criarSimulador()
export const emSimulador = !window.bizapp
