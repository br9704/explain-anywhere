# Contributing

Thanks for helping. Explain Anywhere is deliberately small, so the bar for a change is: does it make the quick "what does this mean?" moment better without making the project harder to read?

## Ground rules

- **One Swift file.** The app lives in `Sources/main.swift`. Keep it that way unless a split clearly helps reading.
- **Apple frameworks only.** No third-party packages, no Xcode project, no package manager.
- **Model output is text, never HTML.** Anything Claude returns must reach the page through `textContent` or the existing render helpers. Pull requests that insert model output as HTML will not be merged.
- **No new network calls** beyond the Claude Code CLI and the optional user-configured webhook.
- **Respect Reduce Motion.** New motion needs a plain-fade fallback.

## Set up

```zsh
git clone https://github.com/br9704/explain-anywhere.git
cd explain-anywhere
xcrun swiftc -O -swift-version 5 Sources/main.swift -o build/Explain -framework Cocoa -framework WebKit
./build/Explain --text "idempotency key"
```

Install the full app with `./install.sh`. It never overwrites an existing `~/.config/explain-anywhere/config.json`.

## Before you open a pull request

1. Build cleanly with the `swiftc` command above (no new warnings).
2. Run ShellCheck on any script you touched: `shellcheck -s bash install.sh uninstall.sh scripts/*`.
3. Check the panel headlessly: `./build/Explain --offscreen /tmp/shots --text "vector index"` and look at the PNGs.
4. If you changed something visible, attach a before and after screenshot.
5. Update `CHANGELOG.md` under "Unreleased".

## Reporting bugs and asking for features

Use the issue templates. For security problems, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Style

- Plain, short user-facing text. Error messages say what happened and what to do next.
- Swift: follow the style already in the file (4-space indent, small functions, comments that explain why).
- Commits: one logical change per commit, written in the imperative ("Add light appearance").

By contributing you agree that your work is released under the [MIT License](LICENSE) and that you will follow the [Code of Conduct](CODE_OF_CONDUCT.md).
