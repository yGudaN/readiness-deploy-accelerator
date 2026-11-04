// Contrato entre o manifesto dos modulos (modules/<id>/module.json),
// o processo principal (Electron) e a interface (React).

/** Requisito de maquina declarado por um modulo. */
export type PreRequisito =
  | { tipo: 'pwsh'; versaoMinima: string }
  | { tipo: 'modulo-ps'; nome: string; versaoMinima?: string; instalavel?: boolean }

export type TipoCampo = 'texto' | 'url' | 'guid'

export interface CampoDef {
  id: string
  rotulo: string
  tipo: TipoCampo
  obrigatorio?: boolean
  /** Valor inicial. Aceita {{OutroCampo}} para reaproveitar valores ja preenchidos. */
  padrao?: string
  placeholder?: string
  ajuda?: string
  /** Regex extra de validacao (alem da validacao do tipo). */
  padraoRegex?: string
  mensagemRegex?: string
}

export interface ArquivoDef {
  rotulo: string
  /** Caminho relativo a pasta do modulo. */
  caminho: string
}

export interface LinkDef {
  rotulo: string
  /** URL https. Aceita {{Campo}}. */
  url: string
}

/**
 * Token de acesso que o instalador obtem (login no navegador escolhido) antes de rodar o script.
 * O script recebe o token em $entrada.Tokens.<nome>.
 */
export interface TokenDef {
  nome: string
  /** GUID do app (aceita {{Campo}}) ou um cliente conhecido: "@azure-powershell". */
  clientId: string
  /** Tenant do login, ex.: "{{Tenant}}.onmicrosoft.com". */
  tenant: string
  /** Escopo OAuth, ex.: "https://graph.microsoft.com/.default". Aceita {{Campo}}. */
  escopo: string
  /** Frase curta mostrada na tela de login: para que serve este acesso. */
  proposito: string
}

export interface ScriptDef {
  /** Caminho relativo a pasta do modulo. */
  arquivo: string
  rotuloBotao: string
  /** Se true, a etapa so avanca depois de o script rodar com sucesso. */
  obrigatorio: boolean
  /** Ids dos campos enviados ao script. Se omitido, envia todos os valores do modulo. */
  entradas?: string[]
  tokens?: TokenDef[]
}

export interface EtapaDef {
  id: string
  titulo: string
  descricao?: string
  /** Passo a passo exibido em lista numerada. Aceita {{Campo}}. */
  instrucoes?: string[]
  campos?: CampoDef[]
  arquivos?: ArquivoDef[]
  links?: LinkDef[]
  /** Texto da caixa de confirmacao obrigatoria (para passos manuais). */
  confirmacao?: string
  script?: ScriptDef
}

export interface ItemResumoDef {
  rotulo: string
  /** Aceita {{Campo}}. Itens que resolvem para vazio sao omitidos. */
  valor: string
}

export interface ModuloManifesto {
  id: string
  nome: string
  versao: string
  resumo: string
  descricao: string
  tempoEstimadoMin?: number
  /** Papeis administrativos que quem instala precisa ter. */
  papeisNecessarios?: string[]
  preRequisitos: PreRequisito[]
  etapas: EtapaDef[]
  resumoFinal?: { itens?: ItemResumoDef[]; links?: LinkDef[] }
}

/** Resultado da verificacao de um requisito na maquina. */
export interface StatusPreRequisito {
  chave: string
  rotulo: string
  ok: boolean
  versaoEncontrada?: string
  detalhe?: string
  /** Acao sugerida quando nao ok. */
  acao?: { tipo: 'instalar-modulo'; nome: string } | { tipo: 'abrir-link'; url: string }
  /** Nomes dos modulos do catalogo que exigem este requisito. */
  exigidoPor: string[]
}

export type NivelLog = 'info' | 'sucesso' | 'aviso' | 'erro' | 'discreto'

/** Eventos enviados pelo processo principal durante a execucao de um script. */
export type EventoExecucao =
  | { execucaoId: string; tipo: 'log'; nivel: NivelLog; mensagem: string }
  | { execucaoId: string; tipo: 'saida'; nome: string; valor: string }
  | { execucaoId: string; tipo: 'login'; estado: 'aguardando'; proposito: string; url: string; navegador: string }
  | { execucaoId: string; tipo: 'login'; estado: 'concluido'; proposito: string; conta?: string }
  | { execucaoId: string; tipo: 'fim'; sucesso: boolean; codigo: number | null; saidas: Record<string, string> }

export interface Navegador {
  id: string
  nome: string
}

export interface ApiInstalador {
  versaoApp(): Promise<string>
  listarModulos(): Promise<ModuloManifesto[]>
  verificarPreRequisitos(): Promise<StatusPreRequisito[]>
  /** O primeiro item e sempre o navegador padrao do Windows (id "padrao"). */
  listarNavegadores(): Promise<Navegador[]>
  /** Retorna o id da execucao; acompanhe por onEventoExecucao. Logins abrem no navegador informado. */
  executarScript(moduloId: string, etapaId: string, valores: Record<string, string>, navegadorId: string): Promise<string>
  instalarModuloPs(nome: string): Promise<string>
  cancelarExecucao(execucaoId: string): Promise<void>
  /** Abre de novo a pagina de login pendente de uma execucao, no navegador informado. */
  reabrirLogin(execucaoId: string, navegadorId: string): Promise<void>
  onEventoExecucao(callback: (evento: EventoExecucao) => void): () => void
  abrirArquivoDoModulo(moduloId: string, caminho: string): Promise<void>
  abrirLink(url: string, navegadorId: string): Promise<void>
}
