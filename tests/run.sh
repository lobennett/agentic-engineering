#!/usr/bin/env bash
# Offline tests for setup.sh.
#
# Every test runs setup.sh inside a throwaway HOME with a hermetic PATH: real
# git/curl/jq, plus stub gh, node, herdr, claude, codex and pi that only record
# what they were asked to do. Nothing is downloaded and nothing on this machine
# changes. This proves the script's flow control (prerequisites, consent flags,
# idempotence, refusal, error propagation), not that the upstream installers
# work; run setup.sh for real in a spare HOME for that.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SETUP="$ROOT/setup.sh"
SKILLS_PLUGIN_NAME=mattpocock-skills
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ae-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
FAILED=()

# Real tools setup.sh needs, linked into one directory so PATH can be exact.
REAL_BIN="$WORK/real-bin"
mkdir -p "$REAL_BIN"
for tool in bash sh env git curl jq awk sed grep head tail cat cut mkdir rm chmod mktemp uname sort tr shasum sha256sum sw_vers ls; do
  if path=$(command -v "$tool" 2>/dev/null); then
    ln -s "$path" "$REAL_BIN/$tool"
  fi
done

# --- stubs -------------------------------------------------------------------
# Each stub keeps its state under $AE_TEST_STATE and appends every mutating
# call to $AE_TEST_STATE/calls.log.

make_stubs() { # <dir> <tools...>
  local dir=$1
  shift
  mkdir -p "$dir"
  local tool
  for tool in "$@"; do
    case "$tool" in
      gh)
        cat >"$dir/gh" <<'STUB'
#!/bin/sh
[ "$1 $2" = "auth status" ] && exit 1
exit 0
STUB
        ;;
      node)
        printf '#!/bin/sh\necho v0.0.0-test\n' >"$dir/node"
        ;;
      herdr)
        # shellcheck disable=SC2016
        printf '#!/bin/sh\n[ "$1" = --version ] && echo "herdr 0.0.0-test"\n' >"$dir/herdr"
        ;;
      claude)
        cat >"$dir/claude" <<'STUB'
#!/bin/sh
S=$AE_TEST_STATE
case "$1 $2 $3" in
  "plugin list ") [ -f "$S/claude.plugin" ] && printf '  > %s\n    Version: 1.0.0\n' "$(cat "$S/claude.plugin")"; exit 0 ;;
  "plugin marketplace list") printf '['; [ -f "$S/claude.marketplace" ] && printf '{"name":"%s","source":"github","repo":"%s"}' "$(cut -d' ' -f1 "$S/claude.marketplace")" "$(cut -d' ' -f2 "$S/claude.marketplace")"; printf ']\n'; exit 0 ;;
  "plugin marketplace add") echo "claude marketplace add $4" >>"$S/calls.log"; echo "mattpocock $4" >"$S/claude.marketplace"; exit 0 ;;
  "plugin install "*) echo "claude install $3" >>"$S/calls.log"; echo "$3" >"$S/claude.plugin"; exit 0 ;;
esac
echo "claude stub: unexpected call: $*" >&2; exit 9
STUB
        ;;
      codex)
        cat >"$dir/codex" <<'STUB'
#!/bin/sh
S=$AE_TEST_STATE
case "$1 $2 $3" in
  "plugin list ") printf 'PLUGIN STATUS VERSION SOURCE\n'; [ -f "$S/codex.plugin" ] && printf '%s  installed, enabled  1.0.0  /x\n' "$(cat "$S/codex.plugin")"
    # A real Codex lists every plugin of every marketplace (hundreds of lines) after ours; a probe
    # that stops reading early must still count us as installed.
    i=0; while [ $i -lt 3000 ]; do printf 'other-%s@somewhere  not installed  0.0.1  /y\n' "$i"; i=$((i+1)); done; exit 0 ;;
  "plugin marketplace list") printf 'MARKETPLACE ROOT\n'; [ -f "$S/codex.marketplace" ] && printf '%s /x\n' "$(cut -d' ' -f1 "$S/codex.marketplace")"; exit 0 ;;
  "plugin marketplace add") echo "codex marketplace add $4" >>"$S/calls.log"; echo "mattpocock $4" >"$S/codex.marketplace"; exit 0 ;;
  "plugin add "*) echo "codex add $3" >>"$S/calls.log"; echo "$3" >"$S/codex.plugin"; exit 0 ;;
