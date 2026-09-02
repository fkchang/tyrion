# frozen_string_literal: true

require 'time'
require 'json'
require_relative 'liveness/worktree_resolver'
require_relative 'liveness/snapshot'

module Tyrion
  # Liveness — derives "what is this lane doing, and how do I know?" from an
  # already-gathered snapshot. Pure functions: no DB, no git, no clock of its
  # own (callers pass `now:`), so every state in here is reproducible from its
  # inputs alone.
  #
  # The governing rule is that an unknown stays visible. A lane whose worktree
  # could not be probed is not a quiet lane, a process we cannot see is not a
  # dead process, and neither may be rendered as though we had looked and found
  # nothing. The board is worth nothing the first time it lies about a lane, so
  # every path below either produces a finding or names the gap.
  module Liveness
    # Age ladder thresholds, in seconds. Below the first is live, then working,
    # then quiet, and at or above the last is stalled.
    LIVE_SECONDS    = 120
    WORKING_SECONDS = 900
    STALLED_SECONDS = 1800

    DEAD               = 'dead'
    UNCLAIMED          = 'unclaimed'
    DISPATCHED         = 'dispatched'
    WORKTREE_MISSING   = 'worktree_missing'
    WORKTREE_AMBIGUOUS = 'worktree_ambiguous'
    BLOCKED            = 'blocked'
    LIVE               = 'live'
    WORKING            = 'working'
    QUIET              = 'quiet'
    STALLED            = 'stalled'

    EVIDENCE_FULL   = 'full'
    EVIDENCE_LEDGER = 'ledger only'

    # Attention severity, lowest number first. The five the story names keep
    # their stated order (dead, worktree, stalled, unclaimed, blocked);
    # `dispatched` sits next to stalled because its reason is also staleness —
    # a lane that was handed out and never picked up.
    SEVERITY = {
      DEAD => 1,
      WORKTREE_MISSING => 2, WORKTREE_AMBIGUOUS => 2,
      STALLED => 3,
      DISPATCHED => 4,
      UNCLAIMED => 5,
      BLOCKED => 6
    }.freeze

    DISPATCH_PREFIX = 'dispatched:'

    # Epic event feed (Changes tab, fleet-visibility/epic-event-queries).
    EVENT_FEED_LIMIT = 50

    # kind => the human-facing 'action' value the block/unblock/reopen
    # commands stamp into metadata (commands.rb ~1524-1591). These are the
    # ONLY note rows that ever carry metadata.action, and each maps to its
    # own lifecycle event kind rather than the generic 'note' kind -- the
    # double-emit trap epic_events exists to close.
    LIFECYCLE_ACTION_KIND = { 'block' => 'blocked', 'unblock' => 'unblocked', 'reopen' => 'reopened' }.freeze

    module_function

    # Derive one lane row from its gathered signals.
    #
    # `lane` carries the ledger row (slug, status, claimed_by, started_at,
    # updated_at, last_note_at, blocked_on), the newest note/gate/commit/criterion
    # rows, the process probe (`liveness`), the resolver result (`resolution`)
    # and the worktree signals (`worktree`) — each source reporting nil for "no
    # evidence" independently of the others.
    def lane_row(lane, now: Time.now)
      signals   = signals_for(lane)
      newest    = signals.values.grep(Integer).max
      age       = newest && [now.to_i - newest, 0].max # clock skew clamps to zero, never negative
      state     = derive_state(lane, age)
      evidence  = worktree_evidence?(lane) ? EVIDENCE_FULL : EVIDENCE_LEDGER
      worktree  = lane['worktree'] || {}
      at        = attention_at(lane, signals, newest)

      {
        'story_id' => lane['story_id'], 'slug' => lane['slug'],
        'project_id' => lane['project_id'], 'project_slug' => lane['project_slug'],
        'epic_slug' => lane['epic_slug'], 'status' => lane['status'],
        'claimed_by' => lane['claimed_by'], 'lane' => lane_label(lane['claimed_by']),
        'state' => state, 'display_state' => display_state(state, evidence),
        'newest_at' => newest, 'age_seconds' => age,
        'signals' => signals, 'evidence' => evidence,
        'resolution_state' => lane.dig('resolution', 'state'),
        'resolution_paths' => lane.dig('resolution', 'paths') || [],
        'worktree_path' => lane.dig('resolution', 'path'),
        'dirty_count' => worktree['dirty_count'],
        'newest_dirty_mtime' => worktree['newest_dirty_mtime'],
        'commit_sha' => worktree['commit_sha'], 'commit_subject' => worktree['commit_subject'],
        'partial' => worktree['partial'] ? true : false,
        'blocked_on' => lane['blocked_on'],
        'met' => lane.dig('criterion', 'met'), 'total' => lane.dig('criterion', 'total'),
        'attention_at' => at,
        # Measured from `attention_at`, not from `newest_at`, so a blocked
        # item's sort position matches the timestamp it displays. Sorting one
        # and showing the other would float a long-stuck block to the bottom
        # the moment someone appended a note to it.
        'attention_age_seconds' => at && [now.to_i - at, 0].max
      }
    end

    def lane_rows(lanes, now: Time.now) = Array(lanes).map { |l| lane_row(l, now: now) }

    # The rows that want a human, worst first. Not every state qualifies: live,
    # working and quiet are the board doing its job quietly, and a `dispatched`
    # lane only qualifies once it is older than the stalled threshold, since a
    # lane that was just handed out has not had time to do anything yet.
    def attention_items(rows)
      Array(rows).filter_map { |row| attention_item(row) }
                 .sort_by { |i| [i['severity'], -(i['age_seconds'] || 0)] }
    end

    # The human-readable lane name inside a token. Every token form
    # (`v0-A`, `v0-A:<thread>`, `claude:<pid>:<stamp>`, `dispatched:<label>`)
    # carries its label in a known position; nil has none, and saying so beats
    # rendering an empty column.
    def lane_label(claimed_by)
      token = claimed_by.to_s
      return UNCLAIMED if token.strip.empty?
      return token.delete_prefix(DISPATCH_PREFIX) if token.start_with?(DISPATCH_PREFIX)

      token.split(':').first
    end

    # -- internals ----------------------------------------------------------

    # The newest timestamp PER SOURCE, not just the winner. This is what lets a
    # row say "edit 40s · note 20m": a lane writing code without writing notes
    # is alive and reads differently from one with no signal at all, and
    # collapsing to a single max would erase exactly that distinction.
    #
    # `claimed`, `started` and `updated` are in the pool deliberately, not by
    # oversight. A story claimed thirty seconds ago has no notes yet and must
    # still read live, and the design calls for `stories.updated_at` to count so
    # that editing a story's context or next action registers as activity even
    # though no note was written.
    def signals_for(lane)
      worktree = lane['worktree'] || {}
      {
        'note'      => epoch(lane.dig('note', 'created_at') || lane['last_note_at']),
        'criterion' => epoch(lane.dig('criterion', 'newest_checked_at')),
        'gate'      => epoch(lane.dig('gate', 'created_at')),
        'commit'    => epoch(worktree['commit_at'] || lane.dig('commit', 'created_at')),
        'edit'      => epoch(worktree['newest_dirty_mtime']),
        'claimed'   => epoch(lane['claimed_at']),
        'started'   => epoch(lane['started_at']),
        'updated'   => epoch(lane['updated_at']),
        'process'   => (lane['liveness'] || :unknown).to_s
      }
    end

    # Overrides first, in this order, then the age ladder. Two orderings here
    # are decisions, not accidents, and both are pinned by specs.
    #
    # `blocked` outranks `dead`: a blocked story was deliberately taken out of
    # the running, so its process being gone is the expected consequence, not a
    # second problem. Reporting it as `dead` would raise a severity-1 alarm
    # about a lane nobody expects to be alive.
    #
    # `unclaimed` and `dispatched` come BEFORE the worktree states because
    # neither token can resolve to a worktree by construction (a nil token has
    # no hash; a `dispatched:` placeholder has no lane directory anywhere).
    # Checking resolution first would label every one of them
    # `worktree_missing`, which is true and useless.
    def derive_state(lane, age)
      return BLOCKED    if lane['status'] == BLOCKED
      return DEAD       if lane['liveness'] == :dead
      return UNCLAIMED  if lane['claimed_by'].to_s.strip.empty?
      return DISPATCHED if lane['claimed_by'].to_s.start_with?(DISPATCH_PREFIX)

      case lane.dig('resolution', 'state')
      when WorktreeResolver::MISSING   then return WORKTREE_MISSING
      when WorktreeResolver::AMBIGUOUS then return WORKTREE_AMBIGUOUS
      end

      age_ladder(age)
    end

    # A lane with no signal at all is stalled, not live. The evidence marker is
    # what keeps that honest: with nothing to go on it renders as `stalled?`.
    def age_ladder(age)
      return STALLED if age.nil?
      return LIVE    if age < LIVE_SECONDS
      return WORKING if age < WORKING_SECONDS
      return QUIET   if age < STALLED_SECONDS

      STALLED
    end

    # Worktree evidence exists only when we actually looked and got an answer.
    # A `partial` probe (timed out) is not evidence, and neither is a hash whose
    # every field came back nil.
    def worktree_evidence?(lane)
      worktree = lane['worktree']
      return false if worktree.nil? || worktree['partial']

      !worktree['dirty_count'].nil? || !worktree['commit_at'].nil?
    end

    # Only `stalled` earns the question mark. Absence of evidence is not
    # evidence of absence, and stalled is the one state that asserts absence.
    def display_state(state, evidence)
      state == STALLED && evidence == EVIDENCE_LEDGER ? "#{STALLED}?" : state
    end

    # The timestamp an attention item's reason is measured from — for most
    # states the lane's newest signal, since the reason IS the silence.
    #
    # Blocked is the exception: its reason is the block, not the silence, so it
    # is measured from the row's last write. Known imprecision, and the schema's
    # fault rather than a choice: there is no `blocked_at` column, and
    # `stories.updated_at` also moves when a context or next-action edit lands
    # on an already-blocked story, so a blocked item's age can read younger than
    # the block actually is. It is the closest honest stamp available.
    #
    # No `|| signals['started'] || signals['updated']` fallback on the other
    # branch: `newest` is the max over this very hash, so if it is nil those are
    # nil too. A fallback that can never fire reads as a safety net that isn't.
    def attention_at(lane, signals, newest)
      return signals['updated'] || newest if lane['status'] == BLOCKED

      newest
    end

    def attention_item(row)
      state = row['state']
      return nil unless SEVERITY.key?(state)
      return nil if state == DISPATCHED && (row['age_seconds'] || 0) < STALLED_SECONDS

      { 'story_id' => row['story_id'], 'slug' => row['slug'], 'lane' => row['lane'],
        'project_slug' => row['project_slug'], 'epic_slug' => row['epic_slug'],
        'kind' => attention_kind(state), 'severity' => SEVERITY[state],
        'reason' => reason_for(row, state), 'at' => row['attention_at'],
        'age_seconds' => row['attention_age_seconds'] }
    end

    # The two worktree states share one attention kind, since the thing a human
    # does about them is the same: go find out which worktree this lane is in.
    def attention_kind(state)
      [WORKTREE_MISSING, WORKTREE_AMBIGUOUS].include?(state) ? 'worktree' : state
    end

    def reason_for(row, state)
      case state
      when DEAD               then "process gone (#{row['lane']})"
      when UNCLAIMED          then 'in progress with no lane claiming it'
      when DISPATCHED         then "dispatched to #{row['lane']} and never picked up"
      when WORKTREE_MISSING   then "no worktree carries lane #{row['lane']}"
      when WORKTREE_AMBIGUOUS then "lane #{row['lane']} matches #{row['resolution_paths'].join(', ')}"
      when BLOCKED            then "blocked: #{row['blocked_on'] || 'no reason recorded'}"
      else                         'no signal past the stalled threshold'
      end
    end

    # Ledger timestamps are ISO8601 strings; worktree signals are already epoch
    # integers. Everything downstream compares them, so they normalize here.
    # An unparseable value becomes nil rather than raising — "we could not read
    # this" collapses into "no evidence", which is the conservative direction:
    # it can cost a lane a signal, never invent one.
    def epoch(value)
      case value
      when nil       then nil
      when Integer   then value
      when Time      then value.to_i
      else                Time.parse(value.to_s).to_i
      end
    rescue ArgumentError
      nil
    end

    # ── Epic event feed (Changes tab, fleet-visibility/epic-event-queries) ──
    #
    # There is no event log; this derives one from Store's four epic-scoped
    # bulk reads per the design's derivation table. Every event is a plain
    # Hash with a symbol `:kind`, an integer `:at` (epoch, via `epoch` above),
    # and `:story_slug`; kind-specific fields (`:text`, `:disc_id`, ...) ride
    # alongside. Claim events are omitted entirely -- a claim only updates the
    # story row and emits no note, so there is nothing to derive it from.
    def epic_events(store, epic_id, limit: EVENT_FEED_LIMIT)
      events = []
      events.concat(note_events(store.epic_notes_recent(epic_id, limit: limit)))
      events.concat(criterion_events(store.epic_criteria_checked_recent(epic_id, limit: limit)))
      events.concat(lifecycle_events(store.epic_story_lifecycle(epic_id, limit: limit)))
      events.concat(mark_events(store.epic_marks_recent(epic_id, limit: limit)))
      events.sort_by { |e| -(e[:at] || 0) }.first(limit)
    end

    # One event per note row -- EXCEPT a block/unblock/reopen row, which
    # already carries its own lifecycle kind via metadata.action and must not
    # also surface as a generic 'note' (that's the double-emit this guards
    # against), and a gate/commit row, which gets its own richer kind instead
    # of the generic one.
    def note_events(notes)
      notes.filter_map do |n|
        meta = parse_note_metadata(n['metadata'])
        action = meta && meta['action']

        if (kind = LIFECYCLE_ACTION_KIND[action])
          { kind: kind, at: epoch(n['created_at']), story_slug: n['story_slug'], text: n['body'] }
        elsif n['kind'] == 'gate'
          gate_text = meta && "#{meta['gate']}: #{meta['result']}"
          { kind: 'gate', at: epoch(n['created_at']), story_slug: n['story_slug'], text: gate_text || n['body'] }
        elsif n['kind'] == 'commit'
          shas = meta && meta['shas']
          { kind: 'commit', at: epoch(n['created_at']), story_slug: n['story_slug'],
            text: Array(shas).any? ? "commit #{Array(shas).join(', ')}" : n['body'] }
        else
          { kind: 'note', at: epoch(n['created_at']), story_slug: n['story_slug'], text: n['body'] }
        end
      end
    end

    def criterion_events(rows)
      rows.map do |c|
        { kind: 'criterion_checked', at: epoch(c['checked_at']), story_slug: c['story_slug'],
          text: "checked: #{c['text']}" }
      end
    end

    def lifecycle_events(rows)
      rows.flat_map do |s|
        events = []
        events << { kind: 'started', at: epoch(s['started_at']), story_slug: s['slug'], text: 'started' } if s['started_at']
        events << { kind: 'done', at: epoch(s['completed_at']), story_slug: s['slug'], text: 'done' } if s['completed_at']
        events
      end
    end

    # Output.discovery_glance_text is the single headline-or-question fallback
    # rule CLI and web already share (CLAUDE.md's "Headline" section) --
    # reused here rather than re-deriving a second, weaker version of it.
    def mark_events(rows)
      rows.map do |d|
        { kind: 'mark', at: epoch(d['created_at']), story_slug: d['story_slug'], disc_id: d['id'],
          text: "mark filed: #{Output.discovery_glance_text(d)}" }
      end
    end

    # Every caller of Store#add_note pre-serializes its metadata with
    # JSON.dump before passing it in, so every row here is either nil or a
    # JSON string. An unparseable value collapses to nil rather than raising
    # -- same conservative direction as `epoch` above.
    def parse_note_metadata(raw)
      return nil if raw.nil?

      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end
  end
end
