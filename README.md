# AI Usage Menu

Aplicativo nativo de barra de menus para macOS que exibe em tempo real as cotas de sessão (5h) e semanais do **Codex**, **Claude** e **Gemini**, além do **contexto das conversas ativas**, **consumo diário de tokens por projeto/sessão** e **status do ecossistema Friday**.

O app reutiliza as sessões já autenticadas nos clientes de linha de comando locais e lê arquivos locais de sessão/estado em modo somente-leitura — **sem pedir chaves de API, sem enviar prompts e sem gastar nenhum token**.

> [!IMPORTANT]
> Projeto comunitário não oficial, sem afiliação com OpenAI, Anthropic ou Google. Mudanças na saída das CLIs podem exigir ajustes nos coletores.

---

## O que o aplicativo mostra (v2)

- **Aba Cotas**
  - Disponibilidade da janela de 5 horas e semanal para **Codex** (cinza), **Claude** (laranja) e **Gemini** (azul).
  - Tempo restante até a renovação de cada janela e detalhamento por grupo de modelos.
  - Menor porcentagem restante sempre visível no ícone da barra de menus.
  - Banner de alerta rápido quando alguma sessão na Friday está aguardando você.
  - Lista de **Conversas Ativas** com tamanho atual do contexto.
- **Aba Sessões**
  - **Conversas Ativas** (Codex e Claude Code com processo vivo): lê os últimos 3 MB do transcript `.jsonl` de cada conversa aberta e exibe o tamanho atual do contexto com alertas em **300 mil tokens** (compactar na troca) e **500 mil tokens** (compactação imediata).
  - **Consumo do Dia** (`friday-usage`): total de tokens gastos no dia separados entre **Novo**, **Cache lido**, **Cache gravado** e **Saída**, custo em dólar declarado pelo Claude Code (`cost-state`) e detalhamento por projeto e por sessão.
- **Aba Friday**
  - **Esperando Você**: sessões travadas aguardando decisão (`friday-pending`) e correio não lido há mais de 30 minutos (`friday-mail`), além de mensagens aguardando sessões fechadas.
  - **Saúde & Backup**: status do `friday-doctor`, resultado da suíte de testes (`friday-test`) e progresso/último snapshot do backup criptografado no Drive (`friday-backup`).
  - **Jobs do Friday**: estado ao vivo dos `LaunchAgents` (`com.gbz.*`) via `launchctl`.

---

## Requisitos

- **macOS 14** ou superior
- **Xcode 26** ou superior para compilar a partir do código-fonte
- Pelo menos uma das CLIs suportadas instalada e autenticada:
  - `codex` (Codex CLI)
  - `claude` (Claude Code)
  - `agy` (Antigravity / Gemini)
- *(Opcional)* **Friday** instalada em `~/Friday` e `~/.local/state/friday-*` para preencher o histórico diário e a aba Friday.

O app procura os executáveis automaticamente em `~/.local/bin`, `~/.npm-global/bin`, `/opt/homebrew/bin` e `/usr/local/bin`.

---

## Passo a passo: Como compilar e rodar o aplicativo

### Opção A — Pelo Xcode

1. Clone o repositório:
   ```bash
   git clone https://github.com/gabzieg/ai-usage-menu.git
   cd ai-usage-menu
   ```
2. Abra o projeto no Xcode:
   ```bash
   open "Untitled Project.xcodeproj"
   ```
3. Selecione o esquema **Untitled Project** e o destino **My Mac**.
4. Pressione **Command-R** (`Run`) para compilar e abrir o **AI Usage Menu** na barra de menus.

### Opção B — Gerar e instalar em `/Applications` pelo Terminal

Para instalar uma versão independente em `/Applications/AI Usage Menu.app` (sem precisar manter o Xcode aberto):

