#!/bin/bash
# Walks a fake session through every state using the real hook CLI, and checks what the
# Touch Bar helper reports (~/.claude/touchbar/status). Watch the Touch Bar while it runs.
#   ./test.sh          pause 4s per state
#   ./test.sh 1        pause 1s per state
set -uo pipefail
cd "$(dirname "$0")"

PAUSE=${1:-4}
# The helper re-reads state about once a second, so shorter pauses can miss a change.
awk "BEGIN{exit !($PAUSE < 1.2)}" && PAUSE=1.2
HOOK=${HOOK:-$HOME/Applications/ClaudeTouchBar.app/Contents/MacOS/claude-touchbar-hook}
[ -x "$HOOK" ] || HOOK=build/ClaudeTouchBar.app/Contents/MacOS/claude-touchbar-hook
STATUS=$HOME/.claude/touchbar/status
SESSIONS=$HOME/.claude/touchbar/sessions
pgrep -qf 'ClaudeTouchBar.app/Contents/MacOS/ClaudeTouchBar' || { echo "Helper is not running (run ./install.sh)"; exit 1; }

# Park your real sessions during the test so they don't change the result; put them back after.
PARKED=$(mktemp -d)
mkdir -p "$SESSIONS"
find "$SESSIONS" -name '*.json' ! -name 'tb-test-*' -exec mv {} "$PARKED"/ \;
trap 'rm -f "$SESSIONS"/tb-test-*.json; mv -n "$PARKED"/*.json "$SESSIONS"/ 2>/dev/null; rm -rf "$PARKED"' EXIT

fail=0
send() { # event session json-extra
    printf '{"session_id":"%s","hook_event_name":"%s","cwd":"/tmp/touchbar-test"%s}' "$2" "$1" "${3:-}" \
        | CLAUDE_PID=$$ "$HOOK" "$1"
}
expect() { # wanted-status description
    sleep "$PAUSE"
    got=$(cat "$STATUS" 2>/dev/null)
    if [ "$got" = "$1" ]; then echo "  ok    $2  ->  $got"; else echo "  FAIL  $2  ->  got '$got', wanted '$1'"; fail=1; fi
}

echo "Session A:"
send SessionStart tb-test-a;                                        expect "idle 1"      "start        (blue)"
send UserPromptSubmit tb-test-a ',"prompt":"hi"';                   expect "working 1"   "prompt       (orange)"
send PreToolUse tb-test-a ',"tool_name":"Bash"';                    expect "working 1"   "tool         (orange)"
send Notification tb-test-a ',"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"'
                                                                    expect "attention 1" "permission   (yellow, blinking)"
send PostToolUse tb-test-a ',"tool_name":"Bash"';                   expect "working 1"   "approved     (orange)"
send PreToolUse tb-test-a ',"tool_name":"AskUserQuestion"';         expect "attention 1" "question     (yellow)"
send PostToolUse tb-test-a ',"tool_name":"AskUserQuestion"';        expect "working 1"   "answered     (orange)"
send Stop tb-test-a;                                                expect "done 1"      "stop         (green)"

echo "Two sessions, most urgent wins:"
send UserPromptSubmit tb-test-b ',"prompt":"second"';               expect "working 2"   "B working, A done  (orange +1)"
send PermissionRequest tb-test-a ',"tool_name":"Edit"';             expect "attention 2" "A needs you        (yellow +1)"
send Stop tb-test-a;                                                expect "working 2"   "A done again       (orange +1)"
send SessionEnd tb-test-b;                                          expect "done 1"      "B ended            (green)"
send SessionEnd tb-test-a;                                          expect "none 0"      "A ended            (grey)"

[ $fail = 0 ] && echo "All states passed." || { echo "Some states failed."; exit 1; }
