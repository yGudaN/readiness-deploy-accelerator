import { useCallback, useEffect, useMemo, useState } from 'react'
import { aplicarModelo } from '@shared/modelo'
import type { CampoDef, EtapaDef, ModuloManifesto, Navegador, StatusPreRequisito } from '@shared/tipos'
import { api, emSimulador } from './api'
import { Seletor } from './componentes/Seletor'
import { lerNavegadorPreferido, NavegadorContexto, salvarNavegadorPreferido } from './navegador'
import { TelaCatalogo } from './telas/TelaCatalogo'
import { TelaEtapa } from './telas/TelaEtapa'
import { TelaPreRequisitos } from './telas/TelaPreRequisitos'
import { TelaResumo } from './telas/TelaResumo'
import { useExecucoes } from './useExecucoes'
import { assinaturaEntradas, validarCampo, valoresLimpos } from './validacao'

type Passo =
  | { tipo: 'prerequisitos' }
  | { tipo: 'catalogo' }
  | { tipo: 'etapa'; modulo: ModuloManifesto; etapa: EtapaDef }
  | { tipo: 'resumo' }

const CHAVE_INSTALACAO_PS = 'prerequisitos/instalar'
const chaveEtapa = (moduloId: string, etapaId: string): string => `${moduloId}/${etapaId}`

