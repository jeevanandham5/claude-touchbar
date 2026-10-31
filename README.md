# Claude Touch Bar

A tiny pixel Claude character that lives in your MacBook Pro's Touch Bar and shows what
your [Claude Code](https://claude.com/claude-code) sessions are doing, so you can glance
down instead of switching windows.

| Color | Meaning |
|---|---|
| 🟡 Yellow (blinking) | **Needs you:** a permission prompt, a question, or a plan to approve |
| 🟠 Orange (legs walk) | **Working:** Claude is thinking or running tools |
| 🟢 Green | **Done:** waiting for your next message |
| 🔵 Blue | **Idle:** new session, done for 10+ minutes, or no activity for 20 minutes |
| ⚪ Grey | No Claude Code sessions running |

- It works with Claude Code in the terminal (CLI) and in the Claude desktop app's Code tab.
- With several sessions at once, the doll shows the most urgent one
  (yellow > orange > green > blue), how long it has been that way, and `+N` for the rest.
- When a session starts working, the Touch Bar opens a list of every session by name and
  time (like `touchbar · 2m`; "claude" is left out because the doll already says it). It
  stays open while anything is working or waiting on you, and closes by itself about
  5 seconds after everything is done.
- Close the list with the ✕ or by tapping a session; it then stays closed until the next
  task starts. Tap the doll to open it any time; a list you open yourself stays open until
  you close it.

> Unofficial fan project. Not made by or affiliated with Anthropic.

## What you need

- A MacBook Pro **with a Touch Bar** (2016–2022 models, Intel or Apple Silicon)
- macOS 11 Big Sur or newer (tested on macOS 26)
- Apple's Command Line Tools (for `clang`). If you don't have them:
  ```bash
  xcode-select --install
  ```
  Full Xcode is **not** needed.
- [Claude Code](https://claude.com/claude-code)
- Touch Bar set to show the **Control Strip**: System Settings → Keyboard →
  Touch Bar Settings → "Show Control Strip" on (this is the default)

## Setup (2 minutes)

1. Download the code:
   ```bash
   git clone https://github.com/jeevanandham5/claude-touchbar.git
   cd claude-touchbar
   ```
2. Install:
   ```bash
   ./install.sh
   ```
   This builds the app, copies it to `~/Applications/ClaudeTouchBar.app`, starts it now
   and at every login, and adds the hooks to `~/.claude/settings.json` (your old file is
   saved as `settings.json.bak-touchbar`; your other settings are kept).
3. Look at the right end of your Touch Bar: a small grey Claude should appear.
4. Optional: watch it go through every color (about 50 seconds):
   ```bash
   ./test.sh 4
   ```
5. Restart any Claude Code sessions that were already open, so they load the hooks.
   New sessions work right away.

That's it. Start Claude Code, send a message, and the doll turns orange.

## Uninstall

```bash
./uninstall.sh
```

This stops the app and removes it, its login item, its state files, and only its own
hooks from `~/.claude/settings.json` (backed up first).

## Troubleshooting

**The doll doesn't appear**
- Check the Control Strip is on (see "What you need").
- Is it running? `launchctl print gui/$(id -u)/com.claude.touchbar | grep state`
  should say `state = running`.
- Restart it:
  ```bash
  launchctl kickstart -k gui/$(id -u)/com.claude.touchbar
  ```
- It can drop out after sleep or a Touch Bar reset. The app re-adds itself on wake;
  if not, restart it as above.

**The doll stays grey while Claude works**
- Restart the Claude Code session (hooks load when a session starts).
- Check the hooks are there: `grep claude-touchbar-hook ~/.claude/settings.json`
- See what the app reads: `ls ~/.claude/touchbar/sessions/` and
  `cat ~/.claude/touchbar/status`

**Build fails**
- Run `xcode-select --install`, then `./install.sh` again.

## How it works

```
Claude Code hook ──► claude-touchbar-hook ──► ~/.claude/touchbar/sessions/<id>.json
                                                          │
                       Touch Bar ◄── ClaudeTouchBar.app ◄─┘ (reads every 0.5 s)
```

- **`Sources/Hook.m`** builds `claude-touchbar-hook`. Claude Code runs it on each hook
  event, and it records that session's state in a small JSON file. It prints nothing and
  always exits 0, so it can never block or change what Claude does.
- **`Sources/App.m`** builds `ClaudeTouchBar.app`, a background app with no Dock icon. It
  reads those files, draws the doll, and removes sessions whose Claude process has exited.

| Hook event | State |
|---|---|
| `SessionStart` | idle (blue) |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PreCompact` | working (orange) |
| `PermissionRequest`, `Notification` (permission / question), `PreToolUse` for `AskUserQuestion` or `ExitPlanMode` | needs you (yellow) |
| `Stop` | done (green) |
| `SessionEnd` | removed |

**About the private API.** Apple's public Touch Bar API only shows an app's buttons while
that app is in front. To stay visible all the time, this uses the same private calls as
[MTMR](https://github.com/Toxblh/MTMR) and [Pock](https://github.com/pock/pock)
(`NSTouchBarItem addSystemTrayItem:` and DFRFoundation's
`DFRElementSetControlStripPresenceForIdentifier`). They still work on macOS 26, but a
future macOS could remove them; if that happens, the app quits and logs why.

**Why Objective-C?** It builds with plain `clang` from the Command Line Tools. Some
Command Line Tools installs ship a Swift compiler that doesn't match its SDK and can't
build anything, and Objective-C avoids that.

## Files

| File | What it does |
|---|---|
| `install.sh` | Build, install, start at login, add hooks |
| `uninstall.sh` | Remove all of it |
| `build.sh` | Build `build/ClaudeTouchBar.app` only |
| `test.sh` | Walk a fake session through every state and check the result |
| `hooks.json` | The hooks that `install.sh` adds |

## License

MIT. See [LICENSE](LICENSE).
