# Contributing

Contributions are welcome, especially parser fixtures, tests, and compatibility fixes for new CLI versions.

## Development

1. Fork and clone the repository.
2. Open `Untitled Project.xcodeproj` in Xcode 26 or newer.
3. Build the `Untitled Project` scheme for macOS.
4. Authenticate only test accounts in the provider CLIs when capturing terminal output.

## Pull requests

- Keep collectors read-only and never send a model prompt.
- Never commit credentials, login databases, cookies, API keys, or unredacted account identifiers.
- Preserve stable IDs for providers and limits.
- Keep UI work compact and accessible in both light and dark appearance.
- Explain which CLI version and output shape a parser change supports.
- Confirm the project builds without warnings before opening a pull request.

Terminal captures used as test fixtures must be synthetic or thoroughly redacted. Replace names, emails, identifiers, paths, and timestamps while retaining the structure required by the parser.

## Commit scope

Prefer focused changes. A compatibility fix for one provider should not reformat unrelated collectors or redesign the interface.

