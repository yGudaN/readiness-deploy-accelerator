// Contrato entre o manifesto dos modulos (modules/<id>/module.json),
// o processo principal (Electron) e a interface (React).

/** Requisito de maquina declarado por um modulo. */
export type PreRequisito =
  | { tipo: 'pwsh'; versaoMinima: string }
  | { tipo: 'modulo-ps'; nome: string; versaoMinima?: string; instalavel?: boolean }

export type TipoCampo = 'texto' | 'url' | 'guid' | 'escolha'

/** Opcao de um campo do tipo "escolha" (mostrado como lista de opcoes, uma selecionada). */
export interface OpcaoCampo {
  valor: string
  rotulo: string
  descricao?: string
}

export interface CampoDef {
  id: string
  rotulo: string
  tipo: TipoCampo
  /** Obrigatorio quando tipo = "escolha". */
  opcoes?: OpcaoCampo[]
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

/** Linha do quadro "situacao atual" de uma etapa. */
export interface ItemSituacaoDef {
  /** Aceita {{Campo}}. */
  rotulo: string
  /** Aceita {{Campo}}. Se ficar vazio, a linha nao aparece. */
  valor: string
  /** Valores (inicio do texto, sem diferenciar maiusculas) mostrados como OK. */
  okQuando?: string[]
  /** Valores (inicio do texto) mostrados como alerta. */
  alertaQuando?: string[]
}

/** Quadro com o estado atual do tenant, uma informacao por linha. */
export interface SituacaoDef {
  /** Padrao: "Situação atual". */
  titulo?: string
  itens: ItemSituacaoDef[]
  /** Frase curta abaixo das linhas. Aceita {{Campo}}. */
  nota?: string
}

export interface EtapaDef {
  id: string
  titulo: string
  /** Aceita {{Campo}}. */
  descricao?: string
  /** Destaque logo abaixo da descricao (ex.: estado atual). Aceita {{Campo}}; se ficar vazio, nao aparece. */
  aviso?: string
  /** Estado atual em linhas (rotulo: valor). Preferivel ao aviso quando ha mais de uma informacao. */
  situacao?: SituacaoDef
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

/** Outro item do catalogo do qual este depende (ex.: os grupos que a politica usa). */
export interface DependenciaDef {
  /** id do item do catalogo. */
  id: string
  /** O que este item precisa que o outro cria (ex.: "os grupos Copilot-Premium e Copilot-Geral"). */
  precisaDe: string
  /** Dica para quem nao sabe se ja tem (aparece no aviso ao marcar o item). */
  dica?: string
}

/** Grupos do catalogo, na ordem do checklist do COE (os mesmos nomes). */
export const CATEGORIAS = [
  'Habilitação',
  'Comunidade',
  'Experiência',
  'Medição',
  'Monitoramento',
  'Acessos',
  'Custos e consumo (FinOps)',
  'Segurança e conformidade',
  'Agentes e ALM'
] as const
export type Categoria = (typeof CATEGORIAS)[number]

export interface ModuloManifesto {
  id: string
  nome: string
  versao: string
  resumo: string
  /** Grupo do item no catalogo (uma das CATEGORIAS, na ordem em que aparecem). */
  categoria?: Categoria
  /** O que e e para que serve (aparece ao expandir o item no catalogo). */
  descricao: string
  /** O que sera criado ou instalado no tenant, um item por linha. */
  oQueInstala?: string[]
  tempoEstimadoMin?: number
  /** Papeis administrativos que quem instala precisa ter. */
  papeisNecessarios?: string[]
  preRequisitos: PreRequisito[]
  /** Itens do catalogo que precisam existir antes (aviso no catalogo; a validacao real fica no script). */
  dependeDe?: DependenciaDef[]
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
  /** Pagina oficial do requisito (para baixar/instalar por conta propria). */
  linkOficial?: string
}

export type NivelLog = 'info' | 'sucesso' | 'aviso' | 'erro' | 'discreto'

/** Eventos enviados pelo processo principal durante a execucao de um script. */
export type EventoExecucao =
  | { execucaoId: string; tipo: 'log'; nivel: NivelLog; mensagem: string }
  | { execucaoId: string; tipo: 'saida'; nome: string; valor: string }
  | { execucaoId: string; tipo: 'login'; estado: 'aguardando'; proposito: string; url: string; navegador: string }
  | { execucaoId: string; tipo: 'login'; estado: 'concluido'; proposito: string; conta?: string }
  /** Progresso de uma operacao longa (ex.: importacao de solucao). percentual de 0 a 100. */
  | { execucaoId: string; tipo: 'progresso'; percentual: number; fase: string }
  | { execucaoId: string; tipo: 'fim'; sucesso: boolean; codigo: number | null; saidas: Record<string, string> }

export interface Navegador {
  id: string
  nome: string
}

export interface ContaLogin {
  conta: string
  tenantId: string
}

export interface ApiInstalador {
  versaoApp(): Promise<string>
  listarModulos(): Promise<ModuloManifesto[]>
  verificarPreRequisitos(): Promise<StatusPreRequisito[]>
  /** O primeiro item e sempre o navegador padrao do Windows (id "padrao"). */
  listarNavegadores(): Promise<Navegador[]>
  /** Retorna o id da execucao; acompanhe por onEventoExecucao. Logins abrem no navegador informado. */
  executarScript(moduloId: string, etapaId: string, valores: Record<string, string>, navegadorId: string): Promise<string>
  /** Instala um ou mais modulos PowerShell (em sequencia, numa unica execucao). */
  instalarModuloPs(nomes: string[]): Promise<string>
  cancelarExecucao(execucaoId: string): Promise<void>
  /** Abre de novo a pagina de login pendente de uma execucao, no navegador informado. */
  reabrirLogin(execucaoId: string, navegadorId: string): Promise<void>
  onEventoExecucao(callback: (evento: EventoExecucao) => void): () => void
  abrirArquivoDoModulo(moduloId: string, caminho: string): Promise<void>
  /** Abre no Explorer uma pasta de evidencias gravada pelos scripts (saida PastaEvidencias). */
  abrirEvidencias(caminho: string): Promise<void>
  /** Conta do ultimo login (reaproveitada pelos proximos itens), ou null. */
  contaAtual(): Promise<ContaLogin | null>
  /** Esquece a conta atual: o proximo login pede para escolher a conta. */
  trocarConta(): Promise<void>
  /**
   * Troca de conta e ja faz o login do item no navegador informado. pendente = true quando o
   * login depende de dados da primeira etapa e vai acontecer nela.
   */
  entrarComOutraConta(moduloId: string, navegadorId: string): Promise<{ pendente: boolean; conta?: ContaLogin | null }>
  cancelarLogin(): Promise<void>
  abrirLink(url: string, navegadorId: string): Promise<void>
}
