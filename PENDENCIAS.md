# Pendências dos itens do catálogo

Decisões em aberto com o time do COE. Não fazem parte do instalador até serem confirmadas.

## Environment Routing (COE-IA-003): regras de roteamento

**Situação:** o item segue o documento COE-IA-003 e só liga a opção `enableDefaultEnvironmentRouting` (e, se escolhido, `environmentRoutingAllMakers`). Não cria regras.

**O que o teste mostrou (08/11/2026, tenant de demo):** depois de ligar, o admin center mostra o roteamento ativo para Power Apps, fluxos da nuvem, fluxos da área de trabalho e Copilot Studio, mas a lista de regras fica vazia.

**Por que importa:** pela documentação atual da Microsoft, o roteamento funciona por regras (quem é roteado: todos ou um grupo de segurança; e para qual grupo de ambientes). Se nenhuma regra se aplica ao maker, ele vai para o ambiente padrão. Pode ser que, sem regras, ninguém seja roteado. [Documentação](https://learn.microsoft.com/power-platform/admin/default-environment-routing)

**Para decidir:**
1. Testar com um maker que não é administrador: abrir make.powerapps.com e ver se ele cai num ambiente pessoal de Developer ou no ambiente padrão.
2. Confirmar com o time se o item deve criar uma regra (ex.: "Todos" + um grupo de ambientes para os ambientes de Developer).
3. Se sim: pesquisar a API das regras de roteamento e adicionar como etapa do módulo `environment-routing`.

**Observação:** o roteamento ficou ligado no tenant de demo (crm202149) depois do teste.

## Guia de automações (18/11/2026)

O `originais/guia-automacoes-readiness-v2.html` trouxe os scripts completos dos itens 12, 26, 27 e 35, salvos em `originais/`:
- `12-mcps-recursos-agentes.ps1` (v3): base do teste `Teste-AUTO12.ps1`.
- `26-navegadores-m365-copilot.ps1` (v8, o validado no relatório): confere com o item do instalador (mesmos IDs, opção `_1` e corpo). Ajuste na v1.14.1: o instalador passou a mandar os mesmos `@odata.type` da v8 no valor de escolha e na atribuição. A v8 usa IDs fixos e o prefixo LAB-AUTO26; o instalador lê os IDs no catálogo e marca a política na descrição.
- `27-bloqueio-ia-nao-corporativa.ps1` (versão segura 1.2, só GET): confere com o item do instalador (mesmo endpoint, escopo `api.securitycenter.microsoft.com` e permissão `Ti.ReadWrite`). O guia confirma que não há script de escrita aprovado: bloquear e remover no instalador continuam sem base testada.
- `35-instalar-powerbi-kpis-guia.ps1`: mesmo código do relatório (só muda a quebra de um comentário). Os scripts de inventário do item 35 também não vieram no guia.

## MCP e recursos para agentes (AUTO-12): testar pelo instalador

**Situação:** relatório (`originais/12-mcps-relatorio.docx`) e script v3 do guia (`originais/12-mcps-recursos-agentes.ps1`). Teste manual `Teste-AUTO12.ps1` aprovado em 18/11/2026 no CRM332072: Validar e Consultar do original, leitura dos 8 clientes de MCP do ambiente (tabela `allowedmcpclient`; GitHub Copilot e Dataverse MCP CLI bloqueados) e as quatro perguntas no Copilot Studio (a criação de registro não foi feita). Obs.: no Windows PowerShell 5.1, o login interativo do Graph derruba o processo se não for concluído em 2 minutos; o teste passou a usar código de dispositivo.

**No instalador (v1.15.0, item `mcp-agentes`):**
- Consultar (somente leitura, Web API do Dataverse): papel da conta, clientes de MCP (tabela `allowedmcpclient`, nome do conjunto lido nos metadados), conectores do ambiente (tabela `connector`) e políticas de DLP do tenant (mesma API do item 20).
- Clientes (opcional): libera ou bloqueia um cliente (`PATCH isenabled`) com CONFIRMO e confere relendo. Clientes do Copilot Studio (`microsoftcopilotstudio*`) não são bloqueados por aqui.
- Validação guiada no Copilot Studio (as quatro perguntas) e orientações para conector MCP personalizado e DLP (o autor não executou essas partes).

**Para testar:** rodar o item pelo instalador no CRM332072; liberar e depois bloquear de novo o Microsoft GitHub Copilot App e conferir em Configurações > Produto > Recursos > Dataverse MCP > Configurações avançadas.

## Bloqueio de IA não corporativa (AUTO-27): validado

**Teste pelo instalador (18/11/2026, tenant Bizapp, v1.15.2):** o admin do tenant rodou o item e deu certo. Etiqueta "Testar" retirada na v1.15.3.

**Situação:** veio só o relatório (`originais/27-bloqueio-ia-relatorio.docx`). Na prova do autor, login e token (app próprio, delegado `Ti.ReadWrite`) funcionaram, mas a primeira consulta (`GET /api/indicators`) deu **403 por RBAC do Defender**; criar e remover não foram testados, por decisão de Segurança. O script não veio. O tenant de demo tem Office 365 E5, sem Defender for Endpoint.

**No instalador (v1.14.0), sem teste real, seguindo as recomendações do relatório:** registra um app no Entra ID (cliente público, `http://localhost`, delegado `WindowsDefenderATP/Ti.ReadWrite`, sem segredo; se a API do Defender não existe no tenant, nada é criado), consulta só com GET, e a etapa opcional de mudança exige CONFIRMO, justificativa e expiração (1 a 365 dias): avisar (`Warn`, padrão) ou bloquear (`Block`) por domínio, com grupos de dispositivos opcionais; remover apaga só indicadores com a marca "Criado pelo Readiness Deploy Accelerator". Indicadores de outra origem nunca são alterados. Token com escopo `https://api.securitycenter.microsoft.com/.default` (a documentação avisa que essa API recusa outros públicos com 403).

**Para testar:** num tenant com Defender for Endpoint, com uma conta que tenha função do Defender para gerenciar indicadores (RBAC) e com os indicadores de rede personalizados ligados: registrar o app, aceitar as permissões no primeiro login, consultar `chatgpt.com`, avisar com expiração curta num grupo piloto, conferir em `security.microsoft.com` e remover.

## Power BI de KPIs (AUTO-35): testar pelo instalador

**Situação:** o relatório (`originais/35-power-bi-relatorio.docx`) aprovou o readiness e deixou pendentes os dois testes de instalação do PBIX, por falta do BI "tudo em 1". O script proposto no relatório foi extraído sem alterações para `originais/35-instalar-powerbi-kpis.ps1`.

**Teste manual (17/11/2026, CRM332072, workspace LAB-AUTO35):** com PBIX de teste (`Cowork Chargeback.pbix` e `NEW - AI-in-One.pbix`), publicação inicial aprovada e atualização com CreateOrOverwrite aprovada: continuou 1 relatório, com o mesmo ID. Relatórios de teste ficaram no workspace LAB-AUTO35 (excluir quando não precisar).

**No instalador (v1.13.0):** mesma lógica (validar o PBIX e o workspace, relatórios antes/depois, CreateOrOverwrite, conferir 1 relatório com o nome do arquivo e, na atualização, o mesmo ID), pela API REST do Power BI (`/groups/{id}/imports?nameConflict=CreateOrOverwrite`) com o login do instalador (cliente do Azure PowerShell, escopo do Power BI), em vez do módulo MicrosoftPowerBIMgmt. O caminho do PBIX é um campo; quando o PBIX oficial existir, ele pode vir dentro do instalador.

**O que não foi testado:** o item pelo instalador (login do Azure PowerShell no Power BI e importação pela API REST); PBIX acima de 1 GB (recusado, publicar pelo Desktop). Ficaram fora: os inventários de readiness do relatório (Power BI, PPAC, Microsoft 365, Agent 365), cujos scripts não vieram.

## Itens com a etiqueta "Testar"

Itens que entraram no instalador sem teste num tenant real levam `"testar": true` no `module.json`, e o catálogo mostra a etiqueta "Testar". Hoje: nenhum. Tirar a marca quando o teste passar.

## Inventário PAYG do Copilot Studio (AUTO-04): validado

**Teste pelo instalador (18/11/2026, tenant Bizapp):** 81 ambientes, 1 Billing Policy (MSAzureSponsorshipCopilotStudio, estado `DisabledBySubscription`) vinculada ao Bizapp POC, com 180.500 Copilot Credits. Na v1.15.4 o resumo passou a mostrar o estado de cada plano em texto (antes aparecia só "0 ativas") e avisa quando a assinatura do Azure desativou o plano. Etiqueta "Testar" retirada na v1.15.4.

**Situação:** script do COE somente leitura (`originais/04-inventario-payg.ps1`, COE-IA-010) e roteiro (`originais/04-inventario-payg-roteiro.docx`). Levado ao instalador sem teste (v1.12.0), a pedido, porque o tenant de demo não tem Copilot Credits nem plano de pagamento por uso.

**O que mudou para caber no instalador:** logins do instalador (sem Az.Accounts e Add-PowerAppsAccount); o CSV `COE-IA-010_Inventario_PAYG.csv` vai sempre para a pasta de evidências, em vez da pergunta. Mesmas chamadas e mesma tabela: `licensing/billingPolicies` (paginado), `billingPolicies/{id}/environments`, nomes dos ambientes pela lista do admin e `allocationsV2/availability` com MCSMessages; só GET (conferido com dados simulados).

**Teste parcial (17/11/2026, CRM332072, v1.12.0):** login, permissão e leitura funcionaram; o tenant não tem plano de pagamento por uso e o item respondeu "Nenhuma Billing Policy PAYG encontrada".

**Para testar:** como é só leitura, dá para rodar no tenant de demo (deve dizer "Nenhuma Billing Policy PAYG encontrada", o que já testa login e permissão) e, num tenant com plano de pagamento por uso, conferir a tabela com o admin center (Licenciamento > Planos de cobrança).

## Edge abrindo no Microsoft 365 Copilot (AUTO-26): validado

**Situação:** veio só o relatório (`originais/26-navegadores-relatorio.docx`), que dá o script `26-navegadores-m365-copilot.ps1` v8 como validado no laboratório do autor. O script não veio, então o item foi montado a partir do relatório: mesmos endpoints beta do Intune (`configurationPolicies`, `configurationSettings/{id}`), windows10/mdm, HomepageLocation e NewTabPageLocation habilitados com a URL do Copilot, política criada sem atribuição e idempotente, atribuição só a grupo piloto, desabilitar = remover atribuições, reverter = excluir só a política do item. O formato do corpo do POST (instância de escolha com filho de texto) é o padrão do Settings Catalog, mas não foi conferido contra o script original.

**Teste manual (17/11/2026, CRM332072):** `Teste-AUTO26.ps1` passou pelo login, escopos e função (Administrador Global) e parou na primeira leitura do Intune: *Request not applicable to target tenant*. O tenant só tem `INTUNE_O365` (mobilidade básica do Office 365) em *PendingActivation*, que não habilita o Settings Catalog.

**No instalador (v1.11.0), sem teste real:** consulta (com aviso "Bloqueado: tenant sem Intune"), criar com prévia em `corpo-proposto.json` e conferência dos dois valores lendo de volta, atribuir/desabilitar/excluir com CONFIRMO, e passo a passo para conferir num dispositivo (`edge://policy`). Diferença do relatório: em vez do prefixo LAB-AUTO26, a política do item é reconhecida pela marca "Criada pelo Readiness Deploy Accelerator" na descrição e pelo ID guardado em `referencia-politica.json`.

**Teste pelo instalador (18/11/2026, tenant Bizapp, v1.15.0):** a etapa Criar funcionou. A política "Edge - Microsoft 365 Copilot" foi criada (ID 4678bc4e-…) sem atribuição, e a conferência leu de volta HomepageLocation e NewTabPageLocation habilitados com `https://copilot.cloud.microsoft/`. O aviso de `-NoTypeInformation` obsoleto no PowerShell 7 foi removido na v1.15.1 (não afetava o resultado). Na mesma rodada, atribuir ao grupo piloto, desabilitar e excluir também funcionaram. Etiqueta "Testar" retirada na v1.15.2.

**Para testar:** num tenant com Intune (ou com a avaliação do Intune Plan 1 ativada), rodar `testes-manuais/Teste-AUTO26.ps1` ou o item no instalador, conferir a política no Intune admin center e, com um grupo piloto, em `edge://policy` num dispositivo. Fora do escopo: abrir o Copilot ao iniciar o Edge (RestoreOnStartup).

## Alocação de Copilot Credits (AUTO-05): validado

**Teste pelo instalador (18/11/2026, tenant Bizapp, v1.15.2):** ambiente Bizapp POC, 180.500 créditos disponíveis no tenant; a alocação foi feita sem erro e conferida no admin center (Licenciamento > Copilot Studio > Gerenciar Copilot Credits). Etiqueta "Testar" retirada na v1.15.3.

**Ajustes da v1.15.5, depois do teste:** (1) com 81 ambientes, a lista em texto corrido na etapa de consulta ficou ilegível: agora a tela mostra só a contagem e o campo Ambiente sugere os nomes enquanto se digita (novo `sugestoesDe` no campo de texto). (2) A reconsulta da disponibilidade (`allocationsV2/availability`) continuou em 180.500 depois da alocação, sem erro: esse número é o que ainda pode ir para o ambiente e não mostra o que já está nele. A consulta e a alocação passaram a ler também a alocação do ambiente (`GET licensing/allocationsByEnvironment/{id}`, api-version 2024-10-01: `allocated` e a regra `TenantPool`), e a conferência depois do PUT usa esse valor (até 4 leituras com 10 s). Testado de novo no tenant Bizapp em 19/11/2026: tudo certo.

**v3.0.0 (19/11/2026):** no catálogo em tela cheia, as duas colunas passaram a ser de grupos (1º grupo à esquerda, 2º à direita...), com os itens de cada grupo um abaixo do outro.

**Situação:** o item tem script do COE (`originais/05-copilot-credits.ps1`, COE-IA-009), que o autor validou em teste prático (155.500 disponíveis, alocação de 5.000, reconsulta). Ele não foi testado aqui: o tenant de demo não tem Copilot Credits. A pedido, o script foi levado ao instalador sem teste (v1.10.0).

**O que mudou para caber no instalador:** os logins vêm do instalador (sem Az.Accounts e sem Add-PowerAppsAccount) e as respostas vêm dos campos (sem Read-Host). As chamadas, os parâmetros e o corpo do PUT são os mesmos do original (conferido com dados simulados): GET `licensing/allocationsV2/availability` com o filtro de `MCSMessages` e PUT `licensing/allocationsV2`, api-version 2024-10-01, igual ao tutorial da Microsoft. As regras também: quantidade não negativa e não maior que o disponível; confirmação ALOCAR; reconsulta no fim. Acréscimos: a quantidade só aceita números sem ponto (para "5.000" não virar 5) e mensagens próprias para *TenantPoolLockedByPolicy* e *InvalidAllocationRequest*.

**Para testar:** num tenant com Copilot Credits pré-pagos, consultar um ambiente de teste, alocar 5000 e conferir no admin center (Licenciamento > Copilot Studio > Gerenciar Copilot Credits). O teste manual com o original está em `testes-manuais/Teste-AUTO05.ps1`.

## ALM com Pipelines (AUTO-09): testar pelo instalador

**Situação:** o roteiro em Word (`originais/09-roteiro.docx`, cabeçalho COE-IA-008) usa o host da plataforma (sem ambiente host dedicado). Só a escolha dos ambientes e o preflight têm script; pipeline, Cross-Geo e deployments são feitos na tela.

**Teste manual (17/11/2026, CRM332072):**
- Primeira tentativa com DEV no Brasil, HML nos EUA e PROD no Canadá: o deployment deu *0x80040265 - Issue detected with the environment configuration for this pipeline... [Agentes IA - Homol]*. O host da plataforma fica na região do tenant (EUA) e o Cross-Geo estava desligado.
- Com os três ambientes nos EUA: preflight ok, pipeline "Agentes IA v2" com HML e PROD, deployment DEV → HML ok.
- `pac pipeline list` no DEV respondeu *Resource not found for the segment 'deploymentpipelines'*: as tabelas de pipeline ficam no host, e o host da plataforma é oculto. Por isso o instalador não cria nem confere o pipeline: guia a criação na tela.

**No instalador (v1.9.0):** consulta, conferência de DEV/HML/PROD (Dataverse, gerenciado, região e aviso de Cross-Geo; sugere os ambientes do item 10), tornar HML e PROD gerenciados, e passo a passo do pipeline e do primeiro deployment.

**O que não foi testado:** o item pelo instalador; ligar o Cross-Geo (não foi preciso).

## Apps e fluxos em soluções (AUTO-13)

**Situação:** o roteiro em Word (`originais/13-roteiro.docx`, cabeçalho COE-IA-006) faz a troca à mão no admin center, dizendo que não há comando público. A documentação da Microsoft ("Add canvas apps and cloud flows to a solution by default", considerações, item 5) diz que as duas chaves da tela gravam as colunas `enablecanvasappsinsolutionsbydefault` e `enableflowsinsolutionbydefault` da tabela `organization`, listadas como graváveis. O item muda essas colunas pela Web API do Dataverse.

**Teste manual (16/11/2026, CRM332072):** as duas chaves estavam ligadas; desligadas pela API, a releitura e o admin center mostraram desligadas.

**Ficou em aberto:** o app de teste `LAB-AUTO13`, criado com as chaves desligadas, apareceu na Common Data Services Default Solution (comportamento de chave ligada). Pode ter sido criado antes da troca ou o Power Apps pode demorar a refletir. O teste manual terminou antes de restaurar, mas a v1.8.0 religou as duas no CRM332072 (16/11/2026, 22:35): o ambiente voltou ao original.

**Teste pelo instalador (v1.8.0):** consultar e aplicar funcionaram (desligar e religar), mas o botão Avançar não liberava depois de aplicar: o script limpa a confirmação e o app achava que os campos tinham mudado. Corrigido na v1.8.1 (a conferência considera os campos que o próprio script preencheu).

**Validação (16/11/2026):** com as chaves ligadas, um fluxo novo nasceu dentro da Common Data Services Default Solution. Item validado.

## Ambientes DEV, HML e PROD (AUTO-10): testar pelo instalador

**Situação:** o item não tinha script, só um roteiro em Word (`originais/10-provisionamento-ambientes-roteiro.docx`, cabeçalho COE-IA-007). Validado no teste manual (13/11/2026, tenant de demo crm332072): consulta de ambientes, regiões, idiomas e moedas; criação de um Sandbox com Dataverse (português, real) em cerca de 1 minuto; ambiente gerenciado (protectionLevel Standard, aparece depois de uns 40 s).

**O que mudou em relação ao roteiro:**
- O `New-AdminPowerAppEnvironment` do roteiro é recusado nesse tenant com *MacroRegionRequired*. A Microsoft orienta usar a API de provisionamento (`api.powerplatform.com/environmentmanagement/provisioning/environments`, 2024-10-01) com `macroRegion`; o módulo antigo não tem esse parâmetro. A correção equivalente no PAC CLI saiu na 2.15.
- Idiomas e moedas só vieram pela macro região (`north-america`) com a API 2021-04-01. Pela região (`unitedstates`) o serviço responde *InvalidMacroRegion*.
- Macro regiões conhecidas (PAC CLI 2.15): north-america, the-americas, emea, europe-uk, eu-efta, asia-pacific. Só `north-america` foi testada; não confirmamos se o Brasil fica em `the-americas`.
- O roteiro usa a URL da instância como alternativa ao Environment ID; isso está errado e não foi levado para o instalador.

**Teste pelo instalador (v1.6.0, 13/11/2026):** criou "Agentes IA - Homol" (América do Norte, Estados Unidos, gerenciado) e "Agentes de IA - Prod" (Produção, Américas, ficou no Canadá, gerenciado). Ficar no Canadá está correto: sem o Advanced Data Residency a Microsoft escolhe o datacenter dentro da macro região, e o primeiro ambiente fixa a região dos próximos ([documentação](https://learn.microsoft.com/power-platform/admin/macro-regions)).

**Ajustes da v1.6.1 para seguir o roteiro:** região específica primeiro (como o `LocationName` do roteiro) e macro região só se o tenant exigir; Dataverse opcional (gerenciado exige Dataverse); qualquer idioma da região, pelo código; descrição gravada como digitada (os ambientes do item ficam em `ambientes-criados.csv` na pasta de evidências; os da v1.6.0 são reconhecidos pela marca antiga); CRIAR limpo a cada execução; PROD bloqueado sem DEV e HML; espera de até 120 min; aviso quando as camadas ficam em regiões diferentes; próximos passos do roteiro no fim.

**Teste da v1.6.1 (13/11/2026):** "Agentes de IA - Dev" foi criado com a região específica `southamerica` e ficou no Brasil (`crm2.dynamics.com`), sem precisar da macro região. Ou seja, a nova API aceitou a região exata neste tenant (o comando antigo do roteiro é que exigia macro região).

**O que não foi testado:** criar sem Dataverse; a região específica num tenant com Advanced Data Residency; grupo de segurança e domínio próprio. A remoção não existe no instalador, como pede o roteiro.

**Para limpar:** ficaram no tenant de demo dois ambientes `LAB-AUTO10-DEV` do teste manual (um gerenciado). Remova pelo admin center quando não precisar mais.

## Configurações do Dataverse (AUTO-11): testar pelo instalador

**Situação:** o item não tinha script, só um roteiro em Word (`originais/11-dataverse-configuracoes-roteiro.docx`). O cabeçalho dele diz COE-IA-004 e a organização está fixa em `fpsnewdev`. Validado no teste manual (12/11/2026, tenant de demo, ambiente org31c11f3e): consulta de organização, idiomas, fusos, equipes, unidades de negócio e caixas de correio; mudar e voltar o fuso de um usuário; criar e apagar uma equipe proprietária; inverter e voltar a entrada e saída de e-mail de uma caixa.

**O que não foi testado:** instalar um idioma (`ProvisionLanguageAsync`), porque o ambiente de teste só oferecia o inglês, que já era o idioma base; mudar o fuso de todos os usuários; o item pelo instalador (v1.5.3; na v1.5.2 criar equipe e ligar caixa falhavam na conferência por não acharem a equipe ou a caixa — corrigido; a v1.5.0 parava na consulta dos idiomas). No tenant crm332072 o admin center lista dezenas de idiomas com versão 0.0 (pacote ainda não baixado), mas RetrieveAvailableLanguages só devolve o inglês; desde a v1.5.2 o instalador tenta instalar mesmo assim e mostra o erro do Dataverse se ele recusar.

**Diferenças do roteiro:** o login é o do instalador (sem Az.Accounts); o fuso pode ir para um usuário ou para todos, com o fuso anterior guardado nas evidências; a equipe criada leva a marca "Criada pelo Readiness Deploy Accelerator" na descrição e só equipes com a marca podem ser removidas.

## Descoberta restrita no SharePoint (AUTO-16): testar pelo instalador

**Situação:** havia dois materiais do item; a base é o script (`originais/16-rcd-sharepoint.ps1`), mais completo. Do roteiro em Word (`originais/16-rcd-sharepoint-roteiro.docx`) veio a lista de todos os sites com o estado do recurso. Teste manual (12/11/2026, tenant de demo): consulta e lista de 13 sites funcionaram sem o SharePoint Advanced Management.

**O que não foi testado:** ligar e desligar num site (fica para o teste pelo instalador, v1.4.0). Sem o SharePoint Advanced Management, espera-se que o SharePoint recuse; a mensagem exata da recusa ainda não foi vista. O instalador reconhece as recusas vistas no item de compartilhamento ("experimental feature", "not supported in the current environment") e menções a licença; se vier outra mensagem, ela aparece como erro comum e é preciso ajustar `Test-ErroSemSam`.

**Diferença do original:** o módulo do SharePoint é importado direto no PowerShell 7 (o original usa `-UseWindowsPowerShell`).

## Modelo de proteção de dados (AUTO-20): testar pelo instalador

**Situação:** validado no teste manual (12/11/2026, tenant de demo): consultar, criar (e não duplicar), habilitar, desabilitar e reverter os 5 objetos. O teste exigiu o Windows PowerShell 5.1 com o Exchange 3.10.0 (o 3.11.x conflita com o Graph 2.39 fixado pelo script) e uma correção no script original (`[AllowEmptyCollection()]` em `Get-Auto20State`, que parava com lista vazia), aplicada só na cópia de trabalho do teste.

**Para avisar quem escreveu o script:** a lista vazia e o "already published" ao habilitar (o rótulo já nasce publicado, e o script conta isso como falha).

**O que não foi testado:** o item pelo instalador (v1.3.0). Ele roda no PowerShell 7: a DLP da Power Platform vai direto pela API que o módulo usa (`PowerPlatform.Governance/v1/policies`), o Acesso Condicional pela API do Graph e o Purview por `Connect-IPPSSession -AccessToken`.

**Observação do teste:** depois de reverter, o Purview ainda listava a DLP e o rótulo por alguns minutos; a política de rótulos sumiu sozinha depois de ficar sem rótulos.

## Alertas de atividade incomum (AUTO-30): testar pelo instalador

**Situação:** validado no teste manual (11/11/2026, tenant de demo): consulta, criar a política simples (sem duplicar), desligar, religar, criar a anômala e remover as duas.

**O que não foi testado:** o item pelo instalador (v1.2.0). A marca "Criada pelo Readiness Deploy Accelerator" vai na descrição e no comentário da política, porque no teste o Purview gravou às vezes a descrição no lugar do comentário; só políticas com a marca podem ser ligadas, desligadas ou removidas.

## Auditoria do Copilot (AUTO-31)

**Situação:** validado no teste manual (11/11/2026) e pelo instalador (v1.1.1, tenant de demo): logins do Exchange Online e do Security & Compliance, consulta, ligar a auditoria e criar a política de retenção. No teste manual, desligar e religar mostrou que a Microsoft demora para religar; o instalador trata isso como "Ligando (pode levar até 60 min)".

**Observação:** uma política removida pode continuar reservando a prioridade por um tempo, mesmo sumindo do portal. A etapa avisa e sugere uma prioridade livre.

**Não testado pelo instalador:** remover a política de retenção.

## Excesso de compartilhamento no SharePoint (AUTO-34): testar com SharePoint Advanced Management

**Situação:** o item está no instalador desde a v0.8.0. A consulta foi validada no teste manual (09/11/2026: 14 sites, sem erro) e pelo instalador na v0.8.1, incluindo o login próprio do SharePoint no navegador padrão.

**O que não foi testado:** relatórios de governança de acesso (permissões, atividade, detalhado de "Todos"), consultar/baixar relatório e ligar/desligar a coleta de atividade. O tenant de demo tem Office 365 E5 sem Copilot nem SharePoint Advanced Management, e o SharePoint recusa com *"experimental feature that is not supported in the current environment"*. O instalador transforma essa recusa no aviso "Bloqueado" (testado só com simulação).

**Também não testado:** a etapa de mudar o compartilhamento de um site.

**Para fechar:** rodar `testes-manuais/Teste-AUTO34.ps1` e o item no instalador num tenant com licença Microsoft 365 Copilot ou SharePoint Advanced Management.
