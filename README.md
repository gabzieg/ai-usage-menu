# AI Usage Menu

A compact, native macOS menu bar app that shows the remaining session and weekly usage for Codex, Claude, and Gemini.

The app reuses the accounts already authenticated in local command-line clients. It does not ask for API keys, copy login tokens, send prompts, or consume model tokens to refresh the display.

> [!IMPORTANT]
> This is an unofficial community project. It is not affiliated with OpenAI, Anthropic, or Google. CLI output and private/local protocols can change without notice and may temporarily break a collector.

## What it shows

- Session and weekly availability at a glance
- Time remaining until each limit resets
- Model-specific limits when the provider exposes them
- The lowest remaining quota directly in the menu bar
- Codex in gray, Claude in orange, and Gemini in blue

## Requirements

- macOS 14 or newer
- Xcode 26 or newer to build from source
- At least one supported CLI installed and logged in:
  - `codex` for Codex
  - `claude` for Claude Code
  - `agy` for Gemini/Antigravity quotas

The app searches common executable locations such as `~/.local/bin`, `~/.npm-global/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`.

## Build and run

1. Clone the repository.
2. Open `Untitled Project.xcodeproj` in Xcode.
3. Select the `Untitled Project` scheme.
4. Build and run the macOS app.

The built product is named **AI Usage Menu**. The internal Xcode project and target names are still retained to avoid a noisy project-file migration in the first public version.

No developer account is required for a local Debug build. Distribution requires your own signing identity and bundle identifier.

## Authentication and data access

AI Usage Menu never performs a new login. Authenticate with each CLI normally before opening the app. The collectors then invoke those local clients with a minimal environment:

| Provider | Local command | Read operation |
| --- | --- | --- |
| Codex | `codex app-server` | `account/rateLimits/read` JSON-RPC request |
| Claude | `claude` | Opens the read-only `/usage` screen in a pseudo-terminal |
| Gemini | `agy` | Opens the `/quota` screen in a pseudo-terminal |

Only quota values, plan labels, and reset times are parsed. No prompt is submitted. Credentials remain managed by each provider's CLI. See [Privacy](docs/PRIVACY.md) for the complete data flow.

## Refresh behavior

Collectors run independently when the app starts, every five minutes, and when the panel opens with data older than one minute. A failed refresh keeps the last valid reading. If no valid reading exists, selecting the provider card shows the collector error.

## Known limitations

- Claude and Gemini collectors parse terminal interfaces. UI changes in their CLIs can require parser updates.
- The Gemini collector currently targets the quota view exposed by the `agy` Antigravity client.
- The app must run without App Sandbox so it can locate and launch locally installed CLIs and let them access their existing authentication state.
- There is no release updater yet. GitHub Releases and repository notifications are the source of update information.
- Automated parser tests have not been added yet; captured output fixtures are the highest-priority testing contribution.

## Project documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Privacy and security](docs/PRIVACY.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

Released under the [MIT License](LICENSE).

