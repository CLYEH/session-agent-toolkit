---
name: restart-session
description: Restart the current agent CLI session (Claude Code, Codex or Antigravity) in the same terminal, or replace it with a fresh session, without the user being present. Use when a restart is the only way forward - an MCP server disconnected and will not reconnect, or an MCP server / plugin / skill / settings change was just installed and needs a restart to load - or when the user asked you to hand the work over to a new session (context reset). Triggers include "restart the session", "restart yourself", "reload MCP", "重啟 session", "開新 session".
---

# Restart session

Replaces the session you are running in. A detached helper waits a few seconds, stops this
process, and types the next command into the shell that launched it, so the next session starts
in the same terminal. You can only replace your own session.

## Choose a mode

| Mode | What starts next | Prompt |
|---|---|---|
| `restart` (default) | The same conversation, resumed. Its first message is a fixed notice telling you to continue where you left off. | None. Do not pass one - it is refused. |
| `new` | A fresh conversation with no history. | Required: the activation prompt becomes its first message. |

Use `restart` to reload MCP servers, plugins or settings and carry on. Use `new` only when the
work should continue with a clean context; the new session knows nothing, so the activation
prompt must say what to do and where the state is (files, branch, a handoff note you wrote first).

## Run it

The scripts are in the `scripts/` folder next to this file. Use the absolute path of that folder
(shown below as `<skill-dir>/scripts`).

Windows, PowerShell:

```powershell
& "<skill-dir>/scripts/restart-session.ps1"
& "<skill-dir>/scripts/restart-session.ps1" -Mode new -ActivationPrompt "Read HANDOFF.md and continue the migration."
```

Windows, from a bash-style shell tool: `powershell.exe -NoProfile -File "<skill-dir>/scripts/restart-session.ps1"` with the same parameters.

macOS / Linux:

```bash
bash "<skill-dir>/scripts/restart-session.sh"
bash "<skill-dir>/scripts/restart-session.sh" --mode new --activation-prompt "Read HANDOFF.md and continue the migration."
```

The session to resume is detected automatically. If the script says it could not determine the
session id, pass your own session / conversation id (a UUID) with `-SessionId` / `--session-id`.

Add `-DryRun` / `--dry-run` to see what would be stopped and typed without doing it.

## Rules

- Make it the **last action of your turn**. When the script prints that the restart is scheduled,
  write one short line saying so and end the turn. Anything still running when the delay
  (5 seconds) expires is killed.
- Before restarting, finish or save in-progress work: files written, background tasks done.
  In `new` mode, write the handoff state to a file first.
- After a `restart`, your first message is the fixed `[restart-session]` notice. Check that the
  thing you restarted for now works (e.g. the MCP tools are back), then continue the task.
  If it is still broken, do not restart in a loop - report it.
- If the script refuses (unsupported shell or terminal, not launched from a shell), report the
  message to the user; do not try to work around it.
- Never call `restart-session-helper.*` directly.

## Limits

- Windows: the session must have been launched from PowerShell.
- macOS: the session must be running in Terminal.app or inside tmux.
- Linux: the session must be running inside tmux.
- The next session starts with the CLI's default options; flags used to launch this one are not replayed.
