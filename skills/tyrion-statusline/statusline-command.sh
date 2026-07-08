#!/usr/bin/env bash
# Claude Code statusline command
# Output format: <model> | <context bar> | <git branch> [| tyrion: <epic>/<story> (N/M)]
#
# Canonical source for ~/.claude/statusline-command.sh. Install with:
#   cp skills/tyrion-statusline/statusline-command.sh ~/.claude/statusline-command.sh
#
# Tyrion segment: toggle with:
#   touch ~/.tyrion/statusline-enabled   # on
#   rm ~/.tyrion/statusline-enabled      # off

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // ""')

# Build 10-char progress bar
if [ -n "$used_pct" ]; then
  pct_int=$(printf '%.0f' "$used_pct")
  filled=$(( pct_int * 10 / 100 ))
  [ $filled -gt 10 ] && filled=10
  empty=$(( 10 - filled ))
  bar=""
  for i in $(seq 1 $filled); do bar="${bar}█"; done
  for i in $(seq 1 $empty);  do bar="${bar}░"; done
  ctx_part="${bar} ${pct_int}%"
else
  ctx_part="░░░░░░░░░░ 0%"
fi

# Get git branch from cwd (skip optional locks, no stderr noise)
branch=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
fi

# Optional tyrion segment — only when ~/.tyrion/statusline-enabled exists
tyrion_part=""
if [ -f "$HOME/.tyrion/statusline-enabled" ] && [ -n "$cwd" ]; then
  # Walk up from cwd to find a .tyrion dir (handles worktrees and subdirs)
  d="$cwd"
  tyrion_dir=""
  while [ "$d" != "/" ]; do
    if [ -d "$d/.tyrion" ]; then tyrion_dir="$d/.tyrion"; break; fi
    d=$(dirname "$d")
  done

  if [ -n "$tyrion_dir" ]; then
    # Preferred path: lane-aware `tyrion statusline` resolves THIS terminal's lane
    # via process identity (the ps-ancestor walk sqlite3 cannot do), so two terminals
    # on the same epic each show their own in-progress story. The gem wrapper may print
    # "Resolving dependencies..." to stdout in a Gemfile dir, so keep only the
    # segment-shaped line: "<epic>/<story> (n/m)" or "<epic> (n/m)".
    if command -v tyrion >/dev/null 2>&1; then
      seg=$( (cd "$cwd" && tyrion statusline) 2>/dev/null \
             | grep -E '\([0-9]+/[0-9]+\)[[:space:]]*$' | tail -n1)
      [ -n "$seg" ] && tyrion_part="tyrion: ${seg}"
    else
      # Fallback: tyrion CLI unavailable — query the shared .tyrion/active-epic + DB
      # directly. Not lane-aware, but keeps the segment working.
      proj=$(cat "$tyrion_dir/active-project" 2>/dev/null)
      epic=$(cat "$tyrion_dir/active-epic" 2>/dev/null)
      db="${TYRION_DB_PATH:-$HOME/.tyrion/tyrion.db}"

      if [ -n "$proj" ] && [ -n "$epic" ] && [ -f "$db" ]; then
        slug=$(sqlite3 "$db" \
          "SELECT s.slug FROM stories s
           JOIN epics e ON s.epic_id = e.id
           JOIN projects p ON e.project_id = p.id
           WHERE p.slug='$proj' AND e.slug='$epic' AND s.status='in_progress'
           LIMIT 1" 2>/dev/null)
        done_n=$(sqlite3 "$db" \
          "SELECT COUNT(*) FROM stories s
           JOIN epics e ON s.epic_id = e.id
           JOIN projects p ON e.project_id = p.id
           WHERE p.slug='$proj' AND e.slug='$epic' AND s.status='done'" 2>/dev/null)
        total_n=$(sqlite3 "$db" \
          "SELECT COUNT(*) FROM stories s
           JOIN epics e ON s.epic_id = e.id
           JOIN projects p ON e.project_id = p.id
           WHERE p.slug='$proj' AND e.slug='$epic' AND s.status!='abandoned'" 2>/dev/null)

        if [ -n "$slug" ]; then
          tyrion_part="tyrion: ${epic}/${slug} (${done_n}/${total_n})"
        elif [ -n "$proj" ]; then
          tyrion_part="tyrion: ${epic} (${done_n}/${total_n})"
        fi
      fi
    fi
  fi
fi

# Assemble output — base parts first, tyrion appended if active
base=""
if [ -n "$branch" ]; then
  base=$(printf "%s | %s | %s" "$model" "$ctx_part" "$branch")
else
  base=$(printf "%s | %s" "$model" "$ctx_part")
fi

if [ -n "$tyrion_part" ]; then
  printf "%s | %s\n" "$base" "$tyrion_part"
else
  printf "%s\n" "$base"
fi
