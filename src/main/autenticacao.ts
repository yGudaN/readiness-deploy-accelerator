import { createHash, randomBytes } from 'node:crypto'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { SIMBOLO_BIZAPP_BRANCO_PNG } from './simboloBizapp'

/**
 * Login Microsoft (Entra ID) feito pelo proprio instalador: fluxo authorization code + PKCE
 * de cliente publico, com retorno em http://localhost:<porta>. Assim a pagina de login abre
 * no navegador que a pessoa escolher, e um mesmo login serve para varias etapas
 * (o refresh token fica so na memoria deste processo e some ao fechar o app).
 */

/** Clientes publicos conhecidos, usados antes de o app do cliente existir. */
const CLIENTES_CONHECIDOS: Record<string, string> = {
  // Mesmo app que o PnP.PowerShell usa para registrar apps (Microsoft Azure PowerShell)
  '@azure-powershell': '1950a258-227b-4e31-a9cf-717495945fc2',
  // App publico do Power Platform CLI (pac), feito para acessar o Dataverse
  '@power-platform-cli': '9cee029c-6210-4654-90bb-17e6e9d36617',
  // Microsoft Graph Command Line Tools: o mesmo do Connect-MgGraph usado nos scripts validados
  '@graph-cli': '14d82eec-204b-4c2f-b7e8-296a70dab67e',
  // Exchange Online PowerShell (Connect-ExchangeOnline / Connect-IPPSSession): o mesmo app que o
  // modulo usa no login pelo navegador (-DisableWAM), que retorna em http://localhost
  '@exchange-online': 'fb78d390-0c51-40cd-8e17-fdbfab77341b'
}

/** Tenants genericos: a conta e escolhida no login, entao nao ha "ultima conta" para sugerir. */
const TENANTS_GENERICOS = new Set(['organizations', 'common'])

const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const TENANT = /^[a-z0-9][a-z0-9.-]*$/i
const ESCOPO = /^[\w:/.\-\s]+$/
const TEMPO_LIMITE_MS = 10 * 60_000

export interface PedidoToken {
  tenant: string
  clientId: string
  escopo: string
  proposito: string
}

export interface ContextoLogin {
  navegadorId: string
  sinal: AbortSignal
  log: (nivel: 'info' | 'sucesso' | 'aviso' | 'erro' | 'discreto', mensagem: string) => void
  abrirNoNavegador: (navegadorId: string, url: string) => Promise<void>
  /** Avisa a tela de que ha um login aberto (url) ou concluido (conta). */
  aoAguardar: (url: string) => void
  aoConcluir: (conta?: string) => void
}

interface Sessao {
  refreshToken: string
  conta?: string
  tenantId?: string
  clientId: string
  obtidoEm: number
}

export interface ContaAtiva {
  conta: string
  tenantId: string
}

const tokens = new Map<string, { valor: string; expiraEm: number; obtidoEm: number }>()
const sessoes = new Map<string, Sessao>()
/** Ultima conta usada em cada tenant: evita escolher a conta de novo no proximo login. */
const contaPorTenant = new Map<string, string>()
/** Conta do ultimo login: os proximos itens a reaproveitam ("manter a mesma conta"). */
let contaAtiva: ContaAtiva | null = null
/** Logins e tokens obtidos antes deste momento sao ignorados ("trocar de conta"). */
let marco = 0

export function contaAtual(): ContaAtiva | null {
  return contaAtiva
}

/** Esquece a conta atual: o proximo login pede para escolher a conta, sem reaproveitar nada. */
export function trocarConta(): void {
  marco = Date.now()
  contaAtiva = null
}

const base64url = (b: Buffer): string => b.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

export function resolverClientId(clientId: string): string {
  return CLIENTES_CONHECIDOS[clientId] ?? clientId
}

function validar(p: PedidoToken): void {
  if (!TENANT.test(p.tenant)) throw new Error(`Tenant inválido para login: "${p.tenant}".`)
  if (!GUID.test(p.clientId)) throw new Error(`Client ID inválido para login: "${p.clientId}".`)
  if (!ESCOPO.test(p.escopo)) throw new Error(`Escopo inválido: "${p.escopo}".`)
}

