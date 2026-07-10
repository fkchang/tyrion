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
#   * If it IS `tyrion note` targeting a story that is already `done` or
#     `blocked`, from a lane with NO in_progress story -> exit 0 (allow). This is
#     the orchestrator affordance: an unclaimed coordinator session may record a
#     post-hoc note on a story its subagents already finished, without weakening
#     the gate for live state mutations.
#   * If it IS, and the lane has NO in_progress story -> exit 2 (block) with a
#     message telling the agent to `tyrion start <slug>` first. This covers
#     `tyrion check`/`tyrion done` always, and `tyrion note` on a pending or
#     in_progress story.
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

# Only gate a ledger-mutating tyrion subcommand invoked as an ACTUAL command —
# the `tyrion` (or `.../bin/tyrion`) token must sit in command position: at the
# start of a command segment or after a shell separator, following only optional
# `VAR=value` env assignments and plain interpreter words (`ruby`, `bundle exec`,
# ...). A flag (e.g. `-C`) or a quote before the token breaks the run, so
# `git -C /path/tyrion check-ignore ...` and `git commit -m "tyrion note: ..."`
# never match. The verb must be a complete token — `check-ignore` is not `check`.
# Group 1 is the verb; group 2 is the first positional arg (the target slug).
gate_re = %r{
  (?:^|[\n;&|])            # start of a command segment
  \s*
  (?:\w+=\S*\s+)*          # optional VAR=value env assignments
  (?:[A-Za-z0-9_.]+\s+)*   # optional plain interpreter words (ruby, bundle, exec)
  (?:\S*/)?                # optional path prefix on the executable (bin/, /path/bin/)
  tyrion\s+
  (note|check|done)        # the gated verb
  (?=[\s;&|]|$)            # verb must be a complete token, not check-ignore
  (?:\s+(\S+))?            # optional first positional arg (the target slug)
}x

m = cmd.match(gate_re)
exit 0 unless m
verb        = m[1]
target_slug = m[2]

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

  epic            = nil
  has_in_progress = false
  if project_slug && (project = store.find_project_by_slug(project_slug)) &&
     epic_slug && (epic = store.find_epic(project['id'], epic_slug))
    has_in_progress   = !store.in_progress_story_for(epic['id'], token).nil? if token
    # Legacy single-session: an unclaimed (NULL claimed_by) in_progress story in
    # the active epic is this lane's story too.
    has_in_progress ||= !store.story_in_progress_unclaimed(epic['id']).nil?
  end

  exit 0 if has_in_progress

  # Orchestrator affordance: a lane with no in_progress story may still record a
  # post-hoc `tyrion note` on a story its subagents already finished — i.e. a
  # story whose status is `done` or `blocked`. `check`/`done` are never permitted
  # without a claim, and `note` on a pending/in_progress story stays blocked.
  if verb == 'note' && target_slug && epic
    story = store.find_story(epic['id'], target_slug)
    exit 0 if story && %w[done blocked].include?(story['status'])
  end

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
