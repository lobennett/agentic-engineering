# agentic-engineering

One command sets up the AI engineering workflow I use, so lab members can copy it:

- **[Herdr](https://herdr.dev)**: the terminal runtime your coding agents live in.
- **[Firstmate](https://github.com/lobennett/firstmate)**: one agent you talk to; it runs agents in Herdr tabs and returns finished pull requests. My fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate), kept in sync.
- **[Skills](https://github.com/lobennett/skills)**: Matt Pocock's engineering skills (grilling, specs, TDD, code review), from my fork of [mattpocock/skills](https://github.com/mattpocock/skills), for whichever of Claude Code, Codex and Pi you have.
- **[WezTerm](https://wezterm.org)**: the terminal app, with [KevinSilvester/wezterm-config](https://github.com/KevinSilvester/wezterm-config) and its JetBrainsMono Nerd Font.

## Prerequisites

macOS or Linux, per the upstream installers. Verified on macOS (Apple silicon); the WezTerm step only in offline tests.

- `git`, `curl`, `gh`, `node`, `jq` (macOS: `brew install git gh node jq`)
- WezTerm: [Homebrew](https://brew.sh) on macOS. On Linux, install [WezTerm](https://wezterm.org/install/linux.html) and the [font](https://www.nerdfonts.com/font-downloads) yourself.
- At least one coding agent, with its own subscription: [Claude Code](https://code.claude.com/docs/en/setup), [Codex](https://github.com/openai/codex) or [Pi](https://pi.dev)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/lobennett/agentic-engineering/main/setup.sh | bash
```

To read it first: `git clone https://github.com/lobennett/agentic-engineering && agentic-engineering/setup.sh`

It asks before each step; decline one to leave it out. `--yes` answers every question.

## What changes on disk

- **Herdr**: `~/.local/bin/herdr`, through the official checksum-verified installer
- **Firstmate**: `~/firstmate` (git clone) and `~/firstmate/config/backend` = `herdr`, only if absent
- **Skills**: Claude Code: plugin entries under `~/.claude`. Codex: `~/.codex/config.toml` and its plugin cache. Pi: a package under `~/.pi/agent`
- **WezTerm**: macOS: casks `wezterm@nightly` (recommended) and `font-jetbrains-mono-nerd-font`. Config: git clone into `~/.config/wezterm` (or `$XDG_CONFIG_HOME/wezterm`), only if no WezTerm config exists. Without fish, `config/launch.lua` can start your login shell

Nothing else is touched; overrides are in the `setup.sh` header.

## Logins you do yourself

The script never touches credentials. Run `gh auth login`, and sign in to your coding agent when you first start it. Herdr and WezTerm need no account.

## Use it

Open WezTerm, then:

```sh
herdr                      # the terminal runtime
cd ~/firstmate && claude   # in a Herdr pane; or codex, or pi
```

For Sherlock, run `ssh sherlock` in a WezTerm tab. Set up the `sherlock` SSH host with Sherlock's [connection guide](https://www.sherlock.stanford.edu/docs/advanced-topics/connection/). Nothing is installed on Sherlock.

Ask the first mate: "look at my repo X, fix the flaky test and open a PR". Its first session checks its toolchain and asks before installing anything.

In a project, run `/setup-matt-pocock-skills` once. Then `/grill-with-docs` before a change, `/tdd` while building, `/ask-matt` when unsure.

## Update or re-run

Re-run the install command. Installed pieces are skipped; existing checkouts are never pulled or reset.

- Herdr: `herdr update`
- Firstmate: `/updatefirstmate` inside a session (fast-forward only)
- Skills: Claude Code: `claude plugin update mattpocock-skills@mattpocock`. Codex refreshes at startup. Pi: `pi update git:github.com/lobennett/skills`
- WezTerm: `brew upgrade --cask wezterm@nightly --greedy-latest`. Config: `git -C ~/.config/wezterm pull --ff-only --no-rebase` (a `launch.lua` edit survives unless upstream changed it; then git refuses, changing nothing)

## Repository

`setup.sh` is the whole installer. `tests/run.sh` runs it offline in a throwaway HOME with stub tools. MIT licensed; each installed tool and config keeps its own license.
