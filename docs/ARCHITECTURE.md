# Architecture

AI Usage Menu is a small SwiftUI menu bar application with three layers.

## UI

`MyApp.swift` owns a single `UsageStore` and exposes `ContentView` through `MenuBarExtra`. `ContentView` renders three summary cards and an optional detail panel. Views receive immutable provider snapshots and do not invoke CLIs directly.

## State and scheduling

`UsageStore` is a main-actor `@Observable` type. It:

- starts an initial refresh;
- refreshes every five minutes;
- refreshes on panel open when the last successful reading is older than one minute;
- runs collectors concurrently;
- applies results as each provider finishes;
- keeps the last valid provider snapshot when a later refresh fails.

All displayed percentages use the same convention: collectors store the percentage used, while the UI derives and displays the percentage remaining.

## Collectors

Each provider implements the `UsageCollector` protocol and returns a `ProviderUsage` value.

- `CodexCollector` communicates through newline-delimited JSON-RPC with `codex app-server`.
- `ClaudeCollector` launches Claude Code in a pseudo-terminal, enters `/usage`, cleans terminal control sequences, and parses the latest rendered values.
- `GeminiCollector` launches `agy` in a pseudo-terminal, enters `/quota`, and parses all quota groups that fit in the expanded terminal.

`CLISupport.swift` centralizes executable discovery, the minimal child-process environment, private working directories, pseudo-terminal handling, and terminal text cleanup.

## Failure model

Collectors fail independently. A failure before the first successful reading produces an unavailable provider with a user-visible reason. A later failure does not discard the last valid values. The global successful-refresh timestamp advances only when at least one collector succeeds.

## Adding a provider

1. Implement `UsageCollector` with a stable `providerID`.
2. Return session and weekly limits first, followed by model-specific limits.
3. Add a placeholder to `ProviderUsage.placeholders`.
4. Register the collector in `UsageStore.init`.
5. Add captured-output parser tests before relying on terminal output in production.

Collectors must remain read-only: do not send model prompts, mutate account settings, or read credential files directly.

