#!/usr/bin/env bash
# Shannon (Claude Code native) — one-command installer.
#
# Makes `/pentest <url>` available in EVERY Claude Code session (any project dir),
# white-box auto-detected from the current directory — no more cloning the repo,
# rooting a session inside it, or symlinking your source in.
#
# What it does (all user-global, idempotent, with backups taken first):
#   1. Installs the tool payload (the shannon-tools MCP server) to $SHANNON_HOME.
#   2. Copies the /pentest skill + the 13 agents + the audit hook into ~/.claude/.
#   3. Merges the ~57-entry security-tool permission allowlist + the audit hook
#      into ~/.claude/settings.json   (a Claude Code PLUGIN cannot carry these —
#      this is the load-bearing reason this is an installer, not a plugin).
#   4. Registers the playwright + shannon-tools MCP servers in ~/.claude.json.
#   5. Adds deliverables/ + audit-logs/ to your GLOBAL gitignore so a pentest run
#      never accidentally commits its output into the project you scan.
#
# Re-runnable: every mutation is idempotent and the prior files are backed up to
# <file>.shannon-bak.<utc-timestamp>. Never clobbers your existing config.
#
# Derivative of Shannon (https://github.com/KeygraphHQ/shannon), AGPL-3.0.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHANNON_HOME="${SHANNON_HOME:-$HOME/.shannon}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_JSON="$HOME/.claude.json"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

log()  { printf '  %s\n' "$*"; }
step() { printf '\n▶ %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 0 — never install as root (matches the skill's own non-root safety check).
[ "$(id -u)" -eq 0 ] && die "do not run as root/sudo — re-run as a normal user."

step "Preflight"
for bin in node npm jq; do command -v "$bin" >/dev/null 2>&1 || die "required tool not found: $bin"; done
node_major="$(node -p 'process.versions.node.split(".")[0]')"
[ "$node_major" -ge 18 ] || die "node >= 18 required (found $(node -v))"
command -v claude >/dev/null 2>&1 || log "warn: 'claude' (Claude Code) not on PATH — install it from claude.ai/code"
log "node $(node -v), npm $(npm -v), jq present"

step "Install tool payload → $SHANNON_HOME"
mkdir -p "$SHANNON_HOME"
rm -rf "$SHANNON_HOME/native"
cp -R "$SRC/native" "$SHANNON_HOME/native"
( cd "$SHANNON_HOME/native" && { npm ci --omit=dev --no-audit --no-fund 2>/dev/null || npm install --omit=dev --no-audit --no-fund; } ) \
  || die "MCP server dependency install failed (cd $SHANNON_HOME/native && npm install)"
MCP_ENTRY="$SHANNON_HOME/native/mcp-stdio-wrapper.mjs"
[ -f "$MCP_ENTRY" ] || die "MCP entrypoint missing: $MCP_ENTRY"
log "shannon-tools MCP installed + deps resolved"

step "Install skill + agents + hook → $CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR/skills" "$CLAUDE_DIR/agents" "$CLAUDE_DIR/hooks"
# /pentest skill (back up any existing copy first)
[ -e "$CLAUDE_DIR/skills/pentest" ] && { mv "$CLAUDE_DIR/skills/pentest" "$CLAUDE_DIR/skills/pentest.shannon-bak.$TS"; log "backed up existing skills/pentest"; }
cp -R "$SRC/.claude/skills/pentest" "$CLAUDE_DIR/skills/pentest"
# audit hook (namespaced filename so it can't clash)
HOOK_DEST="$CLAUDE_DIR/hooks/shannon-audit-logger.sh"
cp "$SRC/.claude/hooks/audit-logger.sh" "$HOOK_DEST"; chmod +x "$HOOK_DEST"
# the 13 agents (back up any same-named existing agent — names are generic:
# recon/report/vuln-*/exploit-*/pre-recon; namespacing them is a tracked follow-up)
ag_installed=0; ag_backed=0
for a in "$SRC/.claude/agents/"*.md; do
  name="$(basename "$a")"; dest="$CLAUDE_DIR/agents/$name"
  if [ -e "$dest" ] && ! cmp -s "$a" "$dest"; then cp "$dest" "$dest.shannon-bak.$TS"; ag_backed=$((ag_backed+1)); fi
  cp "$a" "$dest"; ag_installed=$((ag_installed+1))
done
log "installed /pentest skill + $ag_installed agents + audit hook ($ag_backed pre-existing agent(s) backed up)"

step "Merge permission allowlist + audit hook → $SETTINGS"
[ -f "$SETTINGS" ] && { cp "$SETTINGS" "$SETTINGS.shannon-bak.$TS"; log "backed up $SETTINGS"; } || echo '{}' > "$SETTINGS"
ALLOW="$(jq -c '.permissions.allow // []' "$SRC/.claude/settings.json")"
jq --argjson allow "$ALLOW" --arg hook "$HOOK_DEST" '
  .permissions = (.permissions // {})
  | .permissions.allow = (((.permissions.allow // []) + $allow) | unique)
  | .hooks = (.hooks // {})
  # idempotent: drop any prior shannon-audit PostToolUse entry, then add exactly one
  | .hooks.PostToolUse = (
      ((.hooks.PostToolUse // [])
        | map(select(((.hooks // []) | map(.command // "") | join(" ")) | contains("shannon-audit-logger") | not)))
      + [{matcher: "*", hooks: [{type: "command", command: $hook}]}]
    )
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
log "merged $(echo "$ALLOW" | jq 'length') allowlist entries (union) + audit hook"

step "Register MCP servers → $CLAUDE_JSON"
[ -f "$CLAUDE_JSON" ] && { cp "$CLAUDE_JSON" "$CLAUDE_JSON.shannon-bak.$TS"; log "backed up $CLAUDE_JSON"; } || echo '{}' > "$CLAUDE_JSON"
jq --arg mcp "$MCP_ENTRY" '
  .mcpServers = (.mcpServers // {})
  | .mcpServers.playwright = {command: "npx", args: ["@playwright/mcp@latest", "--headless"]}
  | .mcpServers["shannon-tools"] = {command: "node", args: [$mcp], env: {SHANNON_TARGET_DIR: "."}}
' "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
log "registered playwright + shannon-tools (white-box target = current dir)"

step "Keep pentest output out of your repos (global gitignore)"
GI="$(git config --global --get core.excludesfile 2>/dev/null || true)"; [ -z "$GI" ] && GI="$HOME/.config/git/ignore"
mkdir -p "$(dirname "$GI")"; touch "$GI"
for pat in 'deliverables/' 'audit-logs/' 'shannon.config.json'; do
  grep -qxF "$pat" "$GI" 2>/dev/null || echo "$pat" >> "$GI"
done
git config --global core.excludesfile "$GI" >/dev/null 2>&1 || true
log "added deliverables/ + audit-logs/ + shannon.config.json to $GI"

# Record the source location so `shannon update` knows where to git-pull.
echo "$SRC" > "$SHANNON_HOME/.source-path"

cat <<EOF

✅ Shannon installed. Restart Claude Code, then from ANY project directory:

   /pentest https://staging.example.com

White-box (source-aware) is automatic — it analyses the project you launch \`claude\` in.
For login/scope without retyping, drop a shannon.config.json next to your project
(see shannon.config.example.json). Health check: ./shannon doctor

⚠  Only run against systems you are authorised to test. Shannon runs real exploits.
EOF
