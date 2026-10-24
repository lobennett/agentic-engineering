#!/usr/bin/env bash
# Offline tests for setup.sh.
#
# Every test runs setup.sh inside a throwaway HOME with a hermetic PATH: real
# git/curl/jq, plus stub gh, node, herdr, claude, codex, pi, brew and wezterm that only record
# what they were asked to do. Nothing is downloaded and nothing on this machine
# changes. This proves the script's flow control (prerequisites, consent prompts,
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
for tool in bash sh env git curl jq awk sed grep head tail cat cut mkdir rm chmod mktemp uname sort tr shasum sha256sum sw_vers ls find dirname; do
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
      brew)
        # Installing a cask leaves what the real cask would: the wezterm CLI on
        # PATH, or the font files in ~/Library/Fonts.
        cat >"$dir/brew" <<'STUB'
#!/bin/sh
S=$AE_TEST_STATE
[ "$1 $2" = "install --cask" ] || { echo "brew stub: unexpected call: $*" >&2; exit 9; }
echo "brew install --cask $3" >>"$S/calls.log"
[ -z "${AE_TEST_BREW_FAIL:-}" ] || exit 1
case "$3" in
  wezterm@nightly) printf '#!/bin/sh\necho "wezterm 20260501-000000-abcdef12"\n' >"$(dirname "$0")/wezterm"; chmod +x "$(dirname "$0")/wezterm" ;;
  font-jetbrains-mono-nerd-font) mkdir -p "$HOME/Library/Fonts"; : >"$HOME/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf" ;;
esac
STUB
        ;;
      wezterm)
        # shellcheck disable=SC2016
        printf '#!/bin/sh\necho "wezterm ${AE_TEST_WEZTERM_VERSION:-20240203-110809-5046fc22}"\n' >"$dir/wezterm"
        ;;
      fish)
        printf '#!/bin/sh\n' >"$dir/fish"
        ;;
      darwin | linux)
        # Pins the platform setup.sh sees, whatever this machine is.
        local os=Linux
        [ "$tool" = linux ] || os=Darwin
        # shellcheck disable=SC2016
        printf '#!/bin/sh\ncase "$1" in -m) echo arm64 ;; *) echo %s ;; esac\n' "$os" >"$dir/uname"
        chmod +x "$dir/uname"
        continue
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
# like the real one and drops a stub binary there. It also drains stdin, as any
# child that reads stdin would under curl | bash.
make_fake_herdr_installer() { # <path> [exit-code]
  cat >"$1" <<STUB
#!/bin/sh
set -eu
[ "${2:-0}" = 0 ] || exit ${2:-0}
cat >/dev/null
echo "herdr installer" >>"\$AE_TEST_STATE/calls.log"
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

# A local bare repository shaped like KevinSilvester/wezterm-config, with its
# launch.lua default_prog lines verbatim.
make_fake_wezterm_config_repo() { # <bare-path>
  local src="$WORK/wez-src-$RANDOM"
  mkdir -p "$src/config"
  echo "return require('config')" >"$src/wezterm.lua"
  cat >"$src/config/launch.lua" <<'LUA'
if platform.is_mac then
   options.default_prog = { '/opt/homebrew/bin/fish', '-l' }
   options.launch_menu = {
      { label = 'Fish', args = { '/opt/homebrew/bin/fish', '-l' } },
   }
elseif platform.is_linux then
   options.default_prog = { 'fish', '-l' }
end
LUA
  git -C "$src" init -q -b master
  git -C "$src" -c user.name=t -c user.email=t@example.invalid add -A
  git -C "$src" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  git clone -q --bare "$src" "$1"
}
WEZ_REPO="$WORK/wezterm-config.git"
make_fake_wezterm_config_repo "$WEZ_REPO"

# A Firstmate-shaped directory, so a test can skip the clone.
fake_firstmate_checkout() {
  mkdir -p "$HOME_DIR/firstmate/bin" && echo x >"$HOME_DIR/firstmate/AGENTS.md" && : >"$HOME_DIR/firstmate/bin/fm-bootstrap.sh"
  git -C "$HOME_DIR/firstmate" init -q
  mkdir -p "$HOME_DIR/firstmate/config" && echo herdr >"$HOME_DIR/firstmate/config/backend"
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
    AE_WEZTERM_CONFIG_REPO="${AE_WEZTERM_CONFIG_REPO:-$WEZ_REPO}" SHELL=/bin/test-shell \
    XDG_CONFIG_HOME="${TEST_XDG_CONFIG_HOME:-}" XDG_DATA_HOME='' WEZTERM_CONFIG_FILE="${TEST_WEZTERM_CONFIG_FILE:-}" \
    bash "$SETUP" "$@" 2>&1 </dev/null)
  RC=$?
}

