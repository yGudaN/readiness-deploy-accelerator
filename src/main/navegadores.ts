import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { shell } from 'electron'
import type { Navegador } from '../shared/tipos'
import { executarComando } from './powershell'

/** Id reservado: abre no navegador padrao do Windows. */
export const NAVEGADOR_PADRAO = 'padrao'

interface NavegadorInstalado extends Navegador {
  exe: string
}

let cache: NavegadorInstalado[] | null = null

// Navegadores registrados no Windows (os mesmos que aparecem em "Aplicativos padrao")
const SCRIPT_DETECCAO = `
$raizes = 'HKCU:\\SOFTWARE\\Clients\\StartMenuInternet', 'HKLM:\\SOFTWARE\\Clients\\StartMenuInternet', 'HKLM:\\SOFTWARE\\WOW6432Node\\Clients\\StartMenuInternet'
$r = foreach ($raiz in $raizes) {
  Get-ChildItem -LiteralPath $raiz -ErrorAction SilentlyContinue | ForEach-Object {
    $comando = (Get-ItemProperty -LiteralPath (Join-Path $_.PSPath 'shell\\open\\command') -ErrorAction SilentlyContinue).'(default)'
    $nome = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).'(default)'
    if ($comando) { [pscustomobject]@{ id = $_.PSChildName; nome = $(if ($nome) { $nome } else { $_.PSChildName }); comando = $comando } }
  }
}
ConvertTo-Json -InputObject @($r) -Compress`

function exeDoComando(comando: string): string {
  const texto = comando.trim()
  const exe = texto.startsWith('"') ? texto.slice(1, texto.indexOf('"', 1)) : texto.split(/\s+/)[0]
  return exe.replace(/,\d+$/, '')
}

export async function listarNavegadores(): Promise<Navegador[]> {
  if (!cache) {
    try {
      const lidos = JSON.parse((await executarComando(SCRIPT_DETECCAO)).trim() || '[]') as { id: string; nome: string; comando: string }[]
      const vistos = new Set<string>()
      cache = []
      for (const n of lidos) {
        const exe = exeDoComando(n.comando)
        if (!/\.exe$/i.test(exe) || !existsSync(exe) || /iexplore/i.test(exe) || vistos.has(exe.toLowerCase())) continue
        vistos.add(exe.toLowerCase())
        cache.push({ id: n.id, nome: n.nome, exe })
      }
      cache.sort((a, b) => a.nome.localeCompare(b.nome))
    } catch {
      cache = []
    }
  }
  return [{ id: NAVEGADOR_PADRAO, nome: 'Navegador padrão do Windows' }, ...cache.map(({ id, nome }) => ({ id, nome }))]
}

/** Abre a URL no navegador escolhido. Ids desconhecidos caem no navegador padrao. */
export async function abrirNoNavegador(navegadorId: string | undefined, url: string): Promise<void> {
  if (!/^https?:\/\//i.test(url)) throw new Error('Somente links http(s) são permitidos.')
  if (!cache) await listarNavegadores()
  const navegador = cache?.find((n) => n.id === navegadorId)
  if (!navegador) {
    await shell.openExternal(url)
    return
  }
  const processo = spawn(navegador.exe, [url], { detached: true, stdio: 'ignore', windowsHide: false })
  processo.on('error', () => void shell.openExternal(url))
  processo.unref()
}
