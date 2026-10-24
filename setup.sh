#!/usr/bin/env bash
# setup.sh - one-command setup for the agentic-engineering workflow.
#
# Installs, with your consent at each step:
#   1. Herdr      the terminal runtime coding agents live on   (official installer)
#   2. Firstmate  the agent crew you talk to                   (git clone)
#   3. Skills     Matt Pocock's engineering skills, from the lab's fork, into
#                 whichever of Claude Code, Codex and Pi you already have.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/lobennett/agentic-engineering/main/setup.sh | bash
#   ./setup.sh [--yes]
#
#   --yes     answer yes to every install question (for scripted use)
#
# Re-running is safe: anything already installed is left alone, an existing
# Firstmate checkout is never pulled or reset, and a non-Firstmate directory at
# the Firstmate path makes the script stop instead of touching it.
#
# Environment overrides:
#   AE_FIRSTMATE_DIR    Firstmate checkout path        (default: $HOME/firstmate)
#   AE_FIRSTMATE_REPO   Firstmate git URL              (default: https://github.com/lobennett/firstmate)
#   AE_SKILLS_REPO      skills repository, owner/name  (default: lobennett/skills)
#   AE_HERDR_INSTALLER  Herdr installer URL            (default: https://herdr.dev/install.sh)
#   AE_BIN_DIR          where Herdr is installed       (default: $HOME/.local/bin)
set -euo pipefail

AE_FIRSTMATE_DIR=${AE_FIRSTMATE_DIR:-$HOME/firstmate}
AE_FIRSTMATE_REPO=${AE_FIRSTMATE_REPO:-https://github.com/lobennett/firstmate}
AE_SKILLS_REPO=${AE_SKILLS_REPO:-lobennett/skills}
AE_HERDR_INSTALLER=${AE_HERDR_INSTALLER:-https://herdr.dev/install.sh}
AE_BIN_DIR=${AE_BIN_DIR:-$HOME/.local/bin}

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

  say "Next"
  local line
  for line in "${NOTES[@]+"${NOTES[@]}"}"; do
    todo "$line"
  done
  ok "Start Herdr with: herdr"
  local tilde="~" fm_display
  fm_display=${AE_FIRSTMATE_DIR/#"$HOME"/$tilde}
  ok "In a Herdr pane, start your first mate: cd $fm_display && claude   (or codex, or pi)"
  ok "Its first session checks its own toolchain and asks before installing anything."
}

main "$@"
