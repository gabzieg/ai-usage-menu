# AI Usage Menu

Aplicativo nativo e compacto para a barra de menus do macOS. Ele mostra quanto ainda está disponível na sessão e na semana para Codex, Claude e Gemini.

O app reutiliza as contas já autenticadas nos clientes de linha de comando. Ele não pede chaves de API, não copia tokens de login, não envia prompts e não consome tokens dos modelos ao atualizar os dados.

> [!IMPORTANT]
> Este é um projeto comunitário não oficial, sem vínculo com OpenAI, Anthropic ou Google. A saída dos CLIs e os protocolos locais podem mudar sem aviso e interromper temporariamente algum coletor.

## Requisitos

- macOS 14 ou mais recente
- Xcode 26 ou mais recente para compilar
- Um ou mais clientes instalados e autenticados: `codex`, `claude` e `agy`

## Como executar

1. Clone o repositório.
2. Abra `Untitled Project.xcodeproj` no Xcode.
3. Selecione o scheme `Untitled Project`.
4. Compile e execute o app para macOS.

O produto compilado se chama **AI Usage Menu**. O nome interno do projeto foi preservado nesta primeira versão pública para evitar uma migração ruidosa do arquivo de projeto.

## Como a captura funciona

| Provedor | Fonte local | Informação consultada |
| --- | --- | --- |
| Codex | `codex app-server` | Método JSON-RPC `account/rateLimits/read` |
| Claude | `claude` | Tela somente de leitura `/usage` em pseudoterminal |
| Gemini | `agy` | Tela `/quota` em pseudoterminal |

As credenciais continuam sob responsabilidade de cada CLI. O app interpreta somente percentuais, nomes dos limites, plano e horários de renovação. Consulte [Privacidade e segurança](PRIVACY.md) para detalhes.

## Atualização dos dados

Os coletores são executados ao iniciar, a cada cinco minutos e quando o painel é aberto com dados de mais de um minuto. Se uma atualização falhar, a última leitura válida é preservada. Quando ainda não há leitura válida, clique no cartão do provedor para ver o erro.

## Limitações conhecidas

- Claude e Gemini dependem do formato visual dos respectivos terminais.
- O coletor Gemini usa atualmente a tela de quotas do cliente `agy`/Antigravity.
- O App Sandbox precisa permanecer desativado para localizar e executar os CLIs locais.
- Ainda não existe atualização automática do aplicativo.
- Testes automatizados dos parsers ainda precisam ser adicionados.

O projeto usa a [licença MIT](../LICENSE).

