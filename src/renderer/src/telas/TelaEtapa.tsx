import { aplicarModelo } from '@shared/modelo'
import type { EtapaDef, ModuloManifesto } from '@shared/tipos'
import { api } from '../api'
import { BarraProgresso } from '../componentes/BarraProgresso'
import { Campo } from '../componentes/Campo'
import { CartaoLogin } from '../componentes/CartaoLogin'
import { Log } from '../componentes/Log'
import { useNavegador } from '../navegador'
import type { EstadoExecucao } from '../useExecucoes'

interface Props {
  modulo: ModuloManifesto
  etapa: EtapaDef
  valores: Record<string, string>
  execucao?: EstadoExecucao
  /** Script ja rodou com sucesso para os valores atuais. */
  scriptOk: boolean
  /** Script rodou com sucesso, mas os campos mudaram depois. */
  scriptDesatualizado: boolean
  podeExecutar: boolean
  confirmado: boolean
  onValor: (campo: string, valor: string) => void
  onConfirmar: (confirmado: boolean) => void
  onExecutar: () => void
  onCancelar: () => void
}

export function TelaEtapa(p: Props) {
  const { modulo, etapa, valores, execucao } = p
  const emAndamento = !!execucao?.emAndamento
  const { atual: navegador } = useNavegador()
  const posicao = modulo.etapas.findIndex((e) => e.id === etapa.id) + 1

  const estado = emAndamento
    ? { classe: '', texto: 'Executando...' }
    : p.scriptOk
      ? { classe: 'execucao__estado--ok', texto: '✓ Concluído com sucesso' }
      : p.scriptDesatualizado
        ? { classe: 'execucao__estado--erro', texto: 'Os dados mudaram desde a última execução. Execute novamente.' }
        : execucao?.resultado === 'erro'
          ? { classe: 'execucao__estado--erro', texto: '✕ A execução falhou. Veja o log, corrija e tente de novo.' }
          : execucao?.resultado === 'cancelado'
            ? { classe: 'execucao__estado--erro', texto: 'Execução cancelada.' }
            : null

  return (
    <>
      <div className="sobretitulo">
        {modulo.nome} · Etapa {posicao} de {modulo.etapas.length}
      </div>
      <h1 className="titulo-tela">{etapa.titulo}</h1>
      {etapa.descricao && <p className="descricao-tela">{aplicarModelo(etapa.descricao, valores)}</p>}
      {etapa.aviso && aplicarModelo(etapa.aviso, valores).trim() && (
        <div className="cartao aviso-etapa">{aplicarModelo(etapa.aviso, valores)}</div>
      )}

      {etapa.instrucoes && (
        <div className="cartao">
          <ol className="instrucoes">
            {etapa.instrucoes.map((t, i) => (
              <li key={i}>{aplicarModelo(t, valores)}</li>
            ))}
          </ol>
          {!!(etapa.arquivos?.length || etapa.links?.length) && (
            <div className="linha-botoes" style={{ marginBottom: 0 }}>
              {etapa.arquivos?.map((a) => (
                <button key={a.caminho} className="botao botao--secundario botao--pequeno" onClick={() => void api.abrirArquivoDoModulo(modulo.id, a.caminho)}>
                  {a.rotulo}
                </button>
              ))}
              {etapa.links?.map((l) => (
                <button key={l.url} className="botao botao--secundario botao--pequeno" onClick={() => void api.abrirLink(aplicarModelo(l.url, valores), navegador)}>
                  {l.rotulo}
                </button>
              ))}
            </div>
          )}
        </div>
      )}

      {etapa.campos && (
        <div className="campos">
          {etapa.campos.map((c) => (
            <Campo key={c.id} campo={c} valor={valores[c.id] ?? ''} desabilitado={emAndamento} onChange={(v) => p.onValor(c.id, v)} />
          ))}
        </div>
      )}

      {etapa.confirmacao && (
        <label className="cartao confirmacao">
          <input type="checkbox" checked={p.confirmado} onChange={(e) => p.onConfirmar(e.target.checked)} />
          <span>{etapa.confirmacao}</span>
        </label>
      )}

      {etapa.script && (
        <div className="execucao">
          <div className="execucao__cabecalho">
            <button className="botao botao--primario" disabled={emAndamento || !p.podeExecutar} onClick={p.onExecutar}>
              {emAndamento && <span className="girando" style={{ borderTopColor: '#fff' }} />}
              {p.scriptOk ? 'Executar novamente' : etapa.script.rotuloBotao}
            </button>
            {emAndamento && (
              <button className="botao botao--texto" onClick={p.onCancelar}>
                Cancelar
              </button>
            )}
            {estado && <span className={`execucao__estado ${estado.classe}`}>{estado.texto}</span>}
          </div>
          {execucao && <CartaoLogin execucao={execucao} />}
          {execucao && <BarraProgresso execucao={execucao} />}
          <Log linhas={execucao?.linhas ?? []} />
        </div>
      )}
    </>
  )
}
