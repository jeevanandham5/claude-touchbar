#!/bin/bash
# Stops the helper, removes the LaunchAgent, the app, its state files, and its Claude Code hooks.
set -uo pipefail

LABEL=com.claude.touchbar
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -f 'ClaudeTouchBar.app/Contents/MacOS/ClaudeTouchBar' 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/ClaudeTouchBar.app" "$HOME/.claude/touchbar"

# Drop every hook whose command runs claude-touchbar-hook; leave all other settings alone.
SETTINGS=$HOME/.claude/settings.json
if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak-touchbar"
    /usr/bin/python3 -I - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    s = json.load(f)
hooks = s.get("hooks", {})
for event in list(hooks):
    groups = []
    for g in hooks[event]:
        g["hooks"] = [h for h in g.get("hooks", []) if "claude-touchbar-hook" not in h.get("command", "")]
        if g["hooks"]:
            groups.append(g)
    if groups:
        hooks[event] = groups
    else:
        del hooks[event]
if not hooks:
    s.pop("hooks", None)
with open(path, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
PY
    echo "Removed Touch Bar hooks from $SETTINGS (backup: $SETTINGS.bak-touchbar)."
fi
echo "ClaudeTouchBar uninstalled."
