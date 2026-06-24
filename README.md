# Shannon — Claude Code native (one-command install)

Shannon's 5-phase penetration-testing pipeline, running natively in Claude Code — **no Docker, no Temporal**. This repo wraps it in a one-command installer so `/pentest <url>` works from **any** project directory, white-box auto-detected from the directory you launch Claude Code in.

> Derivative of [Shannon](https://github.com/KeygraphHQ/shannon) (KeygraphHQ, Inc.), **AGPL-3.0** — see [LICENSE](./LICENSE).

## Quick start

```bash
git clone https://github.com/Digital-Frontier-LDA/shannon-claude-code-plugin.git
cd shannon-claude-code-plugin
./install.sh
```

Then restart Claude Code and, **from any project**:

```
/pentest https://staging.example.com
```

That's it — no rooting a session in this repo, no symlinking your source in. White-box (source-aware) is automatic: it analyses whatever project directory you started `claude` in.

## What `install.sh` does (idempotent, backs up first)

| Step | Effect |
|---|---|
| Tool payload → `~/.shannon` | the `shannon-tools` MCP server + `npm ci` its deps (no lazy first-run install) |
| `~/.claude/skills/pentest` + `~/.claude/agents/*` + audit hook | makes `/pentest` + its 13 agents global |
| merge into `~/.claude/settings.json` | the ~57-entry security-tool permission allowlist (nmap/sqlmap/curl/…) + the audit hook — **the load-bearing reason this is an installer, not a Claude Code plugin: a plugin cannot ship a permission allowlist**, so without this you'd get a prompt per command |
| register in `~/.claude.json` | the `playwright` + `shannon-tools` MCP servers |
| global gitignore | adds `deliverables/`, `audit-logs/`, `shannon.config.json` so a run never commits its output into the repo you scan |

Every file it touches (`~/.claude/settings.json`, `~/.claude.json`, any same-named agent) is **backed up** to `<file>.shannon-bak.<utc>` first, and re-running is safe (idempotent merges, not appends).

## Run config (optional — no retyping)

Drop a `shannon.config.json` (copy [`shannon.config.example.json`](./shannon.config.example.json)) in the project you scan; `/pentest` auto-loads the target/login/scope. Inline `/pentest` args override it. **Secrets go in env vars** (`password_env` / `totp_secret_env`), never in the file (which is gitignored anyway).

## Helper

```bash
./shannon doctor      # check node/npm/jq/claude + optional scanners + what's installed
./shannon update      # git pull + re-run install.sh
./shannon uninstall   # remove the global skill/agents/hook/MCP (config backups are kept)
```

## Optional scanners

The pipeline uses these if present and silently skips them if not: `nmap`, `subfinder`, `whatweb`, `sqlmap`, `oathtool` (TOTP). `./shannon doctor` reports which are installed.

## ⚠ Authorisation

Shannon runs **real exploits**. Only point it at systems you are authorised to test (e.g. your own staging). It refuses to run as root.

## Why an installer, not a plugin?

A Claude Code plugin distributes skills/agents/MCP cleanly — but it **cannot** carry the `settings.json` permission allowlist that lets the security tools run without a prompt per command. Since an installer is needed for that regardless, a plugin would just add a second release surface without removing the setup step. So this ships as a single idempotent installer that also makes `/pentest` global and self-updates. (Decision reached by multi-model review.)