function identidadeDoIdToken(idToken?: string): { conta?: string; tenantId?: string } {
  if (!idToken) return {}
  try {
    const payload = JSON.parse(Buffer.from(idToken.split('.')[1], 'base64url').toString('utf8'))
    return { conta: payload.preferred_username ?? payload.upn ?? payload.email, tenantId: payload.tid }
  } catch {
    return {}
  }
}

/** Traduz os erros mais comuns do Entra ID para orientacoes. */
export function mensagemDeErro(codigo: string, descricao = ''): string {
  const texto = `${codigo} ${descricao}`
  if (/AADSTS90094|AADSTS90099|admin.?approval|aprova/i.test(texto)) {
    return 'O app precisa da aprovação de um administrador. Se você enviou o pedido de aprovação, aguarde o administrador aprovar e tente de novo.'
  }
  if (/AADSTS65001|consent_required/i.test(texto)) {
    return 'As permissões do app ainda não foram aprovadas por um administrador do tenant.'
  }
  if (/AADSTS65004|declined/i.test(texto)) return 'O consentimento foi recusado na tela de login.'
  if (/AADSTS700016/i.test(texto)) return 'O Client ID não foi encontrado neste tenant. Confira o valor informado.'
  if (/AADSTS50020|AADSTS50034|AADSTS90072/i.test(texto)) return 'A conta usada no login não pertence a este tenant. Entre com uma conta do tenant informado.'
  if (/AADSTS90002|AADSTS900023/i.test(texto)) return 'Tenant não encontrado. Confira o nome do tenant.'
  if (/AADSTS53003/i.test(texto)) return 'O login foi bloqueado por uma política de Acesso Condicional do tenant.'
  return `Falha no login: ${descricao || codigo}`
}

interface RespostaToken {
  access_token: string
  refresh_token?: string
  expires_in: number
  id_token?: string
  error?: string
  error_description?: string
}