esac
echo "codex stub: unexpected call: $*" >&2; exit 9
STUB
        ;;
      pi)
        cat >"$dir/pi" <<'STUB'
#!/bin/sh
S=$AE_TEST_STATE
case "$1" in
  list) [ -f "$S/pi.package" ] && printf 'User packages:\n  %s\n' "$(cat "$S/pi.package")"; exit 0 ;;
  install) echo "pi install $2" >>"$S/calls.log"; echo "$2" >"$S/pi.package"; exit 0 ;;
esac
echo "pi stub: unexpected call: $*" >&2; exit 9
STUB
        ;;
    esac
    chmod +x "$dir/$tool"
  done
}

# A fake "official installer" served over file://; it honors HERDR_INSTALL_DIR
# like the real one and drops a stub binary there.
make_fake_herdr_installer() { # <path> [exit-code]
  cat >"$1" <<STUB
#!/bin/sh
set -eu
[ "${2:-0}" = 0 ] || exit ${2:-0}
mkdir -p "\$HERDR_INSTALL_DIR"
printf '#!/bin/sh\n[ "\$1" = --version ] && echo "herdr 0.0.0-fake"\n' >"\$HERDR_INSTALL_DIR/herdr"
chmod +x "\$HERDR_INSTALL_DIR/herdr"
STUB
}

# A local bare repository shaped like Firstmate, for offline cloning.
make_fake_firstmate_repo() { # <bare-path>
  local src="$WORK/fm-src-$RANDOM"
  mkdir -p "$src/bin"
  echo "# fake firstmate" >"$src/AGENTS.md"
  printf '#!/usr/bin/env bash\n' >"$src/bin/fm-bootstrap.sh"
  git -C "$src" init -q -b main
  git -C "$src" -c user.name=t -c user.email=t@example.invalid add -A
  git -C "$src" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  git clone -q --bare "$src" "$1"
}

# Every file under a directory with its checksum, for before/after comparison.
tree_digest() { # <dir>
  (cd "$1" && find . -type f ! -path './.git/*' ! -path '*/.git/*' | sort | while IFS= read -r f; do
    printf '%s %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
  done)
}

# --- harness -----------------------------------------------------------------

CASE=
new_case() { # <name> <stub tools...>
  CASE=$1
  shift
  HOME_DIR="$WORK/$CASE/home"
  STUBS="$WORK/$CASE/stubs"
  export AE_TEST_STATE="$WORK/$CASE/state"
  mkdir -p "$HOME_DIR" "$AE_TEST_STATE"
  make_stubs "$STUBS" "$@"
}

run_setup() { # <args...>; sets RC and OUT
  OUT=$(HOME="$HOME_DIR" PATH="$STUBS:$REAL_BIN" TMPDIR="$WORK/$CASE" \
    AE_HERDR_INSTALLER="${AE_HERDR_INSTALLER:-file://$WORK/no-installer}" \
    AE_FIRSTMATE_REPO="${AE_FIRSTMATE_REPO:-file://$WORK/no-repo}" \
    bash "$SETUP" "$@" 2>&1 </dev/null)
  RC=$?
}

check() { # <description> <condition...>
  local desc=$1
  shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED+=("$CASE: $desc")
    printf 'FAIL %s: %s\n' "$CASE" "$desc" >&2
  fi
}
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { ! contains "$1" "$2"; }
calls() { cat "$AE_TEST_STATE/calls.log" 2>/dev/null || true; }

# --- tests -------------------------------------------------------------------

test_missing_prerequisites_fail_check() {
  new_case missing-prereqs # no gh, no node
  run_setup --check
  check "exit 1" [ "$RC" = 1 ]
  check "names gh" contains "$OUT" "gh: not found"
  check "names node" contains "$OUT" "node: not found"
  check "stops before any step" not_contains "$OUT" "==> Herdr"
}

test_unknown_option() {
  new_case unknown-option gh node
  run_setup --bogus
  check "exit 2" [ "$RC" = 2 ]
  check "says unknown" contains "$OUT" "unknown option --bogus"
}

