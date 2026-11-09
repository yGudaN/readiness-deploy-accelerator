import type { StatusPreRequisito } from '@shared/tipos'
import { api } from '../api'
import { Log } from '../componentes/Log'
import { useNavegador } from '../navegador'
import type { EstadoExecucao } from '../useExecucoes'

interface Props {
  status: StatusPreRequisito[] | null
  verificando: boolean
  instalacao?: EstadoExecucao
  onVerificar: () => void
  onInstalar: (nomes: string[]) => void
}

export function TelaPreRequisitos({ status, verificando, instalacao, onVerificar, onInstalar }: Props) {
  const instalando = !!instalacao?.emAndamento
  const { atual: navegador } = useNavegador()
  const instalaveis = (status ?? []).flatMap((r) => (r.acao?.tipo === 'instalar-modulo' ? [r.acao.nome] : []))

  return (
    <>
      <div className="sobretitulo">Antes de começar</div>
      <h1 className="titulo-tela">Pré-requisitos</h1>
      <p className="descricao-tela">
        Conferimos o que precisa estar instalado nesta máquina. Os itens do catálogo usam o PowerShell 7 e módulos PowerShell para configurar o seu tenant.
      </p>

      <div className="requisitos">
        {!status && (
          <div className="cartao requisito">
            <div className="girando" />
            <div className="requisito__info">Verificando...</div>
          </div>
        )}
        {status?.map((r) => (
          <div key={r.chave} className="cartao requisito">
            <div
              className={`requisito__status ${verificando ? 'requisito__status--pendente' : r.ok ? 'requisito__status--ok' : ''}`}
              aria-label={r.ok ? 'OK' : 'Pendente'}
            >
              {r.ok ? '✓' : '✕'}
            </div>
            <div className="requisito__info">
              <div className="requisito__nome">{r.rotulo}</div>
              <div className="requisito__detalhe">
                {r.ok ? `Instalado: ${r.versaoEncontrada}` : r.detalhe}
                {r.exigidoPor.length > 0 && ` · Usado por: ${r.exigidoPor.join(', ')}`}
              </div>
            </div>
            {r.acao?.tipo === 'instalar-modulo' && (
              <button className="botao botao--secundario botao--pequeno" disabled={instalando || verificando} onClick={() => onInstalar([(r.acao as { nome: string }).nome])}>
                Instalar
              </button>
            )}
            {r.acao?.tipo === 'abrir-link' && (
              <button className="botao botao--secundario botao--pequeno" onClick={() => void api.abrirLink((r.acao as { url: string }).url, navegador)}>
                Como instalar
              </button>
            )}
            {r.linkOficial && r.acao?.tipo !== 'abrir-link' && (
              <button
                className="botao botao--texto botao--pequeno"
                title={r.linkOficial}
                onClick={() => void api.abrirLink(r.linkOficial as string, navegador)}
              >
                Página oficial ↗
              </button>
            )}
          </div>
        ))}
      </div>

      <div className="linha-botoes">
        {instalaveis.length > 1 && (
          <button className="botao botao--primario" disabled={instalando || verificando} onClick={() => onInstalar(instalaveis)}>
            Instalar tudo ({instalaveis.length})
          </button>
        )}
        <button className="botao botao--texto" disabled={verificando || instalando} onClick={onVerificar}>
          {verificando ? 'Verificando...' : 'Verificar novamente'}
        </button>
      </div>

      {instalacao && (
        <>
          <h2 className="secao-titulo">Instalação de módulo</h2>
          <Log linhas={instalacao.linhas} />
        </>
      )}
    </>
  )
}