```bash
xcodebuild -project "Untitled Project.xcodeproj" \
  -scheme "Untitled Project" \
  -configuration Release \
  -derivedDataPath build \
  build

cp -R "build/Build/Products/Release/AI Usage Menu.app" /Applications/
open "/Applications/AI Usage Menu.app"
```

---

## Passo a passo: Iniciar sempre junto com o Mac

Depois de copiar o `AI Usage Menu.app` para `/Applications`, você pode configurá-lo para iniciar automaticamente ao ligar o computador de duas maneiras:

### Método 1 — Pelos Ajustes do Sistema do macOS (Mais simples)

1. Abra os **Ajustes do Sistema** (*System Settings*).
2. Vá em **Geral** → **Itens de Início e Extensões** (*Login Items & Extensions*).
3. Na seção **Abrir no Início da Sessão** (*Open at Login*), clique no botão **`+`**.
4. Selecione **`/Applications/AI Usage Menu.app`** e clique em **Adicionar**.

### Método 2 — Criando um LaunchAgent (`launchctl`)

Se preferir gerenciar via `LaunchAgents` (no mesmo padrão dos jobs `com.gbz.*` da Friday, reiniciando automaticamente caso o processo seja fechado por engano):

1. Crie o arquivo `~/Library/LaunchAgents/com.gbz.ai-usage-menu.plist`:
   ```bash
   cat << 'EOF' > ~/Library/LaunchAgents/com.gbz.ai-usage-menu.plist
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>Label</key>
       <string>com.gbz.ai-usage-menu</string>
       <key>ProgramArguments</key>
       <array>
           <string>/Applications/AI Usage Menu.app/Contents/MacOS/AI Usage Menu</string>
       </array>
       <key>RunAtLoad</key>
       <true/>
       <key>KeepAlive</key>
       <false/>
       <key>ProcessType</key>
       <string>Interactive</string>
   </dict>
   </plist>
   EOF
   ```
2. Carregue e ative a tarefa no `launchctl`:
   ```bash
   launchctl unload ~/Library/LaunchAgents/com.gbz.ai-usage-menu.plist 2>/dev/null || true
   launchctl load ~/Library/LaunchAgents/com.gbz.ai-usage-menu.plist
   ```

Para desativar no futuro, basta rodar:
```bash
launchctl unload ~/Library/LaunchAgents/com.gbz.ai-usage-menu.plist
rm ~/Library/LaunchAgents/com.gbz.ai-usage-menu.plist
```

---

## Autenticação e acesso aos dados

O AI Usage Menu nunca faz login por conta própria nem consome tokens de modelos:

| Fonte | Comando / Arquivo local | Operação de leitura |
| --- | --- | --- |
| **Codex (Cota)** | `codex app-server` | Requisição JSON-RPC `account/rateLimits/read` |
| **Claude (Cota)** | `claude` | Abre a tela `/usage` em pseudo-terminal somente-leitura |
| **Gemini (Cota)** | `agy` | Abre a tela `/quota` em pseudo-terminal somente-leitura |
| **Conversas Ativas** | `~/.local/state/friday-sessions/*.json`<br>`~/.claude/sessions/*.json` | Verifica `pid` vivo (`kill -0`) e lê os últimos 3 MB do `.jsonl` da conversa |
| **Consumo & Friday** | `~/.local/state/friday-*`<br>`~/Library/Logs/friday-*.state` | Lê os JSONs locais gerados pelos serviços da Friday |

---

## Comportamento de atualização

- As leituras locais (conversas ativas e estado da Friday) são atualizadas instantaneamente ao abrir o painel (com cache de 60 segundos) e a cada clique em **Atualizar**.
- Os coletores de cota das CLIs rodam em paralelo ao iniciar o app, a cada 5 minutos e ao abrir o painel quando a última leitura tem mais de 1 minuto.

---

## Documentação do projeto

- [Architecture](docs/ARCHITECTURE.md)
- [Privacy and security](docs/PRIVACY.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## Licença

Distribuído sob a [MIT License](LICENSE).
