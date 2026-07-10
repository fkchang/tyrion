#!/usr/bin/env bash
#
# claim-gate.sh — Tyrion PreToolUse claim gate (Claude Code hook).
#
# Turns "claim a story before you touch the ledger" from skill-prose convention
# into a mechanism. Wired as a PreToolUse hook on the Bash tool (see the repo's
# .claude/settings.json), it inspects the command about to run:
#
#   * If the command is NOT `tyrion note|check|done`  -> exit 0 (allow).
#   * If it IS, and the active lane owns an in_progress story -> exit 0 (allow).
#   * If it IS, and the lane has NO in_progress story -> exit 2 (block) with a
#     message telling the agent to `tyrion start <slug>` first.
#
# Contract: exit 2 blocks the tool call and feeds stderr back to the agent
# (Claude Code PreToolUse semantics). Every other outcome — non-tyrion command,
# outside a Tyrion project, missing ruby, any internal error — exits 0 so the
# gate can never wedge normal work. Fail-open is deliberate: a claim gate that
# breaks unrelated Bash calls is worse than one that occasionally lets a
# ledger write through.
#
# The command's own `TYRION_LANE=<token>` prefix (if present) is honored so the
# gate resolves the same lane the command will run under.

# Fail open if ruby is unavailable — nothing to enforce with.
command -v ruby >/dev/null 2>&1 || exit 0

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
lib_dir="$hook_dir/../lib"

# In a source checkout the tyrion library sits at ../lib relative to this hook;
# when tyrion is installed as a gem, `require 'tyrion'` finds it on the load
# path and this -I is simply absent.
ruby_opts=()
[ -f "$lib_dir/tyrion.rb" ] && ruby_opts=(-I "$lib_dir")

decide=$(cat <<'RUBY'
require 'json'

begin
  data = JSON.parse($stdin.read)
rescue StandardError
  exit 0 # unparseable hook payload — not our place to block
end

cmd = data.dig('tool_input', 'command').to_s

# Only gate ledger-mutating tyrion subcommands invoked as an actual command —
# `tyrion`, `bin/tyrion`, `ruby bin/tyrion`, etc. at a command boundary. This
# deliberately does NOT match the words inside a quoted string (e.g. a
# `git commit -m "tyrion note: ..."`), so unrelated Bash is never wedged.
# Everything else passes through.
verb = cmd[%r{(?:^|[\s;&|])(?:\S+/)?tyrion\s+(note|check|done)\b}, 1]
exit 0 unless verb

begin
  require 'tyrion'
rescue LoadError
  exit 0 # can't load the ledger library — fail open
end

begin
  root = Tyrion::Repo.tyrion_root
  exit 0 unless root # outside a Tyrion project — fail open

  # Resolve the lane the command will actually run under: an explicit
  # TYRION_LANE=<token> in the command wins, else the ambient lane identity.
  token = cmd[/\bTYRION_LANE=(\S+)/, 1] || Tyrion::Commands.current_lane_token

  store        = Tyrion::Store.new
  project_slug = Tyrion::Repo.active_project(root)
  epic_slug    = Tyrion::Repo.active_epic(root, token: token)

  has_in_progress = false
  if project_slug && (project = store.find_project_by_slug(project_slug)) &&
     epic_slug && (epic = store.find_epic(project['id'], epic_slug))
    has_in_progress   = !store.in_progress_story_for(epic['id'], token).nil? if token
    # Legacy single-session: an unclaimed (NULL claimed_by) in_progress story in
    # the active epic is this lane's story too.
    has_in_progress ||= !store.story_in_progress_unclaimed(epic['id']).nil?
  end

  exit 0 if has_in_progress

  $stderr.puts <<~MSG
    Tyrion claim gate: no in_progress story in this lane.
    Claim a story before recording ledger updates:
      tyrion start <slug>
    Then re-run your `tyrion #{verb}` command.
  MSG
  exit 2
rescue StandardError
  exit 0 # any internal error — fail open, never wedge the agent
end
RUBY
)

exec ruby "${ruby_opts[@]}" -e "$decide"
