import type { ContaLogin, ModuloManifesto } from '@shared/tipos'
import { Seletor } from '../componentes/Seletor'
import { useNavegador } from '../navegador'

export type EscolhaConta = 'manter' | 'trocar'

export interface EstadoLoginConta {
  estado: 'aguardando' | 'ok' | 'pendente' | 'erro'
  conta?: string
  erro?: string
}

interface Props {
  modulo: ModuloManifesto
  /** Conta do ultimo login nesta sessao (null se ainda nao houve login). */
  conta: ContaLogin | null
  escolha: EscolhaConta
  naoPerguntar: boolean
  login?: EstadoLoginConta
  onEscolha: (e: EscolhaConta) => void
  onNaoPerguntar: (v: boolean) => void
  onEscolherNavegador: (id: string) => void
  onEntrar: () => void
  onCancelarLogin: () => void
}

/**
 * Tela entre itens: continuar com a mesma conta (o login e reaproveitado) ou trocar de
 * conta/tenant, escolhendo o navegador antes de fazer o login novo.
 */
export function TelaConta(p: Props) {
  const { atual: navegador, lista } = useNavegador()
  const aguardando = p.login?.estado === 'aguardando'
  const opcoes: { valor: EscolhaConta; rotulo: string; descricao: string }[] = [
    {
      valor: 'manter',
      rotulo: p.conta ? 'Manter a mesma conta' : 'Usar a conta do próximo login',
      descricao: p.conta
        ? `Continua com ${p.conta.conta} (tenant ${p.conta.tenantId}). O login é reaproveitado.`
        : 'Ainda não há uma conta conectada nesta sessão.'
    },
    {
      valor: 'trocar',
      rotulo: 'Trocar de conta ou tenant',
      descricao: 'Para instalar este item com outra conta ou em outro tenant.'
    }
  ]

  return (
    <>
      <div className="sobretitulo">{p.modulo.nome}</div>
      <h1 className="titulo-tela">Qual conta usar?</h1>
      <p className="descricao-tela">Escolha com qual conta este item vai ser instalado.</p>

      <fieldset className="campo campo--escolha" disabled={aguardando}>
        <legend className="visualmente-oculto">Conta para este item</legend>
        <div className="opcoes">
          {opcoes.map((o) => (
            <label key={o.valor} className={`opcao${p.escolha === o.valor ? ' opcao--marcada' : ''}`}>
              <input type="radio" name="escolha-conta" checked={p.escolha === o.valor} onChange={() => p.onEscolha(o.valor)} />
              <span className="opcao__marca" aria-hidden="true" />
              <span>
                <span className="opcao__rotulo">{o.rotulo}</span>
                <span className="opcao__descricao">{o.descricao}</span>
              </span>
            </label>
          ))}
        </div>
      </fieldset>

      {p.escolha === 'trocar' && (
        <div className="cartao trocar-conta">
          <div className="trocar-conta__linha">
            <span>Fazer o login no</span>
            <Seletor rotulo="Navegador para o login" opcoes={lista} valor={navegador} onEscolher={p.onEscolherNavegador} />
            {aguardando ? (
              <button className="botao botao--texto" onClick={p.onCancelarLogin}>
                Cancelar
              </button>
            ) : (
              <button className="botao botao--primario" onClick={p.onEntrar}>
                Fazer login
              </button>
            )}
          </div>
          {aguardando && (
            <div className="trocar-conta__estado">
              <span className="girando" /> Faça o login no navegador e volte para cá.
            </div>
          )}
          {p.login?.estado === 'ok' && <div className="trocar-conta__estado trocar-conta__estado--ok">✓ Conectado como {p.login.conta}</div>}
          {p.login?.estado === 'pendente' && (
            <div className="trocar-conta__estado">Este item pede alguns dados antes do login: a escolha da conta vai aparecer na primeira etapa.</div>
          )}
          {p.login?.estado === 'erro' && <div className="trocar-conta__estado trocar-conta__estado--erro">✕ {p.login.erro}</div>}
          {!p.login && <div className="trocar-conta__estado">Se preferir, avance: a escolha da conta aparece no primeiro login deste item.</div>}
        </div>
      )}

      <label className="confirmacao-simples">
        <input type="checkbox" checked={p.naoPerguntar} onChange={(e) => p.onNaoPerguntar(e.target.checked)} />
        <span>Não perguntar novamente nesta sessão (os próximos itens mantêm a mesma conta)</span>
      </label>
    </>
  )
}
