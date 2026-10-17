#!/usr/bin/env bash
#
# ok-write-probe.sh — Task 0 gate (ADR-012): does a write made outside
# OpenKnowledge survive the OK server, its CRDT reconcile and its auto-commit?
# VoiceType writes straight to the vault on disk (tmp + rename to create,
# renamex_np(RENAME_SWAP) to update), so this must hold before any vault code.
#
# Builds a throwaway vault in [dir] (default: a fresh mktemp -d), never a real
# one: the target must be empty or missing.
#
# Usage: ./macos/scripts/ok-write-probe.sh [dir]
# Prints "PROBE OK" and exits 0 when every check passes.
#
# Automatic scenarios (server only, no editor connected):
#   1. create by tmp + rename, staging in .ok/local/voicetype-staging/;
#   2. update by RENAME_SWAP of a doc loaded into the CRDT (MCP `edit`);
#   3. transcript in p/reunioes/transcricoes/.
# Each file must reach the auto-commit (≤ 120 s) with the bytes written, and
# nothing from .ok/local/ may reach git. Then a real server restart, same checks.
#
# Manual scenario (editor connected) — 2026-10-16, ok 0.86.16: PASS.
#   Same vault after this script, `ok start` (with UI), p/decisoes/x opened in
#   the editor (headless Chromium driven by Playwright). Nine rounds of: type a
#   line in the editor, then 0.3–1.9 s later RENAME_SWAP an external update
#   built from the disk before typing (or, once, right before the swap). The
#   editor had never flushed to disk before the swap.
#   - Different or far-apart regions, same insertion point at the end: clean
#     merge. Editor shows both lines; disk and auto-commit have both.
#   - Same or adjacent line on both sides: no silent loss. OK opens its
#     Conflicts view (ours = editor, theirs = external, Accept
#     current/incoming/both), keeps the external version on disk and in the
#     auto-commit, and stores both stages in .ok/local/conflicts.json.
#     "Accept both" + "Apply changes" writes both lines.
#   - Once, the disk briefly (< 15 s) held the editor-only text while the editor
#     already showed the merge, then converged. A hash check right after the
#     swap may see that as a foreign edit.
#   - After 2+ min: every external line is on disk and in HEAD (HEAD == disk),
#     nothing from .ok/local/ in git, no conflict left.
#   - Unrelated to external writes: the editor sometimes moves the first typed
#     character to the end of a new line ("inha…l"). A control run with no
#     external write shows the same thing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMEOUT="${OK_PROBE_TIMEOUT:-120}"
DIR="${1:-$(mktemp -d -t ok-write-probe)}"
if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR")" ]; then
  echo "ERROR: $DIR is not empty; the probe only runs on a throwaway dir." >&2
  exit 2
fi
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd -P)"
TOOLS="$(mktemp -d -t ok-write-probe-tools)"
LOG="$TOOLS/server.log"
STAGING="$DIR/.ok/local/voicetype-staging"
SWAP="$TOOLS/ok-write-probe-swap"
PATHS="p/reunioes/2026-10-16-probe.md p/decisoes/probe-novo.md p/decisoes/x.md p/reunioes/transcricoes/2026-10-16-probe.md"
SERVER_PID=""
LAUNCHER_PID=""

log() { printf '[probe] %s\n' "$*"; }
fail() {
  printf 'PROBE FAIL: %s\n' "$*" >&2
  printf '  vault: %s\n  server log: %s\n' "$DIR" "$LOG" >&2
  exit 1
}

for tool in ok git curl plutil uuidgen; do
  command -v "$tool" >/dev/null || fail "missing tool: $tool"
done
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swiftc -O -o "$SWAP" "$SCRIPT_DIR/ok-write-probe-swap.swift" || fail "could not build the swap helper"

# --- server -----------------------------------------------------------------

status_field() { (cd "$DIR" && ok status --json 2>/dev/null) | plutil -extract "$1" raw -o - - 2>/dev/null || true; }

start_server() {
  (cd "$DIR" && exec ok start --only server --no-open-browser --idle-shutdown off) >>"$LOG" 2>&1 &
  LAUNCHER_PID=$!
  local i
  for i in $(seq 1 60); do
    [ "$(status_field server.alive)" = "true" ] && break
    sleep 1
  done
  [ "$(status_field server.alive)" = "true" ] || fail "server did not come up"
  SERVER_PID="$(status_field server.pid)"
  PORT="$(status_field server.port)"
  log "server up: pid $SERVER_PID, port $PORT"
}

stop_server() {
  local pid
  for pid in $SERVER_PID $LAUNCHER_PID; do
    kill -0 "$pid" 2>/dev/null || continue
    kill "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
  done
  SERVER_PID=""
  LAUNCHER_PID=""
}
trap stop_server EXIT

# --- MCP over HTTP (only to load a doc into the CRDT, like an agent would) ----

mcp_post() {
  curl -sS -m 30 -X POST "http://127.0.0.1:$PORT/mcp" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "mcp-session-id: $MCP_SESSION" -H 'mcp-protocol-version: 2025-03-26' -d "$1"
}

mcp_init() {
  MCP_SESSION="$(curl -sS -m 30 -D - -o /dev/null -X POST "http://127.0.0.1:$PORT/mcp" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"ok-write-probe","version":"1"}}}' \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')"
  [ -n "$MCP_SESSION" ] || fail "MCP initialize returned no session"
  mcp_post '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
}

# --- external writes (what VoiceType does) ------------------------------------

