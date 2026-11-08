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
