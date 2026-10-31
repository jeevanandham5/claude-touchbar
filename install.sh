#!/bin/bash
# Builds the helper, copies it to ~/Applications, starts it at login with a LaunchAgent,
# and adds the Claude Code hooks to ~/.claude/settings.json (backed up first).
set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.claude.touchbar
DEST=$HOME/Applications/ClaudeTouchBar.app
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist

./build.sh
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f 'ClaudeTouchBar.app/Contents/MacOS/ClaudeTouchBar' 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R build/ClaudeTouchBar.app "$DEST"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$DEST/Contents/MacOS/ClaudeTouchBar</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $DEST and started it ($PLIST)."

# Merge hooks.json into ~/.claude/settings.json, replacing any earlier Touch Bar hooks and
# leaving every other setting and hook alone.
SETTINGS=$HOME/.claude/settings.json
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-touchbar"
/usr/bin/python3 -I - "$SETTINGS" hooks.json <<'PY'
import json, os, sys
path, ours = sys.argv[1], json.load(open(sys.argv[2]))["hooks"]
s = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
hooks = s.setdefault("hooks", {})
for event, groups in ours.items():
    kept = []
    for g in hooks.get(event, []):
        g["hooks"] = [h for h in g.get("hooks", []) if "claude-touchbar-hook" not in h.get("command", "")]
        if g["hooks"]:
            kept.append(g)
    hooks[event] = kept + groups
with open(path, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
PY
echo "Added Claude Code hooks to $SETTINGS. New sessions pick them up; restart running ones."
