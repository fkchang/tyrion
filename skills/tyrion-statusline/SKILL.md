---
name: tyrion-statusline
description: Use when toggling the tyrion statusline segment on or off, or checking its current state. Triggered by "/tyrion-statusline", "turn on tyrion statusline", "turn off tyrion statusline", "enable/disable tyrion in statusline".
---

# /tyrion-statusline

Toggle the tyrion segment in the Claude Code statusline (`~/.claude/statusline-command.sh`).

The segment shows: `tyrion: <story-slug> (done/total)` — the in-progress story and epic progress.

## Commands

```bash
# Check current state
ls ~/.tyrion/statusline-enabled 2>/dev/null && echo "ON" || echo "OFF"

# Turn ON
touch ~/.tyrion/statusline-enabled

# Turn OFF
rm -f ~/.tyrion/statusline-enabled

# Toggle (on→off or off→on)
[ -f ~/.tyrion/statusline-enabled ] \
  && rm ~/.tyrion/statusline-enabled && echo "tyrion statusline: OFF" \
  || { touch ~/.tyrion/statusline-enabled && echo "tyrion statusline: ON"; }
```

## Protocol

When invoked, run the toggle one-liner above and report the new state.

If the user says "turn on" or "enable" → run `touch`. If "turn off" or "disable" → run `rm -f`. Otherwise → toggle.

## How it works

`statusline-command.sh` checks for `~/.tyrion/statusline-enabled` on every statusline render. When present, it queries the tyrion DB via sqlite3 for the current in-progress story and epic progress, then appends the segment to the statusline output.
