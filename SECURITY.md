# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: open the [Security tab](https://github.com/br9704/explain-anywhere/security) of this repository and choose **Report a vulnerability**. Do not open a public issue.

Include what you found, how to reproduce it, and the macOS and Claude Code versions you used. You should get a first reply within a week. Fixes are released as a new version and noted in the [changelog](CHANGELOG.md).

## Supported versions

Only the latest release is supported.

## Threat model

Explain Anywhere passes text you select, which may come from an untrusted web page or document, to a language model and shows the answer. The main risks are a hostile selection (prompt injection) and hostile model output. The design limits both.

**Model output is rendered as text only.** The panel is a local `WKWebView` page. Every field Claude returns is validated against a JSON schema, length-limited and inserted with text nodes (`textContent`), never as HTML. Script in an answer cannot run. Navigation away from the built-in page is blocked.

**The model gets no tools.** The CLI is started as `claude -p` with `--tools ""`, `--strict-mcp-config` and `--setting-sources ""`, so no tools, MCP servers, hooks or project settings are loaded. A selection that says "read my files" or "run this command" has nothing to act with. It runs in the app's private cache folder with a minimal environment.

**Local temp file permissions.** The Quick Action passes the selection through a file, never on a command line where other processes could read it. The file is created with `mktemp` in `~/Library/Caches/explain-anywhere`, a folder set to mode `0700`, and the app deletes it as soon as it has read it. Selections are capped at 24,000 bytes by the launcher and 6,000 characters by the app.

**What leaves your Mac.** The selection and any follow-up go to Anthropic through your own Claude Code login. Nothing else is sent unless you set `webhookURL`, in which case each lookup is posted to that URL. The optional webhook token is read from a file you choose and never logged.

**Files it writes.** An optional Markdown log (`logFile`) and notes you save (`notesDir`), both plain local files in places you configure.

## Out of scope

- The behaviour and data handling of Claude Code and Anthropic's service.
- A compromised Mac or user account.
- The prebuilt release app is ad-hoc signed and not notarized. If you need to trust the binary, build it from source.
