#!/usr/bin/env bash
# setup.sh - one-command setup for the agentic-engineering workflow.
#
# Installs, with your consent at each step:
#   1. Herdr      the terminal runtime coding agents live on   (official installer)
#   2. Firstmate  the agent crew you talk to                   (git clone)
#   3. Skills     Matt Pocock's engineering skills, from the lab's fork, into
#                 whichever of Claude Code, Codex and Pi you already have.
#   4. WezTerm    the terminal app (Homebrew on macOS), its JetBrainsMono Nerd
#                 Font, and KevinSilvester/wezterm-config        (git clone)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/lobennett/agentic-engineering/main/setup.sh | bash
#   ./setup.sh [--yes]
#
#   --yes     answer yes to every install question (for scripted use)
#
# Re-running is safe: anything already installed is left alone, an existing
# Firstmate checkout is never pulled or reset, and a non-Firstmate directory at
# the Firstmate path makes the script stop instead of touching it. Any WezTerm
# config you already have is left alone and the upstream config is not cloned.
#
# Environment overrides:
#   AE_FIRSTMATE_DIR    Firstmate checkout path        (default: $HOME/firstmate)
#   AE_FIRSTMATE_REPO   Firstmate git URL              (default: https://github.com/lobennett/firstmate)
#   AE_SKILLS_REPO      skills repository, owner/name  (default: lobennett/skills)
#   AE_HERDR_INSTALLER  Herdr installer URL            (default: https://herdr.dev/install.sh)
#   AE_BIN_DIR          where Herdr is installed       (default: $HOME/.local/bin)
#   AE_WEZTERM_CONFIG_REPO  WezTerm config git URL     (default: https://github.com/KevinSilvester/wezterm-config)
set -euo pipefail

AE_FIRSTMATE_DIR=${AE_FIRSTMATE_DIR:-$HOME/firstmate}
AE_FIRSTMATE_REPO=${AE_FIRSTMATE_REPO:-https://github.com/lobennett/firstmate}
AE_SKILLS_REPO=${AE_SKILLS_REPO:-lobennett/skills}
AE_HERDR_INSTALLER=${AE_HERDR_INSTALLER:-https://herdr.dev/install.sh}
AE_BIN_DIR=${AE_BIN_DIR:-$HOME/.local/bin}
AE_WEZTERM_CONFIG_REPO=${AE_WEZTERM_CONFIG_REPO:-https://github.com/KevinSilvester/wezterm-config}

# Names declared by the skills repository's own .claude-plugin manifests.
SKILLS_PLUGIN=mattpocock-skills
SKILLS_MARKETPLACE=mattpocock

ASSUME_YES=0
NOTES=()

usage() {
  printf 'Usage: setup.sh [--yes]\n  --yes  answer yes to every install question (for scripted use)\n'
}

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok() { printf '  \033[32m+\033[0m %s\n' "$*"; }
todo() { printf '  \033[33m-\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m!\033[0m %s\n' "$*" >&2; }
die() { printf '  \033[31m!\033[0m %s\n' "$*" >&2; exit 1; }
note() { NOTES+=("$*"); }

has_tty() { ( : </dev/tty ) 2>/dev/null; }

# confirm <question>: yes -> 0, no -> 1. With --yes every question is a yes.
# Without a terminal (curl | bash in CI, say) there is nobody to ask, so stop.
confirm() {
  if [ "$ASSUME_YES" = 1 ]; then
    return 0
  fi
  has_tty || die "cannot ask '$1': no terminal. Re-run with --yes to accept every step."
  local answer
  printf '  %s [y/N] ' "$1" >/dev/tty
  read -r answer </dev/tty || answer=
  case "$answer" in
    y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
  esac
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# --- 0. platform and prerequisites -------------------------------------------

check_platform() {
  say "Platform"
  case "$(uname -s)" in
    Darwin) ok "macOS $(sw_vers -productVersion 2>/dev/null || true) ($(uname -m))" ;;
    Linux) ok "Linux ($(uname -m))" ;;
    *) die "unsupported OS $(uname -s): Herdr and Firstmate support macOS and Linux" ;;
  esac
}

check_prerequisites() {
  say "Prerequisites"
  local tool missing=()
  for tool in git curl gh node jq; do
    if command -v "$tool" >/dev/null 2>&1; then
      ok "$tool: $(command -v "$tool")"
    else
      fail "$tool: not found"
      missing+=("$tool")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    case "$(uname -s)" in
      Darwin) todo "install with Homebrew (https://brew.sh): brew install ${missing[*]}" ;;
      Linux) todo "install ${missing[*]} with your package manager; gh: https://github.com/cli/cli#installation, node: https://nodejs.org" ;;
    esac
    die "install the missing tools above, then re-run"
  fi

  if gh auth status >/dev/null 2>&1; then
    ok "gh: logged in to GitHub"
  else
    todo "gh: not logged in"
    note "Log in to GitHub (Firstmate needs it): gh auth login"
  fi
}

