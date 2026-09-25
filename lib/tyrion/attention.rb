# frozen_string_literal: true

require 'time'
require_relative 'liveness'

module Tyrion
  # Attention -- "what needs Forrest's attention, Tyrion-wise": a pure fold
  # over already-gathered epic/story data (plus, for lane pid/liveness/
  # worktree info, an already-built Liveness::Snapshot) answering one
  # question per active-or-paused epic: is someone explicitly waiting on
  # this, has it gone quiet mid-flight with no one waiting, or is it fine?
  # Never computed twice -- `tyrion attention` and the web "Needs your
  # attention" view both call `build` over the same `gather`.
  #
  # `waiting` always wins over `stalled`: a paused epic, or one with a story
  # blocked on something, is a decision someone already made, just not yet
  # acted on -- not a mystery. `stalled` is reserved for the epic nobody
  # decided anything about that simply went quiet mid-flight: partially
  # done (some stories done, some not) with no activity past the threshold.
  # Everything else -- unstarted, fully done, or recently active -- needs
  # nobody's attention right now.
  module Attention
    DEFAULT_STALE_DAYS = 7
    ATTENTION_STATUSES = %w[active paused].freeze

    STALLED = 'stalled'
    WAITING = 'waiting'

    # Only a `claude:<pid>:<stamp>` lane token carries a pid worth reporting
    # (Commands.derive_lane_token's own shape). Other shapes -- a codex
    # thread token, a `dispatched:` placeholder, a hand-set label -- have no
    # pid to probe, and are reported as such rather than guessed at.
    CLAUDE_LANE_TOKEN = /\Aclaude:(\d+):/

    module_function

    # -- gather (DB reads only -- no fold logic lives here) ------------------

    # Every epic across every project whose status is active or paused,
    # paired with its story-status counts (Store#epic_graph's own bulk
    # per-epic aggregate) and its full story rows (for activity timestamps,
    # blocked reasons, and lanes). One epic_graph + one stories_for_epic call
    # per project: this is a dashboard/CLI read, not the fleet board's
    # per-poll hot path, so N+1-by-project is the right price for reusing the
    # existing bulk aggregate rather than hand-rolling a second one.
    def gather(store)
      store.list_projects.flat_map do |project|
        graph = store.epic_graph(project['id'])
        graph[:epics].values
                     .select { |epic| ATTENTION_STATUSES.include?(epic['status']) }
                     .map do |epic|
          {
            'project' => project,
            'epic' => epic,
            'counts' => graph[:story_counts][epic['id']],
            'stories' => store.stories_for_epic(epic['id'])
          }
        end
      end
    end

    # -- fold (pure -- no DB, no git, no clock of its own except `now:`) -----

    # `gathered` is `gather`'s return value (or an equivalent list of
    # {'project', 'epic', 'counts', 'stories'} hashes -- e.g. a spec
    # fixture). `snapshot_rows` is Liveness::Snapshot's 'rows' (already-
    # probed pid/liveness/worktree info for every in_progress/blocked story,
    # keyed by story_id) -- optional, since a lane with no snapshot row still
    # reports accurately (pid parsed straight from the token, live: false,
    # worktree_path: nil) rather than raising.
    def build(gathered, snapshot_rows: [], now: Time.now, stale_days: DEFAULT_STALE_DAYS, project_slug: nil)
      considered = Array(gathered).select { |g| project_slug.nil? || g['project']['slug'] == project_slug }
      lanes_by_story = Array(snapshot_rows).to_h { |r| [r['story_id'], r] }

      epics = considered.filter_map { |g| epic_row(g, lanes_by_story, now: now, stale_days: stale_days) }
      stalled = epics.select { |e| e['category'] == STALLED }.sort_by { |e| stalled_sort_key(e) }
      waiting = epics.select { |e| e['category'] == WAITING }.sort_by { |e| -(e['idle_days'] || 0) }

      {
        'generated_at' => now.utc.iso8601,
        'stale_days' => stale_days,
        'summary' => { 'stalled' => stalled.size, 'waiting' => waiting.size,
                        'fine' => considered.size - stalled.size - waiting.size },
        'epics' => stalled + waiting
      }
    end

    # dark_factory epics first, then longest-idle first within each group.
    def stalled_sort_key(epic_row)
      [epic_row['mode'] == 'dark_factory' ? 0 : 1, -(epic_row['idle_days'] || 0)]
    end

    # One epic's classification, or nil when it needs nobody's attention (or
    # isn't active/paused at all -- checked here too, not just in `gather`,
    # so this is a complete, independently testable unit).
    def epic_row(gathered_epic, lanes_by_story, now:, stale_days:)
      epic = gathered_epic['epic']
      return nil unless ATTENTION_STATUSES.include?(epic['status'])

      project = gathered_epic['project']
      counts  = gathered_epic['counts'] || {}
      stories = Array(gathered_epic['stories'])

      blocked_stories = stories.select { |s| s['status'] == 'blocked' }
      waiting = epic['status'] == 'paused' || blocked_stories.any?

      activity_epoch = latest_activity(stories)
      idle_seconds   = activity_epoch && [now.to_i - activity_epoch, 0].max
      idle_days      = idle_seconds && idle_seconds / 86_400
      partial        = counts['done'].to_i.positive? && (counts['pending'].to_i + counts['in_progress'].to_i).positive?
      # "no activity for LONGER than the threshold" -- exactly at the
      # threshold does not (yet) qualify.
      stalled = !waiting && epic['status'] == 'active' && partial &&
                idle_seconds && idle_seconds > stale_days * 86_400

      category = waiting ? WAITING : (stalled ? STALLED : nil)
      return nil unless category

      current = current_story(stories)

      {
        'project_slug' => project['slug'], 'epic_slug' => epic['slug'], 'epic_name' => epic['name'],
        'mode' => epic['mode'] || 'shape', 'status' => epic['status'], 'category' => category,
        'counts' => {
          'done' => counts['done'].to_i, 'pending' => counts['pending'].to_i,
          'in_progress' => counts['in_progress'].to_i, 'blocked' => counts['blocked'].to_i,
          'total' => counts['total'].to_i
        },
        'last_activity_at' => activity_epoch && Time.at(activity_epoch).utc.iso8601,
        'idle_days' => idle_days,
        'waiting_reasons' => waiting_reasons(epic, blocked_stories),
        'current_story' => current && { 'slug' => current['slug'], 'title' => current['title'],
                                         'next_action' => current['next_action'] },
        'lanes' => in_progress_lanes(stories, lanes_by_story),
        'suggested_commands' => suggested_commands(epic, category, current)
      }
    end

    # -- internals ------------------------------------------------------------

    # The newest of a story's four ledger activity timestamps, epoch integer.
    def story_activity(story)
      [story['last_note_at'], story['updated_at'], story['completed_at'], story['claimed_at']]
        .filter_map { |t| Liveness.epoch(t) }.max
    end

    def latest_activity(stories)
      stories.filter_map { |s| story_activity(s) }.max
    end

    def waiting_reasons(epic, blocked_stories)
      reasons = []
      reasons << 'paused' if epic['status'] == 'paused'
      blocked_stories.each do |s|
        reason = s['blocked_on'] || 'no reason recorded'
        disc   = s['blocked_on_discovery']
        reasons << "#{s['slug']}: #{reason}#{disc ? " [#{disc}]" : ''}"
      end
      reasons
    end

    # The one story to surface as "what's going on here": the most recently
    # active in_progress story if any lane is live-claimed, else the first
    # pending story by sequence -- what to pick up next.
    def current_story(stories)
      in_progress = stories.select { |s| s['status'] == 'in_progress' }
      return in_progress.max_by { |s| story_activity(s) || 0 } if in_progress.any?

      stories.select { |s| s['status'] == 'pending' }.min_by { |s| s['sequence'] }
    end

    def in_progress_lanes(stories, lanes_by_story)
      stories.select { |s| s['status'] == 'in_progress' && !s['claimed_by'].to_s.strip.empty? }
             .map { |s| lane_entry(s, lanes_by_story[s['id']]) }
    end

    def lane_entry(story, snapshot_row)
      token = story['claimed_by']
      {
        'token' => token,
        'pid' => claude_pid(token),
        'live' => !!snapshot_row && snapshot_row.dig('signals', 'process') == 'live',
        'story_slug' => story['slug'],
        'worktree_path' => snapshot_row && snapshot_row['worktree_path']
      }
    end

    def claude_pid(token)
      m = CLAUDE_LANE_TOKEN.match(token.to_s)
      m && m[1].to_i
    end

    # Suggestions only -- this module never mutates the ledger itself.
    def suggested_commands(epic, category, current)
      cmds = []
      if category == STALLED
        if current
          cmds << "tyrion epic activate #{epic['slug']} && tyrion resume #{current['slug']}"
          cmds << "tyrion unclaim #{current['slug']}" if current['status'] == 'in_progress'
        end
        cmds << "tyrion epic pause #{epic['slug']}"
        cmds << "tyrion epic archive #{epic['slug']}"
      elsif category == WAITING
        cmds << "tyrion epic activate #{epic['slug']}"
        cmds << "tyrion resume #{current['slug']}" if current
      end
      cmds
    end
  end
end