test_check_mode_changes_nothing() {
  new_case check-mode gh node claude codex pi
  local before after
  before=$(tree_digest "$HOME_DIR")
  run_setup --check
  after=$(tree_digest "$HOME_DIR")
  check "exit 0" [ "$RC" = 0 ]
  check "reports herdr todo" contains "$OUT" "not installed; would run the official installer"
  check "reports firstmate todo" contains "$OUT" "would clone"
  check "reports skills todo" contains "$OUT" "Claude Code: would add marketplace"
  check "home untouched" [ "$before" = "$after" ]
  check "no stub calls" [ -z "$(calls)" ]
}

test_clean_install_then_repeat() {
  new_case clean-install gh node claude codex pi
  make_fake_herdr_installer "$WORK/$CASE/install.sh"
  make_fake_firstmate_repo "$WORK/$CASE/firstmate.git"
  AE_HERDR_INSTALLER="file://$WORK/$CASE/install.sh" AE_FIRSTMATE_REPO="$WORK/$CASE/firstmate.git" run_setup --yes
  check "exit 0" [ "$RC" = 0 ]
  check "herdr installed to ~/.local/bin" [ -x "$HOME_DIR/.local/bin/herdr" ]
  check "firstmate cloned" [ -f "$HOME_DIR/firstmate/AGENTS.md" ]
  check "backend = herdr" [ "$(cat "$HOME_DIR/firstmate/config/backend")" = herdr ]
  check "PATH note when ~/.local/bin is not on PATH" contains "$OUT" "Add Herdr to your PATH"
  check "gh login note" contains "$OUT" "gh auth login"
  local expected
  expected=$(printf '%s\n' "claude marketplace add lobennett/skills" "claude install mattpocock-skills@mattpocock" \
    "codex marketplace add lobennett/skills" "codex add mattpocock-skills@mattpocock" "pi install git:github.com/lobennett/skills")
  check "exactly the documented install commands ran" [ "$(calls)" = "$expected" ]

  local before after
  before=$(tree_digest "$HOME_DIR")
  AE_HERDR_INSTALLER="file://$WORK/$CASE/install.sh" AE_FIRSTMATE_REPO="$WORK/$CASE/firstmate.git" run_setup --yes
  after=$(tree_digest "$HOME_DIR")
  check "repeat exit 0" [ "$RC" = 0 ]
  check "repeat reports herdr installed" contains "$OUT" "installed: herdr 0.0.0-fake"
  check "repeat reports checkout present" contains "$OUT" "checkout present"
  check "repeat reports skills installed" contains "$OUT" "Pi: package git:github.com/lobennett/skills installed"
  check "repeat names the Claude update command" contains "$OUT" "claude plugin update mattpocock-skills@mattpocock"
  check "repeat changes no file" [ "$before" = "$after" ]
  check "repeat issues no install command" [ "$(calls)" = "$expected" ]

  AE_HERDR_INSTALLER="file://$WORK/$CASE/install.sh" AE_FIRSTMATE_REPO="$WORK/$CASE/firstmate.git" run_setup --check
  check "check after install exit 0" [ "$RC" = 0 ]
  check "check sees codex plugin despite a long listing" contains "$OUT" "Codex: $SKILLS_PLUGIN_NAME installed"
}

test_skills_repo_override() {
  new_case skills-override gh node herdr pi
  mkdir -p "$HOME_DIR/firstmate/bin" && echo x >"$HOME_DIR/firstmate/AGENTS.md" && : >"$HOME_DIR/firstmate/bin/fm-bootstrap.sh"
  git -C "$HOME_DIR/firstmate" init -q
  AE_SKILLS_REPO=someone/else run_setup --yes --skip-herdr --skip-firstmate
  check "exit 0" [ "$RC" = 0 ]
  check "pi installs the override" [ "$(calls)" = "pi install git:github.com/someone/else" ]
}

test_refuses_foreign_firstmate_dir() {
  new_case foreign-dir gh node herdr
  mkdir -p "$HOME_DIR/firstmate"
  echo "my notes" >"$HOME_DIR/firstmate/notes.txt"
  local before after
  before=$(tree_digest "$HOME_DIR")
  run_setup --yes --skip-skills
  after=$(tree_digest "$HOME_DIR")
  check "exit 1" [ "$RC" = 1 ]
  check "explains" contains "$OUT" "is not a Firstmate checkout; it was left untouched"
  check "directory untouched" [ "$before" = "$after" ]
  check "no config written" [ ! -e "$HOME_DIR/firstmate/config" ]
}

