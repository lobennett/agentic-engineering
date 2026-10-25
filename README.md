# agentic-engineering

One command sets up my AI engineering workflow for lab members:

- **[Herdr](https://herdr.dev)**: the terminal runtime your coding agents live in.
- **[Firstmate](https://github.com/lobennett/firstmate)**: one agent you talk to; it runs agents in Herdr tabs and returns pull requests. My fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate).
- **[Skills](https://github.com/lobennett/skills)**: Matt Pocock's engineering skills, from my fork of [mattpocock/skills](https://github.com/mattpocock/skills), for Claude Code, Codex or Pi.
- **[WezTerm](https://wezterm.org)**: the terminal app, with [KevinSilvester/wezterm-config](https://github.com/KevinSilvester/wezterm-config) and its JetBrainsMono Nerd Font.

## 1. Check prerequisites

Done when each is present. Verified on macOS (Apple silicon), but WezTerm setup only offline, not yet end-to-end on a real Mac. Linux relies on upstream installers.

- `git`, `curl`, `gh`, `node`, `jq` (macOS: `brew install git gh node jq`)
- WezTerm: [Homebrew](https://brew.sh) on macOS. On Linux, install [WezTerm](https://wezterm.org/install/linux.html) and the [font](https://www.nerdfonts.com/font-downloads) yourself.
- A coding agent with its own subscription: [Claude Code](https://code.claude.com/docs/en/setup), [Codex](https://github.com/openai/codex) or [Pi](https://pi.dev)

## 2. Install

```sh
curl -fsSL https://raw.githubusercontent.com/lobennett/agentic-engineering/main/setup.sh | bash
```

To read it first: `git clone https://github.com/lobennett/agentic-engineering && agentic-engineering/setup.sh`

It asks before each step; `--yes` accepts all. Done when it prints **Next**; follow it.

It changes only:

- **Herdr**: `~/.local/bin/herdr`, via the checksum-verified installer
- **Firstmate**: `~/firstmate` (git clone); `config/backend` = `herdr` if unset
- **Skills**: Claude Code: plugin entries under `~/.claude`. Codex: `~/.codex/config.toml` and its plugin cache. Pi: a package under `~/.pi/agent`
- **WezTerm**: on macOS, casks `wezterm@nightly` and `font-jetbrains-mono-nerd-font`; config cloned into `~/.config/wezterm` (or `$XDG_CONFIG_HOME/wezterm`) only if none exists. Without fish, `config/launch.lua` can start your login shell instead

Path overrides: the [`setup.sh`](setup.sh) header.

## 3. Sign in yourself

Run `gh auth login`, and sign in to your coding agent on first start.

## 4. Use it

Open WezTerm, then:

```sh
herdr                      # the terminal runtime
cd ~/firstmate && claude   # in a Herdr pane; or codex, or pi
```

Ask the first mate: "look at my repo X, fix the flaky test and open a PR".

In a project, run `/setup-matt-pocock-skills` once, then `/grill-with-docs` before a change, `/tdd` while building, `/ask-matt` when unsure.

For Sherlock, define the host per its [connection guide](https://www.sherlock.stanford.edu/docs/advanced-topics/connection/), then run `ssh sherlock` in a WezTerm tab.

## Update

Re-running the installer skips installed pieces and never pulls checkouts. To update:

- Herdr: `herdr update`
- Firstmate: `/updatefirstmate` in a session (fast-forward only)
- Skills: Claude Code: `claude plugin update mattpocock-skills@mattpocock`. Codex refreshes at startup. Pi: `pi update git:github.com/lobennett/skills`
- WezTerm: `brew upgrade --cask wezterm@nightly --greedy-latest`; config: `git -C ~/.config/wezterm pull --ff-only --no-rebase`

## Troubleshooting

For WezTerm config `Permission denied`, then herdr socket timeout, share these read-only checks:

```sh
ls -lde ~ ~/.config ~/.config/wezterm
tail -n 50 ~/.config/herdr/herdr-server.log
```

If your personal `~/.config` is root-owned by mistake, reset only its owner from your normal account with administrator approval:

```sh
sudo chown "$(id -un)" "$HOME/.config"
```

Group, mode and contents stay unchanged. An IT-managed `~/.config` belongs to your administrator. Then re-run setup without sudo.

## Repository

[`setup.sh`](setup.sh) is the whole installer; [`tests/run.sh`](tests/run.sh) runs it offline in a throwaway HOME with stub tools. MIT licensed; installed tools keep their own licenses.