piped_setup() { # <args...>; like run_setup, but feeds the script to bash on stdin
  OUT=$(HOME="$HOME_DIR" PATH="$STUBS:$REAL_BIN" TMPDIR="$WORK/$CASE" \
    AE_HERDR_INSTALLER="${AE_HERDR_INSTALLER:-file://$WORK/no-installer}" \
    AE_FIRSTMATE_REPO="${AE_FIRSTMATE_REPO:-file://$WORK/no-repo}" \
    AE_WEZTERM_CONFIG_REPO="${AE_WEZTERM_CONFIG_REPO:-$WEZ_REPO}" SHELL=/bin/test-shell \
    XDG_CONFIG_HOME='' XDG_DATA_HOME='' WEZTERM_CONFIG_FILE='' \
    bash -s -- "$@" <"$SETUP" 2>&1)
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
  run_setup --yes
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

test_clean_install_then_repeat() {
  new_case clean-install gh node claude codex pi
  make_fake_herdr_installer "$WORK/$CASE/install.sh"
  make_fake_firstmate_repo "$WORK/$CASE/firstmate.git"
  AE_HERDR_INSTALLER="file://$WORK/$CASE/install.sh" AE_FIRSTMATE_REPO="$WORK/$CASE/firstmate.git" run_setup --yes
  check "exit 0" [ "$RC" = 0 ]
  check "herdr installed to ~/.local/bin" [ -x "$HOME_DIR/.local/bin/herdr" ]
  check "firstmate cloned" [ -f "$HOME_DIR/firstmate/AGENTS.md" ]
  check "wezterm config cloned" [ -f "$HOME_DIR/.config/wezterm/wezterm.lua" ]
  check "backend = herdr" [ "$(cat "$HOME_DIR/firstmate/config/backend")" = herdr ]
  check "PATH note when ~/.local/bin is not on PATH" contains "$OUT" "Add Herdr to your PATH"
  check "gh login note" contains "$OUT" "gh auth login"
  local expected
  expected=$(printf '%s\n' "herdr installer" "claude marketplace add lobennett/skills" "claude install mattpocock-skills@mattpocock" \
    "codex marketplace add lobennett/skills" "codex add mattpocock-skills@mattpocock" "pi install git:github.com/lobennett/skills")
  check "exactly the documented install commands ran" [ "$(calls)" = "$expected" ]

  local before after
  before=$(tree_digest "$HOME_DIR")
  AE_HERDR_INSTALLER="file://$WORK/$CASE/install.sh" AE_FIRSTMATE_REPO="$WORK/$CASE/firstmate.git" run_setup --yes
  after=$(tree_digest "$HOME_DIR")
  check "repeat exit 0" [ "$RC" = 0 ]
  check "repeat finds herdr off PATH" contains "$OUT" "installed: herdr 0.0.0-fake at $HOME_DIR/.local/bin/herdr"
  check "repeat names the herdr update command" contains "$OUT" "update any time with: herdr update"
  check "repeat still notes the PATH change" contains "$OUT" "Add Herdr to your PATH"
  check "repeat reports checkout present" contains "$OUT" "checkout present"
  check "repeat reports skills installed" contains "$OUT" "Pi: package git:github.com/lobennett/skills installed"
  check "repeat sees codex plugin despite a long listing" contains "$OUT" "Codex: $SKILLS_PLUGIN_NAME installed"
  check "repeat names the Claude update command" contains "$OUT" "claude plugin update mattpocock-skills@mattpocock"
  check "repeat names the WezTerm config update command" contains "$OUT" "git -C $HOME_DIR/.config/wezterm pull --ff-only --no-rebase"
  check "repeat changes no file" [ "$before" = "$after" ]
  check "repeat issues no install command" [ "$(calls)" = "$expected" ]
}

test_piped_install_runs_to_the_end() {
  new_case piped gh node pi
  make_fake_herdr_installer "$WORK/$CASE/install.sh"
  make_fake_firstmate_repo "$WORK/$CASE/firstmate.git"
  AE_HERDR_INSTALLER="file://$WORK/$CASE/install.sh" AE_FIRSTMATE_REPO="$WORK/$CASE/firstmate.git" piped_setup --yes
  check "exit 0" [ "$RC" = 0 ]
  check "firstmate cloned after the installer drained stdin" [ -f "$HOME_DIR/firstmate/AGENTS.md" ]
  check "skills installed" [ "$(calls)" = "$(printf '%s\n' "herdr installer" "pi install git:github.com/lobennett/skills")" ]
  check "final instructions printed" contains "$OUT" "Its first session checks its own toolchain"
}

test_skills_repo_override() {
  new_case skills-override gh node herdr pi
  fake_firstmate_checkout
  AE_SKILLS_REPO=someone/else run_setup --yes
  check "exit 0" [ "$RC" = 0 ]
  check "pi installs the override" [ "$(calls)" = "pi install git:github.com/someone/else" ]
}

test_refuses_foreign_firstmate_dir() {
  new_case foreign-dir gh node herdr
  mkdir -p "$HOME_DIR/firstmate"
  echo "my notes" >"$HOME_DIR/firstmate/notes.txt"
  local before after
  before=$(tree_digest "$HOME_DIR")
  run_setup --yes
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
  run_setup --yes
  check "exit 0" [ "$RC" = 0 ]
  check "backend still tmux" [ "$(cat "$HOME_DIR/firstmate/config/backend")" = tmux ]
  check "says left alone" contains "$OUT" "already set to 'tmux' (left alone)"
}

test_herdr_download_failure_propagates() {
  new_case download-fail gh node
  AE_HERDR_INSTALLER="http://127.0.0.1:1/install.sh" run_setup --yes
  check "exit 1" [ "$RC" = 1 ]
  check "names the failure" contains "$OUT" "could not download the Herdr installer"
  check "nothing installed" [ ! -e "$HOME_DIR/.local/bin/herdr" ]
}

test_herdr_installer_failure_propagates() {
  new_case installer-fail gh node
  make_fake_herdr_installer "$WORK/$CASE/install.sh" 7
  AE_HERDR_INSTALLER="file://$WORK/$CASE/install.sh" run_setup --yes
  check "exit 1" [ "$RC" = 1 ]
  check "names the failure" contains "$OUT" "the Herdr installer failed"
}

test_clone_failure_propagates() {
  new_case clone-fail gh node herdr
  AE_FIRSTMATE_REPO="$WORK/$CASE/missing.git" run_setup --yes
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

# /Applications or /Library/Fonts on this machine can already hold what a
# macOS test expects to install; those checks then cannot run here.
mac_app_or_font_preinstalled() {
  [ -e /Applications/WezTerm.app ] || [ -n "$(find /Library/Fonts -maxdepth 3 -name 'JetBrainsMonoNerdFont-*' 2>/dev/null | head -n 1)" ]
}

test_wezterm_macos_install_then_repeat() {
  new_case wezterm-macos gh node herdr brew darwin
  if mac_app_or_font_preinstalled; then
    printf 'skip %s: WezTerm or the font is installed system-wide here\n' "$CASE" >&2
    return 0
  fi
  fake_firstmate_checkout
  run_setup --yes
  check "exit 0" [ "$RC" = 0 ]
  check "app and font installed with brew" [ "$(calls)" = "$(printf '%s\n' "brew install --cask wezterm@nightly" "brew install --cask font-jetbrains-mono-nerd-font")" ]
  check "config cloned to ~/.config/wezterm" [ "$(git -C "$HOME_DIR/.config/wezterm" remote get-url origin)" = "$WEZ_REPO" ]
  local launch="$HOME_DIR/.config/wezterm/config/launch.lua"
  check "macOS default shell is the login shell" grep -qF "options.default_prog = { '/bin/test-shell', '-l' }" "$launch"
  check "only the default_prog line changed" [ "$(git -C "$HOME_DIR/.config/wezterm" diff --numstat)" = "$(printf '1\t1\tconfig/launch.lua')" ]

  local before after
  before=$(tree_digest "$HOME_DIR")
  run_setup --yes
  after=$(tree_digest "$HOME_DIR")
  check "repeat exit 0" [ "$RC" = 0 ]
  check "repeat reports the installed app" contains "$OUT" "installed: wezterm 20260501-000000-abcdef12"
  check "repeat finds the font" contains "$OUT" "JetBrainsMono Nerd Font: found in $HOME_DIR/Library/Fonts"
  check "repeat reports the config" contains "$OUT" "config present at $HOME_DIR/.config/wezterm"
  check "repeat changes no file" [ "$before" = "$after" ]
  check "repeat issues no install command" [ "$(calls | wc -l | tr -d ' ')" = 2 ]
}

test_wezterm_linux_points_to_official_installs() {
  new_case wezterm-linux gh node herdr linux
  fake_firstmate_checkout
  run_setup --yes
  check "exit 0" [ "$RC" = 0 ]
  check "app install page" contains "$OUT" "https://wezterm.org/install/linux.html"
  check "font page" contains "$OUT" "https://www.nerdfonts.com/font-downloads"
  check "nothing installed" [ -z "$(calls)" ]
  check "linux default shell is the login shell" grep -qF "options.default_prog = { '/bin/test-shell', '-l' }" "$HOME_DIR/.config/wezterm/config/launch.lua"
  check "macOS line untouched" grep -qF "options.default_prog = { '/opt/homebrew/bin/fish', '-l' }" "$HOME_DIR/.config/wezterm/config/launch.lua"
}

test_wezterm_keeps_fish_and_warns_old_version() {
  new_case wezterm-fish gh node herdr wezterm fish linux
  fake_firstmate_checkout
  AE_TEST_WEZTERM_VERSION=20230712-072601-f4abf8fd run_setup --yes
  check "exit 0" [ "$RC" = 0 ]
  check "fish kept" contains "$OUT" "default shell: fish"
  check "config unmodified" [ -z "$(git -C "$HOME_DIR/.config/wezterm" status --porcelain)" ]
  check "old version flagged" contains "$OUT" "needs 20240127 or newer"
}

test_wezterm_leaves_existing_configs_alone() {
  local kind
  for kind in dotfile dir env xdg-shadow; do
    new_case "wezterm-existing-$kind" gh node herdr wezterm linux
    fake_firstmate_checkout
    local env_file='' xdg=''
    case "$kind" in
      dotfile) echo "-- mine" >"$HOME_DIR/.wezterm.lua" ;;
      dir) mkdir -p "$HOME_DIR/.config/wezterm" && echo "-- mine" >"$HOME_DIR/.config/wezterm/wezterm.lua" ;;
      env) mkdir -p "$HOME_DIR/cfg" && echo "-- mine" >"$HOME_DIR/cfg/wez.lua" && env_file="$HOME_DIR/cfg/wez.lua" ;;
      xdg-shadow) mkdir -p "$HOME_DIR/.config/wezterm" && echo "-- mine" >"$HOME_DIR/.config/wezterm/wezterm.lua" && xdg="$HOME_DIR/xdg" ;;
    esac
    local before after
    before=$(tree_digest "$HOME_DIR")
    TEST_WEZTERM_CONFIG_FILE=$env_file TEST_XDG_CONFIG_HOME=$xdg run_setup --yes
    after=$(tree_digest "$HOME_DIR")
    check "exit 0" [ "$RC" = 0 ]
    check "names the existing config" contains "$OUT" "(left untouched)"
    check "says how to switch" contains "$OUT" "move your WezTerm config aside"
    check "no file changed" [ "$before" = "$after" ]
    check "no XDG config created" [ ! -e "$HOME_DIR/xdg" ]
    check "nothing cloned" [ ! -e "$HOME_DIR/.config/wezterm/.git" ]
  done
}