test_preserves_existing_backend_config() {
  new_case keep-backend gh node herdr
  make_fake_firstmate_repo "$WORK/$CASE/firstmate.git"
  git clone -q "$WORK/$CASE/firstmate.git" "$HOME_DIR/firstmate"
  mkdir -p "$HOME_DIR/firstmate/config" && printf 'tmux\n' >"$HOME_DIR/firstmate/config/backend"
  run_setup --yes --skip-skills
  check "exit 0" [ "$RC" = 0 ]
  check "backend still tmux" [ "$(cat "$HOME_DIR/firstmate/config/backend")" = tmux ]
  check "says left alone" contains "$OUT" "already set to 'tmux' (left alone)"
}

test_herdr_download_failure_propagates() {
  new_case download-fail gh node
  AE_HERDR_INSTALLER="http://127.0.0.1:1/install.sh" run_setup --yes --skip-firstmate --skip-skills
  check "exit 1" [ "$RC" = 1 ]
  check "names the failure" contains "$OUT" "could not download the Herdr installer"
  check "nothing installed" [ ! -e "$HOME_DIR/.local/bin/herdr" ]
}

test_herdr_installer_failure_propagates() {
  new_case installer-fail gh node
  make_fake_herdr_installer "$WORK/$CASE/install.sh" 7
  AE_HERDR_INSTALLER="file://$WORK/$CASE/install.sh" run_setup --yes --skip-firstmate --skip-skills
  check "exit 1" [ "$RC" = 1 ]
  check "names the failure" contains "$OUT" "the Herdr installer failed"
}

test_clone_failure_propagates() {
  new_case clone-fail gh node herdr
  AE_FIRSTMATE_REPO="$WORK/$CASE/missing.git" run_setup --yes --skip-skills
  check "exit 1" [ "$RC" = 1 ]
  check "names the failure" contains "$OUT" "git clone of"
  check "no partial checkout" [ ! -e "$HOME_DIR/firstmate" ]
}

test_no_coding_agent_skips_skills() {
  new_case no-agent gh node herdr
  make_fake_firstmate_repo "$WORK/$CASE/firstmate.git"
  AE_FIRSTMATE_REPO="$WORK/$CASE/firstmate.git" run_setup --yes
  check "exit 0" [ "$RC" = 0 ]
  check "lists install commands" contains "$OUT" "Claude Code: curl -fsSL https://claude.ai/install.sh | bash"
  check "skills step skipped" contains "$OUT" "no coding agent found"
}

test_no_private_material_in_repo() {
  CASE=privacy
  local files hits
  files=$(git -C "$ROOT" ls-files | grep -v '^tests/run.sh$')
  # Patterns are assembled so this file does not match itself.
  hits=$(cd "$ROOT" && printf '%s\n' "$files" | xargs grep -n -E \
    -e '/Users/[a-z]' -e '/home/[a-z]' \
    -e 'gh[op]_[A-Za-z0-9]{20,}' -e 'github_pat_' -e 'sk-[A-Za-z0-9]{20,}' -e 'AKIA[0-9A-Z]{12,}' \
    -e 'BEGIN [A-Z ]*PRIVATE KEY' -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(edu|com|org)' \
    -e 'FMX_PAIRING_TOKEN=' -- 2>/dev/null || true)
  check "no absolute home paths, tokens, keys or addresses in tracked files" [ -z "$hits" ]
  [ -z "$hits" ] || printf '%s\n' "$hits" >&2
  check "no state/data/no-mistakes directories committed" [ -z "$(printf '%s\n' "$files" | grep -E '^(state|data|\.no-mistakes|config)/')" ]
}

test_readme_under_500_words() {
  CASE=readme
  local words
  words=$(wc -w <"$ROOT/README.md" | tr -d ' ')
  check "README has $words words (< 500)" [ "$words" -lt 500 ]
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  "$t"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || { printf '%s\n' "${FAILED[@]}" >&2; exit 1; }
