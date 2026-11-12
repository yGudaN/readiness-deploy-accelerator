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