export function App() {
  const [versao, setVersao] = useState('')
  const [modulos, setModulos] = useState<ModuloManifesto[]>([])
  const [preRequisitos, setPreRequisitos] = useState<StatusPreRequisito[] | null>(null)
  const [verificando, setVerificando] = useState(false)
  const [selecionados, setSelecionados] = useState<string[]>([])
  const [valores, setValores] = useState<Record<string, Record<string, string>>>({})
  const [confirmacoes, setConfirmacoes] = useState<Record<string, boolean>>({})
  /** Assinatura das entradas na ultima execucao bem-sucedida de cada etapa. */
  const [sucessos, setSucessos] = useState<Record<string, string>>({})
  const [indice, setIndice] = useState(0)
  const [maxAlcancado, setMaxAlcancado] = useState(0)
  /** Itens ja instalados nesta sessao (marcados no catalogo). */
  const [instalados, setInstalados] = useState<string[]>([])
  const [navegadores, setNavegadores] = useState<Navegador[]>([])
  const [navegador, setNavegador] = useState(lerNavegadorPreferido)

  const escolherNavegador = (id: string): void => {
    setNavegador(id)
    salvarNavegadorPreferido(id)
  }

  const definirValor = useCallback((moduloId: string, campo: string, valor: string) => {
    setValores((v) => ({ ...v, [moduloId]: { ...v[moduloId], [campo]: valor } }))
  }, [])

  // Saidas dos scripts (ex.: ClientId) viram valores do modulo e preenchem os campos de mesmo id
  const { estados, iniciar, cancelar, limpar, algumaEmAndamento } = useExecucoes((chave, nome, valor) => {
    const moduloId = chave.split('/')[0]
    if (modulos.some((m) => m.id === moduloId)) definirValor(moduloId, nome, valor)
  })

  const verificar = useCallback(async () => {
    setVerificando(true)
    try {
      setPreRequisitos(await api.verificarPreRequisitos())
    } finally {
      setVerificando(false)
    }
  }, [])

  useEffect(() => {
    void api.versaoApp().then(setVersao)
    void api.listarNavegadores().then(setNavegadores)
    void api.listarModulos().then((lista) => {
      setModulos(lista)
      // Com um unico item no catalogo, ele ja vem selecionado
      if (lista.length === 1) setSelecionados([lista[0].id])
    })
    void verificar()
  }, [verificar])

  const passos = useMemo<Passo[]>(() => {
    const etapas = modulos
      .filter((m) => selecionados.includes(m.id))
      .flatMap((modulo) => modulo.etapas.map((etapa): Passo => ({ tipo: 'etapa', modulo, etapa })))
    return [{ tipo: 'prerequisitos' }, { tipo: 'catalogo' }, ...etapas, { tipo: 'resumo' }]
  }, [modulos, selecionados])

  const passo = passos[Math.min(indice, passos.length - 1)]

  // Ao entrar numa etapa, preenche os valores padrao dos campos ainda nao tocados
  useEffect(() => {
    if (passo.tipo !== 'etapa') return
    const { modulo, etapa } = passo
    setValores((v) => {
      const atuais = { ...v[modulo.id] }
      let mudou = false
      for (const c of etapa.campos ?? []) {
        if (atuais[c.id] === undefined) {
          atuais[c.id] = c.padrao ? aplicarModelo(c.padrao, atuais) : ''
          mudou = true
        }
      }
      return mudou ? { ...v, [modulo.id]: atuais } : v
    })
  }, [passo])

  const pendenciasPorModulo = useMemo(() => {
    const r: Record<string, string[]> = {}
    for (const m of modulos) {
      r[m.id] = (preRequisitos ?? []).filter((p) => !p.ok && p.exigidoPor.includes(m.nome)).map((p) => p.rotulo)
    }
    return r
  }, [modulos, preRequisitos])

  const camposDoModulo = (m: ModuloManifesto): CampoDef[] => m.etapas.flatMap((e) => e.campos ?? [])

  /** Motivo pelo qual nao da para avancar, ou null. */
  const bloqueio = ((): string | null => {
    if (algumaEmAndamento) return 'Aguarde a execução terminar.'
    if (passo.tipo === 'prerequisitos') {
      if (!preRequisitos || verificando) return 'Verificando os pré-requisitos...'
      return preRequisitos.find((p) => p.chave === 'pwsh')?.ok ? null : 'Instale o PowerShell 7 e clique em "Verificar novamente".'
    }
    if (passo.tipo === 'catalogo') {
      if (selecionados.length === 0) return 'Selecione ao menos um item.'
      const comPendencia = modulos.filter((m) => selecionados.includes(m.id) && pendenciasPorModulo[m.id]?.length)
      return comPendencia.length ? `Resolva os pré-requisitos de: ${comPendencia.map((m) => m.nome).join(', ')}.` : null
    }
    if (passo.tipo === 'etapa') {
      const { modulo, etapa } = passo
      const v = valores[modulo.id] ?? {}
      const invalido = (etapa.campos ?? []).find((c) => validarCampo(c, v[c.id] ?? ''))
      if (invalido) return `Preencha corretamente: ${invalido.rotulo}.`
      const chave = chaveEtapa(modulo.id, etapa.id)
      if (etapa.confirmacao && !confirmacoes[chave]) return 'Marque a confirmação para continuar.'
      if (etapa.script?.obrigatorio && sucessos[chave] !== assinaturaEntradas(etapa, v)) return `Clique em "${etapa.script.rotuloBotao}" para continuar.`
    }
    return null
  })()

  const irPara = (novo: number): void => {
    setIndice(novo)
    setMaxAlcancado((m) => Math.max(m, novo))
  }

  const alternarModulo = (id: string): void => {
    setSelecionados((s) => (s.includes(id) ? s.filter((x) => x !== id) : [...s, id]))
    setMaxAlcancado(indice) // a lista de etapas mudou: refaz o caminho a partir daqui
  }

  const executarEtapa = (modulo: ModuloManifesto, etapa: EtapaDef): void => {
    const chave = chaveEtapa(modulo.id, etapa.id)
    const v = valoresLimpos(valores[modulo.id] ?? {})
    const assinatura = assinaturaEntradas(etapa, v)
    void iniciar(chave, () => api.executarScript(modulo.id, etapa.id, v, navegador), (sucesso) => {
      setSucessos((s) => {
        const novo = { ...s }
        if (sucesso) novo[chave] = assinatura
        else delete novo[chave]
        return novo
      })
    })
  }

  /**
   * Concluir: marca os itens como instalados e volta ao catalogo para instalar outro.
   * Os valores preenchidos ficam guardados; o progresso das etapas recomeca do zero.
   */
  const concluir = (): void => {
    const prefixos = selecionados.map((id) => `${id}/`)
    const semPrefixos = <T,>(registro: Record<string, T>): Record<string, T> =>
      Object.fromEntries(Object.entries(registro).filter(([chave]) => !prefixos.some((p) => chave.startsWith(p))))
    setInstalados((i) => [...new Set([...i, ...selecionados])])
    setSucessos(semPrefixos)
    setConfirmacoes(semPrefixos)
    prefixos.forEach(limpar)
    setSelecionados([])
    setIndice(1)
    setMaxAlcancado(1)
  }

  const instalarModuloPs = (nome: string): void => {
    void iniciar(CHAVE_INSTALACAO_PS, () => api.instalarModuloPs(nome), () => void verificar())
  }

  const renderizarTela = () => {
    switch (passo.tipo) {
      case 'prerequisitos':
        return (
          <TelaPreRequisitos
            status={preRequisitos}
            verificando={verificando}
            instalacao={estados[CHAVE_INSTALACAO_PS]}
            onVerificar={() => void verificar()}
            onInstalar={instalarModuloPs}
          />
        )
      case 'catalogo':
        return (
          <TelaCatalogo
            modulos={modulos}
            selecionados={selecionados}
            instalados={instalados}
            pendencias={pendenciasPorModulo}
            onAlternar={alternarModulo}
          />
        )
      case 'etapa': {
        const { modulo, etapa } = passo
        const chave = chaveEtapa(modulo.id, etapa.id)
        const v = valores[modulo.id] ?? {}
        const campos = camposDoModulo(modulo)
        const entradas = etapa.script?.entradas ?? campos.map((c) => c.id)
        const podeExecutar = entradas.every((id) => {
          const campo = campos.find((c) => c.id === id)
          return !campo || !validarCampo(campo, v[id] ?? '')
        })
        const assinaturaOk = sucessos[chave] !== undefined
        const scriptOk = assinaturaOk && sucessos[chave] === assinaturaEntradas(etapa, v)
        return (
          <TelaEtapa
            key={chave}
            modulo={modulo}
            etapa={etapa}
            valores={v}
            execucao={estados[chave]}
            scriptOk={scriptOk}
            scriptDesatualizado={assinaturaOk && !scriptOk}
            podeExecutar={podeExecutar}
            confirmado={!!confirmacoes[chave]}
            onValor={(campo, valor) => definirValor(modulo.id, campo, valor)}
            onConfirmar={(c) => setConfirmacoes((s) => ({ ...s, [chave]: c }))}
            onExecutar={() => executarEtapa(modulo, etapa)}
            onCancelar={() => cancelar(chave)}
          />
        )
      }
      case 'resumo':
        return <TelaResumo modulos={modulos.filter((m) => selecionados.includes(m.id))} valores={valores} />
    }
  }

  const ultimo = indice === passos.length - 1

  const itemLateral = (p: Passo, i: number, rotulo: string, sub = false) => {
    const navegavel = i <= maxAlcancado && i !== indice && !algumaEmAndamento
    const classes = ['passo', sub && 'passo--sub', i === indice && 'passo--atual', i < indice && 'passo--feito', navegavel && 'passo--navegavel']
    return (
      <li key={i}>
        <button className={classes.filter(Boolean).join(' ')} disabled={!navegavel} onClick={() => setIndice(i)} aria-current={i === indice ? 'step' : undefined}>
          <span className="passo__marca">{i < indice ? '✓' : ''}</span>
          {rotulo}
        </button>
      </li>
    )
  }

  return (
    <NavegadorContexto.Provider value={{ atual: navegador, lista: navegadores }}>
    <div className="app">
      <aside className="lateral">
        <img className="lateral__logo" src="./logo/logo-white-transparent.png" alt="Bizapp" />
        <ol className="lateral__lista">
          {passos.map((p, i) => {
            if (p.tipo === 'prerequisitos') return itemLateral(p, i, 'Pré-requisitos')
            if (p.tipo === 'catalogo') return itemLateral(p, i, 'Catálogo')
            if (p.tipo === 'resumo') return itemLateral(p, i, 'Resumo')
            const primeiraDoModulo = p.modulo.etapas[0].id === p.etapa.id
            return [
              primeiraDoModulo && <li key={`t-${p.modulo.id}`} className="lateral__titulo">{p.modulo.nome}</li>,
              itemLateral(p, i, p.etapa.titulo, true)
            ]
          })}
        </ol>
        <div className="lateral__navegador">
          <span>Logins e links abrem no</span>
          <Seletor
            rotulo="Navegador para logins e links"
            tema="escuro"
            paraCima
            opcoes={navegadores}
            valor={navegador}
            onEscolher={escolherNavegador}
          />
        </div>
        <div className="lateral__rodape">
          Readiness Deploy Accelerator {versao && `v${versao}`}
          {emSimulador && ' · modo simulador'}
        </div>
      </aside>

      <main className="principal">
        <div className="principal__corpo">
          <div className="principal__conteudo">{renderizarTela()}</div>
        </div>
        <footer className="principal__rodape">
          <span className="principal__dica">{bloqueio}</span>
          {indice > 0 && !ultimo && (
            <button className="botao botao--secundario" disabled={algumaEmAndamento} onClick={() => setIndice(indice - 1)}>
              Voltar
            </button>
          )}
          {ultimo ? (
            <button className="botao botao--primario" onClick={concluir}>
              Concluir
            </button>
          ) : (
            <button className="botao botao--primario" disabled={!!bloqueio} onClick={() => irPara(indice + 1)}>
              Avançar
            </button>
          )}
        </footer>
      </main>
    </div>
    </NavegadorContexto.Provider>
  )
}
