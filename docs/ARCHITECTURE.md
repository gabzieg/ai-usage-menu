# Architecture

AI Usage Menu is a SwiftUI macOS menu bar application with three layers.

## UI

`MyApp.swift` owns a single `UsageStore` and exposes `ContentView` through `MenuBarExtra`. `ContentView` organizes the interface into three tabs:

- **Cotas**: renders three provider summary cards (`Codex`, `Claude`, `Gemini`), an expandable provider detail panel, a compact alert banner when Friday items await user input, and the live active conversations list.
- **Sessões**: displays open CLI sessions with their current context token usage (`300k` soft / `500k` hard thresholds) and daily token consumption by project and session (`friday-usage`).
- **Friday**: displays pending prompts and unread mail (`friday-pending`, `friday-mail`), health and backup status (`friday-doctor`, `friday-test`, `friday-backup`), and `com.gbz.*` `LaunchAgents`.

Views receive immutable snapshots from `UsageStore` and do not invoke CLIs or read files directly.

## State and scheduling

`UsageStore` is a main-actor `@Observable` type. It:

- starts an initial refresh;
- refreshes every five minutes;
- refreshes on panel open when the last reading is older than one minute (matching Friday's 60-second snapshot cache);
- updates fast local collectors (`ActiveConversationCollector` and `FridayStateCollector`) immediately before waiting on slower terminal collectors;
- runs provider collectors concurrently and applies each result as it finishes;
- keeps the last valid provider snapshot when a later refresh fails.

All displayed quota percentages use the same convention: collectors store the percentage used, while the UI derives and displays the percentage remaining.

## Collectors

### Provider Quota Collectors (`UsageCollector`)

Each provider implements the `UsageCollector` protocol and returns a `ProviderUsage` value:

- `CodexCollector` communicates through newline-delimited JSON-RPC with `codex app-server`.
- `ClaudeCollector` launches Claude Code in a pseudo-terminal, enters `/usage`, cleans terminal control sequences, and parses the latest rendered values.
- `GeminiCollector` launches `agy` in a pseudo-terminal, enters `/quota`, and parses all quota groups that fit in the expanded terminal.

`CLISupport.swift` centralizes executable discovery, the minimal child-process environment, private working directories, pseudo-terminal handling, and terminal text cleanup.

### Local Session & Friday Collectors

- `ActiveConversationCollector` replicates `friday_context.py`: checks live PIDs (`kill(pid, 0)`) in `~/.local/state/friday-sessions/*.json` and `~/.claude/sessions/*.json`, and reads at most the last 3 MB of each `.jsonl` transcript to compute current context tokens.
- `FridayStateCollector` reads local JSON and plist state from `~/.local/state/friday-usage/usage.json`, `~/.local/state/friday-pending`, `~/.local/state/friday-mail`, `~/Library/Logs/friday-*.state`, and `~/Library/LaunchAgents/com.gbz.*.plist`.

## Failure model

Collectors fail independently. A failure before the first successful reading produces an unavailable provider with a user-visible reason. A later failure does not discard the last valid values. The global successful-refresh timestamp advances only when at least one collector succeeds.

## Adding a provider

1. Implement `UsageCollector` with a stable `providerID`.
2. Return session and weekly limits first, followed by model-specific limits.
3. Add a placeholder to `ProviderUsage.placeholders`.
4. Register the collector in `UsageStore.init`.
5. Add captured-output parser tests before relying on terminal output in production.

Collectors must remain read-only: do not send model prompts, mutate account settings, or read credential files directly.