test_wezterm_honors_xdg_config_home() {
  new_case wezterm-xdg gh node herdr wezterm linux
  fake_firstmate_checkout
  TEST_XDG_CONFIG_HOME="$HOME_DIR/xdg" run_setup --yes
  check "exit 0" [ "$RC" = 0 ]
  check "cloned under XDG_CONFIG_HOME" [ -f "$HOME_DIR/xdg/wezterm/wezterm.lua" ]
  check "nothing under ~/.config" [ ! -e "$HOME_DIR/.config" ]
}

test_wezterm_failures_propagate() {
  new_case wezterm-clone-fail gh node herdr wezterm linux
  fake_firstmate_checkout
  AE_WEZTERM_CONFIG_REPO="$WORK/$CASE/missing.git" run_setup --yes
  check "exit 1" [ "$RC" = 1 ]
  check "names the failure" contains "$OUT" "git clone of $WORK/$CASE/missing.git failed"
  check "no partial checkout" [ ! -e "$HOME_DIR/.config/wezterm" ]

  new_case wezterm-brew-fail gh node herdr brew darwin
  if mac_app_or_font_preinstalled; then
    return 0
  fi
  fake_firstmate_checkout
  AE_TEST_BREW_FAIL=1 run_setup --yes
  check "exit 1" [ "$RC" = 1 ]
  check "names the failure" contains "$OUT" "brew install --cask wezterm@nightly failed"
}

test_no_private_material_in_repo() {
  CASE=privacy
  local files hits
  files=$(git -C "$ROOT" ls-files | grep -v '^tests/run.sh$')
  # Patterns are assembled so this file does not match itself.
  hits=$(cd "$ROOT" || exit; printf '%s\n' "$files" | xargs grep -n -E \
    -e '/Users/[a-z]' -e '/home/[a-z]' \
    -e 'gh[op]_[A-Za-z0-9]{20,}' -e 'github_pat_' -e 'sk-[A-Za-z0-9]{20,}' -e 'AKIA[0-9A-Z]{12,}' \
    -e 'BEGIN [A-Z ]*PRIVATE KEY' -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(edu|com|org)' \
    -e 'FMX_PAIRING_TOKEN=' -- 2>/dev/null) || true
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
