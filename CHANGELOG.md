# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-22

First public release.

### Added

- Floating, non-activating panel that explains selected text from any app via a macOS Quick Action (Control+Shift+I or right-click > Services).
- Structured answers from `claude -p` with a JSON schema: plain explanation, example, optional code, optional flow diagram, related terms.
- Follow-up questions in place, clickable related terms, pin, stack, drag, and save as a Markdown note.
- Optional Markdown log with automatic trimming, and an optional webhook with bearer token.
- Safe rendering: model output is inserted as text only; the CLI runs with no tools, MCP servers or settings.
- Motion that follows the system, with a plain-fade fallback under Reduce Motion.
- `--offscreen` headless rendering and `--frames` for screenshots and the demo animation.
- App icon, `scripts/build-app.sh`, installer and uninstaller.
- Prebuilt, unsigned release zip (`scripts/package-release.sh`); `install.sh` installs it without the Swift compiler.
- CI that compiles the app and runs ShellCheck on the scripts.

[Unreleased]: https://github.com/br9704/explain-anywhere/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/br9704/explain-anywhere/releases/tag/v0.1.0
