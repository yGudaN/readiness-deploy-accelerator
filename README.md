# Readiness Deploy Accelerator

Aplicativo desktop (Windows) que instala e configura as soluções do COE Bizapp no tenant do cliente. A pessoa confere os pré-requisitos, escolhe no catálogo o que quer instalar, preenche os dados de cada item e o instalador roda os scripts PowerShell por ela.

> Esta é a nova versão do assistente de implantação da Biblioteca de Prompts. Até ela ficar pronta, a instalação oficial da Biblioteca continua sendo o assistente da pasta `implantacao/` do repositório [sharepoint-biblioteca-prompt](https://github.com/yGudaN/sharepoint-biblioteca-prompt).

## Como funciona

```
Electron (telas em React)  ──IPC──▶  processo principal  ──spawn──▶  pwsh.exe  ──▶  scripts dos módulos
```

- **Telas:** pré-requisitos → catálogo → etapas de cada item escolhido → resumo.
- **PowerShell 7 não vem no instalador.** O cliente instala antes; a tela de pré-requisitos confere a versão e mostra o link de instalação. Os módulos PowerShell exigidos (ex.: PnP.PowerShell) podem ser instalados pelo próprio app, com `Install-Module -Scope CurrentUser`.
- **Cada item do catálogo é um módulo** em `modules/<id>/`, com um `module.json` e os scripts. A interface é montada a partir do manifesto: para incluir um item novo não é preciso mexer no código do app. Itens que ainda não foram testados num tenant real levam `"testar": true`: o catálogo mostra a etiqueta "Testar" (tirar a marca depois do teste). O campo `categoria` coloca o item num dos grupos do catálogo (os mesmos do checklist do COE: Habilitação, Comunidade, Experiência, Medição, Monitoramento, Acessos, Custos e consumo (FinOps), Segurança e conformidade, Agentes e ALM; a lista fica em `src/shared/tipos.ts` e o validador recusa outro nome).
- **O login é feito pelo próprio instalador**, não pelos scripts. A pessoa escolhe no canto inferior esquerdo em qual navegador os logins e links abrem (a lista vem dos navegadores registrados no Windows). O app abre a página da Microsoft nesse navegador, recebe a resposta em `http://localhost:<porta>` (fluxo authorization code + PKCE) e entrega o token ao script. Um mesmo login serve para todas as etapas que usam o mesmo app e tenant.

## Estrutura

```
ReadinessDeployAccelerator/
├── modules/
│   ├── alertas-atividade/                      AUTO-30
│   │   ├── module.json
│   │   └── scripts/                            AlertasAtividade.psm1 (funções do script validado),
│   │                                           01-consultar, 02-criar, 03-estado
│   ├── mcp-agentes/                            AUTO-12
│   │   ├── module.json
│   │   └── scripts/                            McpAgentes.psm1, 01-consultar, 02-clientes
│   ├── bloqueio-ia/                            AUTO-27
│   │   ├── module.json
│   │   └── scripts/                            BloqueioIa.psm1 (montado a partir do relatório),
│   │                                           01-registrar-app, 02-consultar, 03-aplicar
│   ├── powerbi-kpis/                           AUTO-35
│   │   ├── module.json
│   │   └── scripts/                            PowerBiKpis.psm1 (lógica do script do relatório),
│   │                                           01-consultar, 02-instalar
│   ├── inventario-payg/                        AUTO-04
│   │   ├── module.json
│   │   └── scripts/                            01-inventario (lógica do script do COE, somente leitura)
│   ├── edge-copilot/                           AUTO-26
│   │   ├── module.json
│   │   └── scripts/                            EdgeCopilot.psm1 (montado a partir do relatório),
│   │                                           01-consultar, 02-criar, 03-atribuicao
│   ├── copilot-credits/                        AUTO-05
│   │   ├── module.json
│   │   └── scripts/                            CopilotCredits.psm1 (lógica do script do COE),
│   │                                           01-ambientes, 02-consultar, 03-alocar
│   ├── alm-pipelines/                          AUTO-09
│   │   ├── module.json
│   │   └── scripts/                            AlmPipelines.psm1, 01-consultar, 02-preflight, 03-gerenciados
│   ├── solucoes-por-padrao/                    AUTO-13
│   │   ├── module.json
│   │   └── scripts/                            SolucoesPorPadrao.psm1, 01-consultar, 02-aplicar
│   ├── provisionamento-ambientes/              AUTO-10
│   │   ├── module.json
│   │   └── scripts/                            ProvisionamentoAmbientes.psm1 (chamadas validadas no teste
│   │                                           do roteiro em Word), 01-consultar, 02-criar
│   ├── configuracoes-dataverse/                AUTO-11
│   │   ├── module.json
│   │   └── scripts/                            ConfiguracoesDataverse.psm1 (chamadas do roteiro em Word),
│   │                                           01-consultar, 02-idioma, 03-fuso, 04-equipe, 05-caixa
│   ├── descoberta-restrita/                    AUTO-16
│   │   ├── module.json
│   │   └── scripts/                            DescobertaRestrita.psm1 (funções do script validado +
│   │                                           lista de sites do roteiro em Word), 01-consultar, 02-site
│   ├── auditoria-copilot/                      AUTO-31
│   │   ├── module.json
│   │   └── scripts/                            AuditoriaCopilot.psm1 (funções do script validado),
│   │                                           01-consultar, 02-auditoria, 03-retencao
│   ├── _compartilhado/
│   │   ├── BizappInstalador.psm1               funções que os scripts usam para falar com o app (log, saídas,
│   │   │                                       progresso, tokens, contexto e pacote de evidências)
│   │   └── BizappGraph.psm1                    Graph PowerShell conectado com o token do instalador
│   ├── biblioteca-prompts/
│   │   ├── module.json                         manifesto: etapas, campos, pré-requisitos, resumo
│   │   ├── scripts/                            01-registrar-app, 02-validar-permissoes, 03-provisionar-listas, 04-criar-paginas
│   │   └── assets/                             .sppkg da Biblioteca (atualizado com npm run sincronizar)
│   ├── copilot-agent-kit/
│   │   ├── module.json
│   │   └── scripts/                            Dataverse.psm1 (Web API + importação com progresso),
│   │                                           01-verificar-ambiente, 02-configurar-ambiente,
│   │                                           03-importar-creator-kit, 04-importar-agent-kit
│   ├── environment-routing/
│   │   ├── module.json
│   │   └── scripts/                            ConfiguracoesTenant.psm1 (configurações do tenant),
│   │                                           01-verificar-tenant, 02-ativar-roteamento
│   ├── grupos-copilot/                         AUTO-22
│   │   ├── module.json
│   │   └── scripts/                            GruposCopilot.psm1 (funções do script validado),
│   │                                           01-consultar, 02-criar-grupos, 03-membros
│   ├── mfa-copilot/                            AUTO-33
│   │   ├── module.json
│   │   └── scripts/                            MfaCopilot.psm1 (funções do script validado),
│   │                                           01-consultar, 02-criar-relatorio, 03-mudar-estado
│   ├── modelo-protecao/                        AUTO-20
│   │   ├── module.json
│   │   └── scripts/                            ModeloProtecao.psm1 (funções do script validado; DLP da
│   │                                           Power Platform pela API, sem o módulo do Windows PowerShell 5.1),
│   │                                           01-consultar, 02-criar, 03-estado
│   └── sharepoint-compartilhamento/            AUTO-34
│       ├── module.json
│       └── scripts/                            SharePointCompartilhamento.psm1 (funções do script validado),
│                                               01-consultar, 02-governanca, 03-compartilhamento-site
├── testes-manuais/  roteiros PowerShell usados para validar cada item antes de virar módulo
├── PENDENCIAS.md    decisões em aberto com o time sobre os itens do catálogo
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
   - `campos`: tipo `texto`, `url` ou `guid`, com `obrigatorio`, `padrao` (aceita `{{OutroCampo}}`) e `padraoRegex`; ou tipo `escolha`, com `opcoes` (`valor`, `rotulo`, `descricao`), mostrado como lista de opções;
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
     - `"@graph-cli"`: Microsoft Graph (o mesmo do `Connect-MgGraph`), para os itens de identidade.
     - `"@exchange-online"`: Exchange Online (`"escopo": "https://outlook.office365.com/.default"`) e Security & Compliance (`"https://ps.compliance.protection.outlook.com/.default"`), entregues ao `Connect-ExchangeOnline` / `Connect-IPPSSession -AccessToken` (módulo 3.8 ou superior).

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

### Itens do guia de automações (AUTO-xx)

Os itens que vêm dos scripts validados no laboratório seguem os padrões do guia:

- **Consultar primeiro:** a primeira etapa só lê e grava `Conta` e `TenantId`. As etapas seguintes passam esses valores em `entradas` e chamam `Assert-BizappContexto` (ou `Connect-BizappGraph`), que aborta se o login for de outro tenant ou conta.
- **Pacote de evidências:** cada execução chama `New-BizappEvidencias -Item <id> -Acao <ação>`, que cria `Documentos\Readiness Deploy Accelerator\evidencias\<id>\<data-hora>-<ação>`, e grava os CSVs com `Export-BizappEvidencia` (mesmos nomes do laboratório: `configuracao-antes.csv`, `acoes.csv`, `resumo.csv`...). O resumo final do app ganha o botão "Abrir evidências".
- **Lógica preservada:** as funções do script validado vão para um `.psm1` do item sem mudar a lógica; o script original fica em `testes-manuais/originais/`.
- **Um login por item:** todas as etapas pedem o mesmo token (mesmo cliente e mesmos escopos), então o login acontece uma vez e é reaproveitado.

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

- **MCP e recursos para agentes (AUTO-12):** testar pelo instalador; liberar e bloquear cliente ainda não rodaram de verdade. Veja [PENDENCIAS.md](PENDENCIAS.md).
- **Power BI de KPIs (AUTO-35):** testar pelo instalador; falta o PBIX "tudo em 1" oficial. Veja [PENDENCIAS.md](PENDENCIAS.md).
- **ALM com Pipelines (AUTO-09):** testar pelo instalador. Veja [PENDENCIAS.md](PENDENCIAS.md).
- **Ambientes DEV, HML e PROD (AUTO-10):** testar pelo instalador. Veja [PENDENCIAS.md](PENDENCIAS.md).
- **Configurações do Dataverse (AUTO-11):** testar pelo instalador; instalar idioma ainda não rodou de verdade (o ambiente de teste só oferecia o inglês). Veja [PENDENCIAS.md](PENDENCIAS.md).
- **Environment Routing: regras de roteamento** em aberto com o time. Veja [PENDENCIAS.md](PENDENCIAS.md).
- **Testar pelo instalador o Environment Routing** num tenant real. O procedimento foi validado manualmente com o PAC CLI (`testes-manuais/Teste-EnvironmentRouting.ps1`), mas o módulo usa o login do app e a API de administração do Power Platform, que ainda não rodaram contra um tenant.
- **Copilot Agent Kit:** ligar o code apps pela Power Platform API ainda não rodou num ambiente onde ele estivesse desligado.
- **Token longo:** a importação do Copilot Agent Kit leva de 30 a 40 min, perto da validade de um token do Dataverse (60 a 90 min). Se ele expirar durante o acompanhamento, a etapa mostra o erro, mas a importação continua no ambiente; ao rodar de novo, a etapa reconhece a solução instalada.
- **Assinatura de código.** Sem certificado, o Windows mostra o aviso do SmartScreen ao abrir o instalador.
- **Atualização automática** (`electron-updater`) e a publicação dos instaladores.
