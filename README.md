# agentic-engineering

One command sets up the AI engineering workflow I use, so lab members can copy it:

- **[Herdr](https://herdr.dev)**: the terminal runtime your coding agents live in.
- **[Firstmate](https://github.com/lobennett/firstmate)**: one agent you talk to. It runs a crew of agents in Herdr tabs and brings back finished pull requests. My fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate), kept in sync.
- **[Skills](https://github.com/lobennett/skills)**: Matt Pocock's engineering skills (grilling, specs, TDD, code review), from my fork of [mattpocock/skills](https://github.com/mattpocock/skills), installed into whichever of Claude Code, Codex and Pi you have.

## Prerequisites

macOS or Linux, per the upstream installers. This script was verified on macOS (Apple silicon).

- `git`, `curl`, `gh`, `node`, `jq` (macOS: `brew install git gh node jq`)
- At least one coding agent, with its own subscription: [Claude Code](https://code.claude.com/docs/en/setup), [Codex](https://github.com/openai/codex) or [Pi](https://pi.dev)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/lobennett/agentic-engineering/main/setup.sh | bash
```

Prefer to read it first? `git clone https://github.com/lobennett/agentic-engineering && agentic-engineering/setup.sh`

The script asks before each step; decline one to leave it out. `--yes` answers every question, for scripted use.

## What changes on disk

| Step      | Writes                                                                                                                      |
| --------- | --------------------------------------------------------------------------------------------------------------------------- |
| Herdr     | `~/.local/bin/herdr`, through the official checksum-verified installer                                                     |
| Firstmate | `~/firstmate` (git clone) and `~/firstmate/config/backend` = `herdr`, only if absent                                        |
| Skills    | Claude Code: marketplace and plugin entries under `~/.claude`. Codex: entries in `~/.codex/config.toml` plus its plugin cache. Pi: a package under `~/.pi/agent` |

Nothing else is touched. `AE_FIRSTMATE_DIR`, `AE_FIRSTMATE_REPO`, `AE_SKILLS_REPO` and `AE_BIN_DIR` override paths and sources; see the header of `setup.sh`.

## Logins you do yourself

The script never touches credentials. Run `gh auth login` for GitHub, and sign in to your coding agent the first time you start it (`claude`, `codex` or `pi`). Herdr needs no account.

## Use it

```sh
herdr                      # open the terminal runtime
cd ~/firstmate && claude   # in a Herdr pane; or codex, or pi
```

Talk to the first mate: "look at my repo X, fix the flaky test and open a PR". Its first session checks its own toolchain and asks before installing anything.

In a project, run `/setup-matt-pocock-skills` once. Then `/grill-with-docs` before a change, `/tdd` while building, `/ask-matt` when unsure.

## Update or re-run

Re-run the install command. Installed pieces are detected and skipped, and an existing Firstmate checkout is never pulled or reset.

- Herdr: `herdr update`
- Firstmate: `/updatefirstmate` inside a session (fast-forward only)
- Skills: Claude Code: `claude plugin update mattpocock-skills@mattpocock`. Codex refreshes the plugin at startup. Pi: `pi update git:github.com/lobennett/skills`

The skills fork follows upstream through `gh repo sync lobennett/skills`.

## Repository

`setup.sh` is the whole installer. `tests/run.sh` runs it offline in a throwaway HOME with stub tools. MIT licensed; Herdr, Firstmate and the skills keep their own licenses.
