#!/bin/sh
# Checks for the Meilynx plugin for Claude Code, run by
# .github/workflows/plugin-checks.yml on every pull request and locally with
# `sh tests/run.sh`.
#
# 1. The pinned adapter release (adapter/RELEASE, adapter/SHA256SUMS) is well
#    formed and pins a checksum for every build the hook runner can ask for.
# 2. The hook runner fails closed: a missing pin, a non-https location, a
#    download that does not match its checksum or an unsafe proxy URL denies
#    the tool call, and only a verified adapter is ever run.

set -u

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FAILED=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILED=1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

# ── 1. the pinned release ───────────────────────────────────────────────────

VERSION=$(sed -n 's/^version=//p' "$REPO/adapter/RELEASE" | head -n 1)
BASE_URL=$(sed -n 's/^base_url=//p' "$REPO/adapter/RELEASE" | head -n 1)
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) pass "RELEASE names version $VERSION" ;;
  *) bad "RELEASE has no version=<x.y.z> line" ;;
esac
case "$BASE_URL" in
  "https://github.com/Meilynx/meilynx-claude-plugin/releases/download/meilynx-hook-v$VERSION")
    pass "RELEASE points at this repository's meilynx-hook-v$VERSION release" ;;
  *) bad "RELEASE base_url is not this repository's meilynx-hook-v$VERSION release: $BASE_URL" ;;
esac

# Every target the hook runner maps (scripts/meilynx-hook-run) needs a pin.
for T in aarch64-apple-darwin x86_64-apple-darwin x86_64-unknown-linux-musl \
         aarch64-unknown-linux-musl x86_64-pc-windows-msvc.exe; do
  F="meilynx-hook-$VERSION-$T"
  if awk -v f="$F" '$2 == f || $2 == "*" f { found = 1 } END { exit !found }' "$REPO/adapter/SHA256SUMS"; then
    pass "SHA256SUMS pins $F"
  else
    bad "SHA256SUMS pins no checksum for $F"
  fi
done
if grep -v '^#' "$REPO/adapter/SHA256SUMS" | grep -v '^$' \
  | grep -Ev '^[0-9a-f]{64} [ *]meilynx-hook-[^ ]+$' >/dev/null; then
  bad "SHA256SUMS has a line that is not '<64 hex> <file>'"
else
  pass "every SHA256SUMS line is '<64 hex> <file>'"
fi

# ── 2. the hook runner fails closed ─────────────────────────────────────────

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A stand-in adapter: prints what it was given so the tests can check it.
cat > "$WORK/adapter" <<'EOF'
#!/bin/sh
printf 'args=%s cred=%s url=%s leaked=%s\n' "$*" "${MEILYNX_HOOK_CREDENTIAL:-}" \
  "${MEILYNX_HOOK_PROXY_URL:-}" "${CLAUDE_PLUGIN_OPTION_CREDENTIAL:-}"
EOF
GOOD_SUM=$(sha256_of "$WORK/adapter")
echo 'not the adapter' > "$WORK/tampered"

# plugin <name> <base_url> <checksum or empty>: a copy of the plugin whose
# release points at <base_url> and pins <checksum> for every target.
plugin() {
  P="$WORK/$1"
  mkdir -p "$P/adapter" "$P/scripts" "$P/mirror"
  cp "$REPO/scripts/meilynx-hook-run" "$P/scripts/"
  printf 'version=9.9.9\nbase_url=%s\n' "$2" > "$P/adapter/RELEASE"
  : > "$P/adapter/SHA256SUMS"
  if [ -n "$3" ]; then
    for T in aarch64-apple-darwin x86_64-apple-darwin x86_64-unknown-linux-musl \
             aarch64-unknown-linux-musl x86_64-pc-windows-msvc.exe; do
      printf '%s  meilynx-hook-9.9.9-%s\n' "$3" "$T" >> "$P/adapter/SHA256SUMS"
    done
  fi
}

# serve <name> <file>: put <file> in the copy's mirror under every target name.
serve() {
  for T in aarch64-apple-darwin x86_64-apple-darwin x86_64-unknown-linux-musl \
           aarch64-unknown-linux-musl x86_64-pc-windows-msvc.exe; do
    cp "$2" "$WORK/$1/mirror/meilynx-hook-9.9.9-$T"
  done
}

# run <name> <mode>: run the copy's hook runner; sets OUT, ERR and CODE.
run() {
  CLAUDE_PLUGIN_ROOT="$WORK/$1" CLAUDE_PLUGIN_DATA="$WORK/$1/data" \
    sh "$WORK/$1/scripts/meilynx-hook-run" "$2" > "$WORK/out" 2> "$WORK/err" < /dev/null
  CODE=$?
  OUT=$(cat "$WORK/out")
  ERR=$(cat "$WORK/err")
}

expect_deny() {
  # $1: test name, $2: text the reason must contain.
  if [ "$CODE" -eq 2 ] && printf '%s' "$ERR" | grep -q "$2"; then
    pass "$1"
  else
    bad "$1 (exit $CODE, stderr: $ERR)"
  fi
}

plugin unknown "https://example.invalid" "$GOOD_SUM"
run unknown bogus
expect_deny "an unknown mode denies the call" "unknown mode"

plugin nopin "https://example.invalid" ""
run nopin pre
expect_deny "a build with no pinned checksum is denied" "pins no checksum"

plugin plainhttp "http://example.invalid/r" "$GOOD_SUM"
run plainhttp pre
expect_deny "a non-https adapter location is denied" "must be an https"

plugin mismatch "file://$WORK/mismatch/mirror" "$GOOD_SUM"
serve mismatch "$WORK/tampered"
run mismatch pre
expect_deny "a download that does not match its checksum is denied" "does not match the pinned checksum"
if [ -n "$(find "$WORK/mismatch/data" -type f 2>/dev/null)" ]; then
  bad "the mismatched download was left on disk"
else
  pass "the mismatched download was deleted"
fi

plugin post "file://$WORK/post/mirror" "$GOOD_SUM"
serve post "$WORK/tampered"
run post post
if [ "$CODE" -eq 1 ]; then pass "a PostToolUse failure reports without blocking (exit 1)"
else bad "a PostToolUse failure exited $CODE, expected 1"; fi

plugin good "file://$WORK/good/mirror" "$GOOD_SUM"
serve good "$WORK/adapter"
CLAUDE_PLUGIN_OPTION_PROXY_URL="http://proxy.example.invalid" run good pre
expect_deny "a plain-http proxy URL is denied" "must start with https"

CLAUDE_PLUGIN_OPTION_PROXY_URL="https://px.example.invalid" \
  CLAUDE_PLUGIN_OPTION_CREDENTIAL="mx_test_secret" run good pre
if [ "$CODE" -eq 0 ] && \
   [ "$OUT" = "args=--host claude-code cred=mx_test_secret url=https://px.example.invalid leaked=" ]; then
  pass "a verified adapter runs, with the credential in its environment only"
else
  bad "the verified adapter did not run as expected (exit $CODE, stdout: $OUT, stderr: $ERR)"
fi

# A session start re-hashes the installed adapter and replaces a changed one.
BIN="$WORK/good/data/adapter/9.9.9/meilynx-hook"
cp "$WORK/tampered" "$BIN"
run good install
if [ "$CODE" -eq 0 ] && [ "$(sha256_of "$BIN")" = "$GOOD_SUM" ]; then
  pass "a session start replaces an installed adapter that no longer matches"
else
  bad "a changed installed adapter was not replaced (exit $CODE, stderr: $ERR)"
fi

[ "$FAILED" -eq 0 ] && echo "all checks passed"
exit "$FAILED"