async function chamarToken(tenant: string, corpo: Record<string, string>): Promise<RespostaToken> {
  const resposta = await fetch(`https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(corpo)
  })
  const json = (await resposta.json()) as RespostaToken
  if (!resposta.ok) {
    throw Object.assign(new Error(mensagemDeErro(json.error ?? 'erro', json.error_description)), { codigo: json.error, descricao: json.error_description })
  }
  return json
}

function guardar(chaveSessao: string, chaveToken: string, r: RespostaToken, p: PedidoToken): string | undefined {
  const agora = Date.now()
  tokens.set(chaveToken, { valor: r.access_token, expiraEm: agora + (r.expires_in - 300) * 1000, obtidoEm: agora })
  const id = identidadeDoIdToken(r.id_token)
  const anterior = sessoes.get(chaveSessao)
  const conta = id.conta ?? anterior?.conta
  const tenantId = id.tenantId ?? anterior?.tenantId
  if (r.refresh_token) sessoes.set(chaveSessao, { refreshToken: r.refresh_token, conta, tenantId, clientId: p.clientId, obtidoEm: agora })
  if (conta) contaPorTenant.set(p.tenant.toLowerCase(), conta)
  if (conta && tenantId) contaAtiva = { conta, tenantId }
  return conta
}

/** Sugestao de conta para o login: a ultima usada neste tenant ou, sem ela, a conta ativa. */
function contaSugerida(p: PedidoToken): string | undefined {
  const tenant = p.tenant.toLowerCase()
  if (TENANTS_GENERICOS.has(tenant)) return contaAtiva?.conta
  const doTenant = contaPorTenant.get(tenant)
  if (doTenant) return doTenant
  // Tenant informado pelo dominio (ex.: empresa.onmicrosoft.com): so sugere se a conta for desse dominio
  return contaAtiva && contaAtiva.conta.toLowerCase().endsWith(`@${tenant}`) ? contaAtiva.conta : undefined
}

const PAGINA_RETORNO = (titulo: string, texto: string): string => `<!doctype html><html lang="pt-BR"><meta charset="utf-8"><title>Readiness Deploy Accelerator</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#06010a;color:#fff;font-family:Inter,'Segoe UI',Arial,sans-serif;letter-spacing:-.02em}
main{max-width:460px;padding:40px;border-radius:20px;background:#141018;text-align:center}h1{font-weight:600;letter-spacing:-.04em;margin:0 0 12px}
p{color:rgba(255,255,255,.75);margin:0}.marca{display:inline-grid;place-items:center;width:44px;height:44px;border-radius:50%;background:linear-gradient(135deg,#8034ae,#cb61e8);margin-bottom:20px}
.marca img{width:20px;height:auto;display:block}</style>
<main><span class="marca"><img src="data:image/png;base64,${SIMBOLO_BIZAPP_BRANCO_PNG}" alt="Bizapp"></span><h1>${titulo}</h1><p>${texto}</p></main></html>`

/** Servidor local que recebe o redirecionamento do login (127.0.0.1 e ::1, porta livre). */
async function iniciarRetorno(estado: string): Promise<{ porta: number; resultado: Promise<URLSearchParams>; fechar: () => void }> {
  let resolver!: (p: URLSearchParams) => void
  const resultado = new Promise<URLSearchParams>((r) => (resolver = r))
  const tratar: Parameters<typeof createServer>[1] = (req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost')
    const params = url.searchParams
    if (url.pathname !== '/' || params.get('state') !== estado) {
      res.writeHead(404).end()
      return
    }
    const ok = params.has('code')
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
    res.end(ok
      ? PAGINA_RETORNO('Login concluído', 'Pode fechar esta aba e voltar para o Readiness Deploy Accelerator.')
      : PAGINA_RETORNO('Login não concluído', 'Volte para o Readiness Deploy Accelerator para ver os detalhes.'))
    resolver(params)
  }

  const servidores: Server[] = []
  const escutar = (s: Server, host: string, porta: number): Promise<number> =>
    new Promise((ok, falha) => {
      s.once('error', falha)
      s.listen(porta, host, () => ok((s.address() as AddressInfo).port))
    })

  const v4 = createServer(tratar)
  const porta = await escutar(v4, '127.0.0.1', 0)
  servidores.push(v4)
  // Alguns navegadores resolvem "localhost" para ::1 primeiro
  const v6 = createServer(tratar)
  await escutar(v6, '::1', porta).then(() => servidores.push(v6)).catch(() => undefined)

  return { porta, resultado, fechar: () => servidores.forEach((s) => s.close()) }
}

async function loginInterativo(p: PedidoToken, ctx: ContextoLogin): Promise<RespostaToken> {
  const verificador = base64url(randomBytes(32))
  const desafio = base64url(createHash('sha256').update(verificador).digest())
  const estado = base64url(randomBytes(16))
  const retorno = await iniciarRetorno(estado)
  const redirectUri = `http://localhost:${retorno.porta}`
  const escopo = `${p.escopo} offline_access openid profile`
  // Com uma conta ativa, o navegador ja recebe a sugestao e costuma concluir sozinho;
  // sem ela (inicio ou "trocar de conta"), a pessoa escolhe a conta.
  const conta = contaSugerida(p)
  const autoridade = TENANTS_GENERICOS.has(p.tenant.toLowerCase()) && conta && contaAtiva ? contaAtiva.tenantId : p.tenant

  const url = new URL(`https://login.microsoftonline.com/${autoridade}/oauth2/v2.0/authorize`)
  url.search = new URLSearchParams({
    client_id: p.clientId,
    response_type: 'code',
    response_mode: 'query',
    redirect_uri: redirectUri,
    scope: escopo,
    state: estado,
    code_challenge: desafio,
    code_challenge_method: 'S256',
    ...(conta ? { login_hint: conta } : { prompt: 'select_account' })
  }).toString()

  try {
    ctx.log('discreto', `Login: ${p.proposito}. A página de login foi aberta no navegador.`)
    await ctx.abrirNoNavegador(ctx.navegadorId, url.toString())
    ctx.aoAguardar(url.toString())

    const params = await new Promise<URLSearchParams>((ok, falha) => {
      const limite = setTimeout(() => falha(new Error('O login não foi concluído em 10 minutos.')), TEMPO_LIMITE_MS)
      ctx.sinal.addEventListener('abort', () => falha(new Error('Login cancelado.')), { once: true })
      retorno.resultado.then(ok, falha).finally(() => clearTimeout(limite))
    })
    if (!params.has('code')) {
      throw new Error(mensagemDeErro(params.get('error') ?? 'erro', params.get('error_description') ?? ''))
    }
    return await chamarToken(autoridade, {
      client_id: p.clientId,
      grant_type: 'authorization_code',
      code: params.get('code')!,
      redirect_uri: redirectUri,
      code_verifier: verificador,
      scope: escopo
    })
  } finally {
    retorno.fechar()
  }
}

/** Devolve um access token valido: do cache, renovando com o refresh token ou com login no navegador. */
export async function obterToken(pedido: PedidoToken, ctx: ContextoLogin): Promise<string> {
  const p = { ...pedido, clientId: resolverClientId(pedido.clientId) }
  validar(p)
  const chaveSessao = `${p.tenant.toLowerCase()}|${p.clientId.toLowerCase()}`
  const chaveToken = `${chaveSessao}|${p.escopo}`

  const emCache = tokens.get(chaveToken)
  if (emCache && emCache.expiraEm > Date.now() && emCache.obtidoEm >= marco) return emCache.valor

  const escopo = `${p.escopo} offline_access openid profile`
  const renovar = async (s: Sessao, autoridade: string): Promise<RespostaToken | null> => {
    try {
      return await chamarToken(autoridade, { client_id: p.clientId, grant_type: 'refresh_token', refresh_token: s.refreshToken, scope: escopo })
    } catch {
      return null // recusado (ex.: falta consentimento para o novo escopo)
    }
  }

  // 1) Mesmo app: renova com o login que ja existe
  const sessao = sessoes.get(chaveSessao)
  if (sessao && sessao.obtidoEm >= marco) {
    const r = await renovar(sessao, p.tenant)
    if (r) {
      const conta = guardar(chaveSessao, chaveToken, r, p)
      ctx.log('discreto', `Login reaproveitado${conta ? ` (${conta})` : ''}.`)
      return r.access_token
    }
  }

  // 2) Outro app da Microsoft com a mesma conta: alguns apps publicos da Microsoft aceitam o
  //    login uns dos outros. Se o Entra ID recusar, segue para o login no navegador.
  if (contaAtiva) {
    const generico = TENANTS_GENERICOS.has(p.tenant.toLowerCase())
    const candidatas = [...sessoes.values()].filter((s) =>
      s.clientId !== p.clientId && s.obtidoEm >= marco && s.conta === contaAtiva!.conta && s.tenantId === contaAtiva!.tenantId)
    for (const s of candidatas) {
      const r = await renovar(s, generico ? s.tenantId! : p.tenant)
      if (r) {
        const conta = guardar(chaveSessao, chaveToken, r, p)
        ctx.log('discreto', `Login reaproveitado de outro item${conta ? ` (${conta})` : ''}.`)
        return r.access_token
      }
    }
  }

  // 3) Login no navegador (com a conta ativa ja sugerida, quando houver)
  const r = await loginInterativo(p, ctx)
  const conta = guardar(chaveSessao, chaveToken, r, p)
  ctx.aoConcluir(conta)
  ctx.log('sucesso', `Login concluído${conta ? ` como ${conta}` : ''}.`)
  return r.access_token
}

/** Troca de conta e ja faz o login novo (botao "Fazer login" da tela entre itens). */
export async function entrarComOutraConta(pedido: PedidoToken, ctx: ContextoLogin): Promise<ContaAtiva | null> {
  trocarConta()
  await obterToken(pedido, ctx)
  return contaAtiva
}