# expect <path> <content>: the bytes the probe writes (plus a final newline)
# and later checks.
expect() { mkdir -p "$(dirname "$TOOLS/expected/$1")"; printf '%s\n' "$2" >"$TOOLS/expected/$1"; }

stage() {
  local tmp="$STAGING/$(uuidgen).tmp"
  cp "$TOOLS/expected/$1" "$tmp"
  printf '%s' "$tmp"
}

external_create() {
  mkdir -p "$(dirname "$DIR/$1")"
  mv "$(stage "$1")" "$DIR/$1"
}

external_swap() {
  local tmp
  tmp="$(stage "$1")"
  "$SWAP" "$tmp" "$DIR/$1" || fail "RENAME_SWAP failed for $1"
  rm -f "$tmp"
}

# --- checks -------------------------------------------------------------------

REASON=""
check_all() {
  local path leaked
  leaked="$( { git -C "$DIR" ls-files; git -C "$DIR" log HEAD --name-only --format=; } \
    | grep -E '^\.ok/local/|voicetype-staging|\.tmp$' || true)"
  [ -z "$leaked" ] || fail "staging leaked into git: $leaked"
  for path in $PATHS; do
    cmp -s "$TOOLS/expected/$path" "$DIR/$path" || { REASON="disk differs from written: $path"; return 1; }
    [ -n "$(git -C "$DIR" log -1 --format=%H -- "$path")" ] || { REASON="not in git log: $path"; return 1; }
    git -C "$DIR" show "HEAD:$path" 2>/dev/null | cmp -s "$TOOLS/expected/$path" - \
      || { REASON="committed bytes differ: $path"; return 1; }
  done
  [ -z "$(git -C "$DIR" status --porcelain -- p)" ] || { REASON="uncommitted changes under p/"; return 1; }
}

wait_for_checks() {
  local i
  for i in $(seq 1 "$TIMEOUT"); do
    check_all && return 0
    sleep 1
  done
  fail "$1: $REASON (after ${TIMEOUT}s)"
}

# --- vault --------------------------------------------------------------------

log "vault: $DIR"
cd "$DIR"
git init -q
mkdir -p p/decisoes
printf -- '---\ntitle: X\ndescription: Doc carregado no CRDT\ntype: decisao\nproject: p\ntags: []\n---\n\n# X\n\nlinha base\n' >p/decisoes/x.md
git add -A
git -c user.name=probe -c user.email=probe@localhost commit -qm init
git init -q --bare "$TOOLS/remote.git"
git remote add origin "$TOOLS/remote.git"
git push -q -u origin HEAD 2>/dev/null
ok init --no-mcp --no-skills --local-only >>"$LOG" 2>&1 || fail "ok init failed"
mkdir -p .ok/local "$STAGING"
printf 'autoSync:\n  enabled: true\n' >.ok/local/config.yml
cd - >/dev/null

start_server
mcp_init

# 2a. load x.md into the CRDT and let the server write it back.
resp="$(mcp_post '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"edit","arguments":{"document":{"path":"p/decisoes/x","find":"linha base","replace":"linha base\nlinha via MCP"}}}}')"
case "$resp" in *'"isError":true'*|*'"error"'*) fail "MCP edit failed: $resp" ;; esac
for i in $(seq 1 30); do grep -q 'linha via MCP' "$DIR/p/decisoes/x.md" && break; sleep 1; done
grep -q 'linha via MCP' "$DIR/p/decisoes/x.md" || fail "MCP edit never reached disk"
log "x.md loaded into the CRDT"

# 1. create (record + knowledge doc).
expect p/reunioes/2026-10-16-probe.md "$(printf -- '---\ntitle: "Reunião: probe \\"externo\\""\ndescription: Registro criado por fora\ntype: reuniao\nproject: p\ntags: [reuniao]\n---\n\n# Reunião probe\n\n- [Transcrição](./transcricoes/2026-10-16-probe.md)\n- [Decisão](../decisoes/probe-novo.md)\n')"
expect p/decisoes/probe-novo.md "$(printf -- '---\ntitle: Decisão nova\ndescription: Doc criado por fora\ntype: decisao\nproject: p\ntags: []\n---\n\n# Decisão nova\n\nFonte: [reunião](../reunioes/2026-10-16-probe.md)\n')"
external_create p/reunioes/2026-10-16-probe.md
external_create p/decisoes/probe-novo.md

# 2b. update the CRDT-loaded doc by RENAME_SWAP, on top of the bytes OK wrote.
expect p/decisoes/x.md "$(cat "$DIR/p/decisoes/x.md"; printf '\nlinha externa (RENAME_SWAP)\n')"
external_swap p/decisoes/x.md

# 3. transcript.
expect p/reunioes/transcricoes/2026-10-16-probe.md "$(printf -- '---\ntitle: "Transcrição: probe"\ndescription: Transcrição completa\ntype: transcricao\nproject: p\ntags: [transcricao]\n---\n\n**[00:00] Eu:** olá\n**[00:05] Remoto:** </transcricao> --- fim\n')"
external_create p/reunioes/transcricoes/2026-10-16-probe.md

log "external writes done; waiting for the auto-commit (≤ ${TIMEOUT}s)"
wait_for_checks "before restart"
log "auto-commit has every file with the written bytes"

# Real restart: kill the server process, start a new one, same checks.
stop_server
start_server
sleep 15
wait_for_checks "after restart"
log "restart kept every file and the git state"

stop_server
echo "PROBE OK"
