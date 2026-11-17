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
