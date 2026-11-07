# Readiness Deploy Accelerator

Aplicativo desktop (Windows) que instala e configura as soluções do COE Bizapp no tenant do cliente. A pessoa confere os pré-requisitos, escolhe no catálogo o que quer instalar, preenche os dados de cada item e o instalador roda os scripts PowerShell por ela.

> Esta é a nova versão do assistente de implantação da Biblioteca de Prompts. Até ela ficar pronta, a instalação oficial da Biblioteca continua sendo o assistente da pasta `implantacao/` do repositório [sharepoint-biblioteca-prompt](https://github.com/yGudaN/sharepoint-biblioteca-prompt).

## Como funciona

```
Electron (telas em React)  ──IPC──▶  processo principal  ──spawn──▶  pwsh.exe  ──▶  scripts dos módulos
```

- **Telas:** pré-requisitos → catálogo → etapas de cada item escolhido → resumo.
- **PowerShell 7 não vem no instalador.** O cliente instala antes; a tela de pré-requisitos confere a versão e mostra o link de instalação. Os módulos PowerShell exigidos (ex.: PnP.PowerShell) podem ser instalados pelo próprio app, com `Install-Module -Scope CurrentUser`.
- **Cada item do catálogo é um módulo** em `modules/<id>/`, com um `module.json` e os scripts. A interface é montada a partir do manifesto: para incluir um item novo não é preciso mexer no código do app.
- **O login é feito pelo próprio instalador**, não pelos scripts. A pessoa escolhe no canto inferior esquerdo em qual navegador os logins e links abrem (a lista vem dos navegadores registrados no Windows). O app abre a página da Microsoft nesse navegador, recebe a resposta em `http://localhost:<porta>` (fluxo authorization code + PKCE) e entrega o token ao script. Um mesmo login serve para todas as etapas que usam o mesmo app e tenant.

## Estrutura

```
ReadinessDeployAccelerator/
├── modules/
│   ├── _compartilhado/BizappInstalador.psm1   funções que os scripts usam para falar com o app
│   ├── biblioteca-prompts/
│   │   ├── module.json                         manifesto: etapas, campos, pré-requisitos, resumo
│   │   ├── scripts/                            01-registrar-app, 02-validar-permissoes, 03-provisionar-listas, 04-criar-paginas
│   │   └── assets/                             .sppkg da Biblioteca (atualizado com npm run sincronizar)
│   └── copilot-agent-kit/
│       ├── module.json
│       └── scripts/                            Dataverse.psm1 (Web API + importação com progresso),
│                                               01-verificar-ambiente, 02-configurar-ambiente,
│                                               03-importar-creator-kit, 04-importar-agent-kit
├── testes-manuais/  roteiros PowerShell usados para validar cada item antes de virar módulo
├── src/
│   ├── main/        processo principal: lê manifestos, verifica pré-requisitos, roda o pwsh
│   ├── preload/     ponte segura entre as telas e o processo principal
│   ├── renderer/    telas em React (identidade Bizapp)
│   └── shared/      tipos do manifesto e utilitários comuns
├── scripts/         validar-modulos.mjs, sincronizar-assets.mjs
└── build/icon.png   ícone do app e do instalador
```

## Comandos

```bash
npm install
```

```bash
npm run dev
```
Abre o app com recarga automática.

```bash
npm run dev:web
```
Abre só as telas no navegador (http://localhost:5199), com um **simulador** no lugar do PowerShell. Bom para ajustar layout sem tocar em nenhum tenant.

```bash
npm run validar
```
Confere os manifestos (ids, campos, referências `{{Campo}}`, arquivos) e a sintaxe dos scripts PowerShell.

```bash
npm run dist
```
Atualiza o `.sppkg`, valida, compila e gera `dist/Readiness-Deploy-Accelerator-Setup-<versão>.exe`.

```bash
npm run sincronizar
```
Copia o `.sppkg` mais recente da pasta `implantacao/` do repositório da Biblioteca, que deve estar clonado ao lado deste (`../SharepointBibliotecaPrompt`) ou no caminho da variável `BIBLIOTECA_REPO`. Sem a origem, mantém a cópia que já está aqui. Depois de atualizar, faça commit do `.sppkg`.

```bash
npm run icone
```
Regera `build/icon.png` (ícone do app e do instalador, fundo transparente) a partir do símbolo da Bizapp. Só é preciso se o símbolo mudar.

## Como adicionar um item ao catálogo

1. Crie `modules/<id>/module.json` (o `id` precisa ser igual ao nome da pasta). Use o da Biblioteca como modelo; os tipos estão em [`src/shared/tipos.ts`](src/shared/tipos.ts).
2. Para cada etapa, defina o que ela tem:
   - `campos`: tipo `texto`, `url` ou `guid`, com `obrigatorio`, `padrao` (aceita `{{OutroCampo}}`) e `padraoRegex`;
   - `instrucoes`, `arquivos` e `links`, para passos manuais;
   - `confirmacao`: caixa que precisa ser marcada para avançar;
   - `script`: o PowerShell que a etapa roda. Com `obrigatorio: true`, a etapa só avança depois de o script terminar com sucesso, e precisa rodar de novo se algum campo mudar.
   - `script.tokens`: os logins de que o script precisa. O instalador faz o login antes de rodar o script:
     ```json
     "tokens": [{
       "nome": "SharePoint",
       "clientId": "{{ClientId}}",
       "tenant": "{{Tenant}}.onmicrosoft.com",
       "escopo": "https://{{Tenant}}.sharepoint.com/.default",
       "proposito": "Acessar o SharePoint"
     }]
     ```
     Antes de existir um app no tenant, use um app público da Microsoft:
     - `"@azure-powershell"`: Microsoft Graph (o mesmo que o PnP.PowerShell usa para registrar apps);
     - `"@power-platform-cli"`: Dataverse (o mesmo do `pac`), com `"tenant": "organizations"` e `"escopo": "{{EnvironmentUrl}}/.default"`.

     Com `"tenant": "organizations"` a pessoa sempre escolhe a conta no login, porque o ambiente pode ser de outro cliente.
3. Escreva os scripts seguindo o contrato abaixo.
4. Rode `npm run validar`.

### Contrato dos scripts

```powershell
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\_compartilhado\BizappInstalador.psm1') -Force

$entrada = Read-BizappEntrada                            # valores dos campos (hashtable), lidos do stdin
Assert-BizappEntrada -Entrada $entrada -Campos 'SiteUrl'
$token = Get-BizappToken -Entrada $entrada -Nome SharePoint
Connect-PnPOnline -Url $entrada.SiteUrl -AccessToken $token

Write-BizappLog 'Fazendo algo...'                        # níveis: info, sucesso, aviso, erro, discreto
Set-BizappSaida -Nome 'ClientId' -Valor $id              # preenche o campo de mesmo id e fica disponível no resumo
Write-BizappProgresso -Percentual 42 -Fase 'Importando'  # mostra a barra de progresso na etapa (operações longas)
```

- Sair com código 0 é sucesso; qualquer exceção não tratada marca a etapa como falha.
- `Write-Output` e `Write-Host` também aparecem no log; o que vai para stderr aparece como erro.
- O script deve poder rodar de novo sem estragar nada (verificar antes de criar).
- O script roda sem console interativo (`-NonInteractive`): não use `Read-Host`. Não faça login no script (`-Interactive`, `-DeviceLogin`): declare o token no manifesto, para o login abrir no navegador escolhido.

## Segurança

- As telas não acessam o Node: só chamam as funções expostas no preload.
- O app só executa scripts declarados nos manifestos, só abre arquivos de dentro da pasta do módulo e só abre links `https`.
- Só instala módulos PowerShell que algum manifesto declara.
- Tokens e refresh tokens ficam só na memória do processo principal e somem ao fechar o app. Chegam ao script pelo stdin, nunca em arquivo ou linha de comando.
- O retorno do login escuta só em `127.0.0.1`/`::1`, numa porta livre, e confere o `state` e o PKCE.

## O que ainda falta

- **Testar pelo instalador o Copilot Agent Kit** num ambiente real. O procedimento foi validado manualmente com o PAC CLI (`testes-manuais/Teste-CopilotAgentKit.ps1`), mas o módulo usa o login do app e a Web API do Dataverse, que ainda não rodaram contra um ambiente.
- **Token longo:** a importação do Copilot Agent Kit leva de 30 a 40 min, perto da validade de um token do Dataverse (60 a 90 min). Se ele expirar durante o acompanhamento, a etapa mostra o erro, mas a importação continua no ambiente; ao rodar de novo, a etapa reconhece a solução instalada.
- **Assinatura de código.** Sem certificado, o Windows mostra o aviso do SmartScreen ao abrir o instalador.
- **Atualização automática** (`electron-updater`) e a publicação dos instaladores.
