# Firstmate config example

Firstmate reads per-home settings from `config/` inside its checkout. That
directory is gitignored upstream, so these files belong to you and survive
`/updatefirstmate`.

`setup.sh` writes exactly one of them, and only when it does not exist yet:

| File      | Value   | Why                                                        |
| --------- | ------- | ---------------------------------------------------------- |
| `backend` | `herdr` | Run crewmates as Herdr tabs instead of the default tmux.   |

Other keys worth knowing (none are written for you; see Firstmate's
[configuration guide](https://github.com/lobennett/firstmate/blob/main/docs/configuration.md)):

- `claude-permission-mode`: permission mode for Claude Code workers.
- `crew-dispatch.json`: which harness and model handles which kind of task.
- `brief-include.md`: text appended to every worker brief, for shared conventions.

Copy a file from here into `~/firstmate/config/` to adopt it.
