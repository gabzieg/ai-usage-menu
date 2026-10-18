# Privacy and security

## Data handled

AI Usage Menu processes only the data returned or drawn by the locally installed provider CLIs during a quota lookup:

- provider and plan names;
- used/remaining quota percentages;
- reset dates and durations;
- local collector errors.

These values remain in application memory. The current version does not persist usage history, include analytics, contact an application backend, or contain an advertising SDK.

## Credentials

The app does not request, import, copy, parse, or store account passwords, API keys, cookies, or OAuth tokens. Authentication remains owned by `codex`, `claude`, and `agy`. Child processes receive a minimal environment containing basic user and terminal variables; unrelated shell variables are not inherited.

Provider CLIs may make their own network requests and may update files they own. Their behavior and privacy policies are outside this project's control.

## Local execution

The app launches executables only when they are found in a fixed list of common installation directories. It does not evaluate shell strings or run through a shell. Claude and Gemini run in provider-specific directories under Application Support so that project trust prompts and generated files do not touch the user's source repositories.

App Sandbox is disabled because sandboxing would prevent the app from locating arbitrary user-installed CLIs and reusing their existing authentication state. This makes code review and trusted distribution especially important.

## Reporting concerns

Do not include credentials, raw authentication files, or complete terminal captures in a public issue. Follow [SECURITY.md](../SECURITY.md) for sensitive reports.