HARNESSES=()
check_harnesses() {
  say "Coding agents"
  local h
  for h in claude codex pi; do
    if command -v "$h" >/dev/null 2>&1; then
      ok "$h: $(command -v "$h")"
      HARNESSES+=("$h")
    else
      todo "$h: not found"
    fi
  done
  if [ ${#HARNESSES[@]} -eq 0 ]; then
    todo "install at least one, then re-run to get the skills:"
    todo "  Claude Code: curl -fsSL https://claude.ai/install.sh | bash"
    todo "  Codex:       npm install -g @openai/codex"
    todo "  Pi:          curl -fsSL https://pi.dev/install.sh | sh"
    note "Install a coding agent (Claude Code, Codex or Pi) and re-run this script for the skills."
  fi
}

# --- 1. Herdr ----------------------------------------------------------------

step_herdr() {
  say "Herdr"
  local herdr_bin
  herdr_bin=$(command -v herdr 2>/dev/null || true)
  if [ -z "$herdr_bin" ] && [ -x "$AE_BIN_DIR/herdr" ]; then
    herdr_bin=$AE_BIN_DIR/herdr
  fi
  if [ -n "$herdr_bin" ]; then
    ok "installed: $("$herdr_bin" --version 2>/dev/null | head -n 1) at $herdr_bin"
    ok "update any time with: herdr update"
    note_path_if_missing
    return 0
  fi
  if ! confirm "Install Herdr with the official installer ($AE_HERDR_INSTALLER) into $AE_BIN_DIR?"; then
    todo "skipped Herdr"
    note "Install Herdr later: curl -fsSL https://herdr.dev/install.sh | sh"
    return 0
  fi
  local installer
  installer=$(mktemp "${TMPDIR:-/tmp}/herdr-install.XXXXXX")
  if ! curl -fsSL --connect-timeout 10 --max-time 60 "$AE_HERDR_INSTALLER" -o "$installer"; then
    rm -f "$installer"
    die "could not download the Herdr installer from $AE_HERDR_INSTALLER"
  fi
  ok "downloaded installer (sha256 $(sha256_of "$installer"))"
  if ! HERDR_INSTALL_DIR="$AE_BIN_DIR" sh "$installer"; then
    rm -f "$installer"
    die "the Herdr installer failed"
  fi
  rm -f "$installer"
  [ -x "$AE_BIN_DIR/herdr" ] || die "expected $AE_BIN_DIR/herdr after install, found nothing"
  ok "installed: $("$AE_BIN_DIR/herdr" --version | head -n 1)"
  note_path_if_missing
}

note_path_if_missing() {
  command -v herdr >/dev/null 2>&1 ||
    note "Add Herdr to your PATH (shell rc file): export PATH=\"$AE_BIN_DIR:\$PATH\""
}

# --- 2. Firstmate ------------------------------------------------------------

is_firstmate_checkout() {
  [ -f "$1/AGENTS.md" ] && [ -f "$1/bin/fm-bootstrap.sh" ] &&
    git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

write_firstmate_config() {
  # Firstmate keeps config/ out of git, so these files are yours. Only the
  # runtime backend choice is written, and only when it is not already set.
  local cfg="$AE_FIRSTMATE_DIR/config"
  if [ -e "$cfg/backend" ]; then
    ok "config/backend already set to '$(head -n 1 "$cfg/backend")' (left alone)"
    return 0
  fi
  mkdir -p "$cfg"
  printf 'herdr\n' >"$cfg/backend"
  ok "config/backend = herdr"
}

step_firstmate() {
  say "Firstmate"
  if [ -e "$AE_FIRSTMATE_DIR" ]; then
    if is_firstmate_checkout "$AE_FIRSTMATE_DIR"; then
      ok "checkout present at $AE_FIRSTMATE_DIR ($(git -C "$AE_FIRSTMATE_DIR" log -1 --format='%h, %cs' 2>/dev/null || echo 'unknown revision'))"
      ok "update from inside a Firstmate session with /updatefirstmate (fast-forward only)"
      write_firstmate_config
      return 0
    fi
    fail "$AE_FIRSTMATE_DIR exists and is not a Firstmate checkout; it was left untouched"
    die "move that directory, or set AE_FIRSTMATE_DIR to another path, then re-run"
  fi
  if ! confirm "Clone Firstmate ($AE_FIRSTMATE_REPO) into $AE_FIRSTMATE_DIR?"; then
    todo "skipped Firstmate"
    return 0
  fi
  git clone "$AE_FIRSTMATE_REPO" "$AE_FIRSTMATE_DIR" || die "git clone of $AE_FIRSTMATE_REPO failed"
  ok "cloned to $AE_FIRSTMATE_DIR ($(git -C "$AE_FIRSTMATE_DIR" log -1 --format='%h, %cs'))"
  write_firstmate_config
}

# --- 3. Skills ---------------------------------------------------------------

# Each "is it installed?" probe captures the tool's full output, then greps it
# without -q. A grep that stops reading early makes the writer take SIGPIPE, and
# under pipefail a long listing would then read as "not installed".
skills_claude() {
  local installed marketplaces
  installed=$(claude plugin list 2>/dev/null || true)
  if printf '%s\n' "$installed" | grep -F "$SKILLS_PLUGIN@" >/dev/null; then
    ok "Claude Code: $SKILLS_PLUGIN installed (update with: claude plugin update $SKILLS_PLUGIN@$SKILLS_MARKETPLACE)"
    return 0
  fi
  if ! confirm "Claude Code: add marketplace github.com/$AE_SKILLS_REPO and install $SKILLS_PLUGIN?"; then
    todo "skipped Claude Code skills"
    return 0
  fi
  marketplaces=$(claude plugin marketplace list --json 2>/dev/null || echo '[]')
  if ! printf '%s\n' "$marketplaces" |
    jq -e --arg name "$SKILLS_MARKETPLACE" 'map(select(.name == $name)) | length > 0' >/dev/null; then
    claude plugin marketplace add "$AE_SKILLS_REPO" || die "claude plugin marketplace add $AE_SKILLS_REPO failed"
  fi
  claude plugin install "$SKILLS_PLUGIN@$SKILLS_MARKETPLACE" || die "claude plugin install $SKILLS_PLUGIN failed"
  ok "Claude Code: $SKILLS_PLUGIN installed (restart open sessions to load it)"
}

skills_codex() {
  local installed marketplaces
  installed=$(codex plugin list 2>/dev/null || true)
  if printf '%s\n' "$installed" | grep -E "^$SKILLS_PLUGIN@[^ ]+ +installed" >/dev/null; then
    ok "Codex: $SKILLS_PLUGIN installed (refreshed at startup)"
    return 0
  fi
  if ! confirm "Codex: add marketplace $AE_SKILLS_REPO and install $SKILLS_PLUGIN?"; then
    todo "skipped Codex skills"
    return 0
  fi
  marketplaces=$(codex plugin marketplace list 2>/dev/null || true)
  if ! printf '%s\n' "$marketplaces" | awk 'NR > 1 {print $1}' | grep -x "$SKILLS_MARKETPLACE" >/dev/null; then
    codex plugin marketplace add "$AE_SKILLS_REPO" || die "codex plugin marketplace add $AE_SKILLS_REPO failed"
  fi
  codex plugin add "$SKILLS_PLUGIN@$SKILLS_MARKETPLACE" || die "codex plugin add $SKILLS_PLUGIN failed"
  ok "Codex: $SKILLS_PLUGIN installed (restart open sessions to load it)"
}

skills_pi() {
  local source="git:github.com/$AE_SKILLS_REPO" installed
  installed=$(pi list 2>/dev/null || true)
  if printf '%s\n' "$installed" | grep -F "$source" >/dev/null; then
    ok "Pi: package $source installed (update with: pi update $source)"
    return 0
  fi
  if ! confirm "Pi: install package $source?"; then
    todo "skipped Pi skills"
    return 0
  fi
  pi install "$source" || die "pi install $source failed"
  ok "Pi: package $source installed (run /reload in open sessions)"
}

step_skills() {
  say "Skills (github.com/$AE_SKILLS_REPO)"
  if [ ${#HARNESSES[@]} -eq 0 ]; then
    todo "no coding agent found; nothing to install the skills into"
    return 0
  fi
  local h
  for h in "${HARNESSES[@]}"; do
    "skills_$h"
  done
  note "In each project, run /setup-matt-pocock-skills once; then try /grill-with-docs or /ask-matt."
}

# --- 4. WezTerm --------------------------------------------------------------

# Requirements stated in the wezterm-config README: WezTerm 20240127-113634-bbcac864
# or newer (nightly recommended) and the JetBrainsMono Nerd Font.
WEZTERM_MIN_VERSION=20240127
WEZTERM_CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/wezterm

wezterm_app() {
  local bin app version
  bin=$(command -v wezterm 2>/dev/null || true)
  for app in /Applications/WezTerm.app "$HOME/Applications/WezTerm.app"; do
    [ -n "$bin" ] || [ ! -x "$app/Contents/MacOS/wezterm" ] || bin=$app/Contents/MacOS/wezterm
  done
  if [ -n "$bin" ]; then
    version=$("$bin" --version 2>/dev/null | head -n 1 || true)
    ok "installed: $version at $bin"
    case "${version#wezterm }" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*)
        version=${version#wezterm }
        [ "${version%%-*}" -ge "$WEZTERM_MIN_VERSION" ] ||
          note "Update WezTerm: the config needs $WEZTERM_MIN_VERSION or newer (nightly recommended)."
        ;;
    esac
    return 0
  fi
  if [ "$(uname -s)" != Darwin ]; then
    todo "WezTerm: not found"
    note "Install WezTerm (the config recommends nightly): https://wezterm.org/install/linux.html"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    todo "WezTerm: not found, and Homebrew is not available to install it"
    note "Install WezTerm (the config recommends nightly): https://wezterm.org/install/macos.html"
    return 0
  fi
  if ! confirm "Install WezTerm nightly, as the config recommends (brew install --cask wezterm@nightly)?"; then
    todo "skipped the WezTerm app"
    return 0
  fi
  brew install --cask wezterm@nightly || die "brew install --cask wezterm@nightly failed"
  ok "installed WezTerm nightly (update with: brew upgrade --cask wezterm@nightly --greedy-latest)"
}

wezterm_font() {
  local dir
  for dir in "$HOME/Library/Fonts" /Library/Fonts "${XDG_DATA_HOME:-$HOME/.local/share}/fonts" "$HOME/.fonts"; do
    if [ -d "$dir" ] && [ -n "$(find "$dir" -maxdepth 3 -name 'JetBrainsMonoNerdFont-*' -print 2>/dev/null | head -n 1)" ]; then
      ok "JetBrainsMono Nerd Font: found in $dir"
      return 0
    fi
  done
  if [ "$(uname -s)" != Darwin ] || ! command -v brew >/dev/null 2>&1; then
    todo "JetBrainsMono Nerd Font: not found"
    note "Install the JetBrainsMono Nerd Font the config uses: https://www.nerdfonts.com/font-downloads"
    return 0
  fi
  if ! confirm "Install the JetBrainsMono Nerd Font the config uses (brew install --cask font-jetbrains-mono-nerd-font)?"; then
    todo "skipped the JetBrainsMono Nerd Font"
    return 0
  fi
  brew install --cask font-jetbrains-mono-nerd-font || die "brew install --cask font-jetbrains-mono-nerd-font failed"
  ok "installed JetBrainsMono Nerd Font"
}

is_wezterm_config_checkout() {
  local origin
  [ -f "$1/wezterm.lua" ] || return 1
  origin=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  [ "${origin%.git}" = "${AE_WEZTERM_CONFIG_REPO%.git}" ]
}

# The config's README has you point config/launch.lua at your own shell (setup
# step 2): it starts fish, from /opt/homebrew/bin on macOS. When fish is not
# there, offer to make that one-line change for the login shell.
wezterm_shell() {
  local launch="$WEZTERM_CONFIG_DIR/config/launch.lua" fish line shell
  case "$(uname -s)" in
    Darwin) fish=/opt/homebrew/bin/fish ;;
    *) fish=fish ;;
  esac
  line="options.default_prog = { '$fish', '-l' }"
  grep -F "$line" "$launch" >/dev/null 2>&1 || return 0
  if command -v "$fish" >/dev/null 2>&1; then
    ok "default shell: fish ($fish)"
    return 0
  fi
  shell=${SHELL:-/bin/bash}
  if ! confirm "The config starts fish, which is not installed. Start your login shell ($shell) instead, in config/launch.lua?"; then
    todo "left config/launch.lua starting fish"
    note "WezTerm cannot open a shell until you install fish or change default_prog in $launch"
    return 0
  fi
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/launch.lua.XXXXXX")
  if ! awk -v old="$line" -v new="options.default_prog = { '$shell', '-l' }" '
    { i = index($0, old); if (i) $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); print }
  ' "$launch" >"$tmp" || ! cat "$tmp" >"$launch"; then
    rm -f "$tmp"
    die "could not update $launch"
  fi
  rm -f "$tmp"
  ok "default shell: $shell (a local change in config/launch.lua; see git -C $WEZTERM_CONFIG_DIR diff)"
}

wezterm_config() {
  if is_wezterm_config_checkout "$WEZTERM_CONFIG_DIR"; then
    ok "config present at $WEZTERM_CONFIG_DIR ($(git -C "$WEZTERM_CONFIG_DIR" log -1 --format='%h, %cs' 2>/dev/null || echo 'unknown revision'))"
    ok "update with: git -C $WEZTERM_CONFIG_DIR pull --ff-only --no-rebase"
    wezterm_shell
    return 0
  fi
  # WezTerm reads the first of these that exists, so any one outside the
  # checkout would either hide the new config or be hidden by it.
  local found=() f
  [ ! -e "$WEZTERM_CONFIG_DIR" ] || found+=("$WEZTERM_CONFIG_DIR")
  for f in "${WEZTERM_CONFIG_FILE:-}" "$HOME/.config/wezterm/wezterm.lua" "$HOME/.wezterm.lua"; do
    case "$f" in "" | "$WEZTERM_CONFIG_DIR"/*) continue ;; esac
    [ ! -e "$f" ] || found+=("$f")
  done
  if [ ${#found[@]} -gt 0 ]; then
    for f in "${found[@]}"; do
      todo "existing WezTerm config: $f (left untouched)"
    done
    note "To use $AE_WEZTERM_CONFIG_REPO, move your WezTerm config aside (or unset WEZTERM_CONFIG_FILE), then re-run."
    return 0
  fi
  if ! confirm "Clone the WezTerm config ($AE_WEZTERM_CONFIG_REPO) into $WEZTERM_CONFIG_DIR?"; then
    todo "skipped the WezTerm config"
    return 0
  fi
  mkdir -p "$(dirname "$WEZTERM_CONFIG_DIR")"
  git clone "$AE_WEZTERM_CONFIG_REPO" "$WEZTERM_CONFIG_DIR" || die "git clone of $AE_WEZTERM_CONFIG_REPO failed"
  ok "cloned to $WEZTERM_CONFIG_DIR ($(git -C "$WEZTERM_CONFIG_DIR" log -1 --format='%h, %cs'))"
  wezterm_shell
}

step_wezterm() {
  say "WezTerm"
  wezterm_app
  wezterm_font
  wezterm_config
}

# --- run ---------------------------------------------------------------------

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --yes | -y) ASSUME_YES=1 ;;
      -h | --help) usage; exit 0 ;;
      *) printf 'setup.sh: unknown option %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
  done

  check_platform
  check_prerequisites
  check_harnesses
  step_herdr
  step_firstmate
  step_skills
  step_wezterm

  say "Next"
  local line
  for line in "${NOTES[@]+"${NOTES[@]}"}"; do
    todo "$line"
  done
  ok "Open WezTerm and start Herdr in it with: herdr   (Sherlock: run ssh sherlock in a WezTerm tab)"
  local tilde="~" fm_display
  fm_display=${AE_FIRSTMATE_DIR/#"$HOME"/$tilde}
  ok "In a Herdr pane, start your first mate: cd $fm_display && claude   (or codex, or pi)"
  ok "Its first session checks its own toolchain and asks before installing anything."
}

main "$@"
