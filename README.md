# session-agent-toolkit

Session tools for coding agents. One skill so far, `restart-session`: it lets an agent restart its
own CLI session, replace it with a fresh one, or switch to another existing session - in the same
terminal, with nobody at the
keyboard. Typical use: an MCP server dropped or was just installed, and the session has to restart
to pick it up.

Works with Claude Code, Codex and Antigravity (`agy`). Nothing changes in how you start the agent.

## Install

Claude Code:

```
/plugin install session-agent-toolkit --marketplace CLYEH/session-agent-toolkit
```

Codex:

```
codex plugin marketplace add CLYEH/session-agent-toolkit
codex plugin add session-agent-toolkit@session-agent-toolkit
```

Antigravity:

```
agy plugin install https://github.com/CLYEH/session-agent-toolkit
```

All three install straight from this repository. Claude Code and Codex read it as a marketplace
(`.claude-plugin/marketplace.json`, `.agents/plugins/marketplace.json`). Antigravity has no
third-party marketplaces - its `plugin@marketplace` form only knows Google's own catalogs - so it
installs from the repository URL instead, picking the plugin up from `plugins/`.

## How it works

The agent calls `restart-session.ps1` (Windows) or `restart-session.sh` (macOS / Linux) from its
shell tool. The script returns at once; a detached helper waits (5 s by default) for the turn to
end, stops the agent process tree, and types the next command into the shell that launched the agent:

| Mode | What starts next | Typed command (claude) |
|---|---|---|
| `restart` (default) | The same conversation, resumed, with a fixed notice as its first message | `claude --resume <own-session-id> '<fixed restart notice with a restart token>'` |
| `new` | A fresh conversation that starts from an activation prompt | `claude "<fixed notice><origin and activation prompt, loaded from a file>"` |
| `switch` | Another existing conversation, resumed, with the activation prompt as its next message | `claude --resume <other-session-id> "<fixed notice><origin and activation prompt, loaded from a file>"` |

## Platform support

| Platform | Requirement | Tested |
|---|---|---|
| Windows | Agent launched from PowerShell (pwsh or Windows PowerShell), any terminal | stand-in agents in CI; a real Claude Code session |
| macOS | Agent running in Terminal.app, or inside tmux | stand-in agents in CI (both terminals) |
| Linux | Agent running inside tmux | stand-in agents in CI |

There is no universal way to type into a terminal from outside on macOS / Linux, so each terminal
needs its own support. Not supported yet: iTerm2, and Linux terminals outside tmux.

Stand-in agents are small scripts named like the real CLIs; they check what gets stopped and typed.
Only Claude Code on Windows has been run end to end with a real session.

## Safety

The script is meant to run without a permission prompt, so the caller controls very little:

- It can only replace the session it runs inside (found by walking up the process tree).
- The typed command is a fixed template. The only variable part is a session id that must be a
  plain UUID.
- `restart` means "this session" on every CLI and takes no session id from the caller. The id is
  what the CLI itself reports: Claude Code's per-process session record (found through the agent
  process, not through the caller's environment), or the id Codex / Antigravity hand to their
  tools in an environment variable. If the CLI does not say, the script refuses and changes nothing.
- A restart carries a random token. The script prints it into the calling session's tool output
  and the restart notice quotes it, telling the session to stop and report if it cannot find the
  token there. So a conversation that is resumed by mistake can tell it did not ask.
- `restart` mode has no prompt at all. In `new` mode the activation prompt is never typed: it is
  written to a file and loaded by the typed command as one prefixed argument, so it cannot become
  shell syntax or a CLI option.
- A session that receives an agent-written prompt (`new`, `switch`) is told where it came from.
  The message starts with a fixed notice - part of the typed command, so the calling agent cannot
  remove or reword it - saying that an AI agent started or switched to the session and that the
  user did not type the message, followed by the originating session id (when known) and the
  path of the script. The activation prompt comes after that.
- `switch` cannot be aimed at the caller's own session (that would be a restart carrying a
  prompt), and for Claude Code the target must be an existing session of the same project.

If you allow-list it, allow only `restart-session.ps1` / `restart-session.sh`. Never allow-list
`restart-session-helper.*`: that half does the typing and trusts its caller to be the launcher.

The next session starts with the CLI's default options; launch flags are not replayed.

## Tests

```
pwsh -NoProfile -File tests/test-restart-session.ps1     # Windows; opens two minimized console windows
bash tests/run-in-tmux.sh                                # macOS / Linux, needs tmux
bash tests/run-in-terminal-app.sh                        # macOS, drives Terminal.app
docker run --rm -v "<repo root>:/plugin:ro" debian:stable-slim bash /plugin/tests/run-in-docker.sh
```

## License

MIT
