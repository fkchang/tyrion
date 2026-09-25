# frozen_string_literal: true

require 'digest'
require 'tyrion'

module TyrionWeb
  module Data
    def self.store
      @store ||= Tyrion::Store.new
    end

    def self.resolve_active_project
      slug = ENV['TYRION_PROJECT']&.strip
      return store.find_project_by_slug(slug) if slug && !slug.empty?

      root = Tyrion::Repo.tyrion_root(repo_root)
      if root
        slug = Tyrion::Repo.active_project(root)
        return store.find_project_by_slug(slug) if slug
      end
      store.list_projects.first
    end

    def self.resolve_active_epic(project)
      return nil unless project
      epic_slug = cli_active_epic_slug(project)
      if epic_slug
        epic = store.find_epic(project['id'], epic_slug)
        return epic if epic
      end
      store.list_epics(project['id']).find { |e| e['status'] == 'active' }
    end

    def self.repo_root
      ENV['TYRION_REPO_ROOT']&.then { |r| r.strip.empty? ? nil : r } || Dir.pwd
    end

    def self.load_active_story_view(project_slug: nil, epic_slug: nil)
      project = project_slug ? store.find_project_by_slug(project_slug) : resolve_active_project

      # Explicit ?epic= scope: pin to that exact epic and do NOT fall back to
      # searching other epics. This is what keeps a tab scoped to its own epic
      # instead of jumping to another epic's active story (multitab-url-scoping).
      epic  = project ? (epic_slug ? store.find_epic(project['id'], epic_slug) : resolve_active_epic(project)) : nil
      story = epic ? store.in_progress_story(epic['id']) : nil

      # Fall back to searching all epics if active epic has no in_progress story
      # (only when no explicit epic_slug was given — an explicit scope stays pinned)
      if !epic_slug && project && story.nil?
        store.list_epics(project['id']).each do |e|
          found = store.in_progress_story(e['id'])
          if found
            story = found
            epic  = e
            break
          end
        end
      end

      criteria = story ? store.criteria_for_story(story['id']) : []
      notes    = story ? store.notes_for_story(story['id'], limit: 5) : []
      stories  = epic  ? store.stories_for_epic(epic['id']) : []
      disc_summary = project ? load_discovery_summary(project['id']) : empty_disc_summary

      git_branch  = safe_git_branch
      dirty_count = safe_dirty_count

      {
        project: project, epic: epic, story: story,
        criteria: criteria, notes: notes, stories: stories,
        disc_summary: disc_summary,
        epic_switcher: epic_switcher_epics(project),
        git_branch: git_branch, dirty_count: dirty_count
      }
    end

    def self.load_story_view(story_id:)
      story = store.find_story_by_id(story_id.to_s)
      return { story: nil, project: nil, epic: nil, criteria: [], notes: [], stories: [], disc_summary: empty_disc_summary, epic_switcher: [], git_branch: 'unknown', dirty_count: 0 } unless story

      epic    = store.find_epic_by_id(story['epic_id'])
      project = epic ? store.find_project_by_id(epic['project_id']) : nil

      {
        project: project, epic: epic, story: story,
        criteria: store.criteria_for_story(story['id']),
        notes:    store.notes_for_story(story['id'], limit: 10),
        stories:  epic ? store.stories_for_epic(epic['id']) : [],
        disc_summary: project ? load_discovery_summary(project['id']) : empty_disc_summary,
        epic_switcher: epic_switcher_epics(project),
        git_branch:  safe_git_branch,
        dirty_count: safe_dirty_count
      }
    end

    EMPTY_EPIC_GRAPH = { epics: {}, by_slug: {}, children: {}, depends_on: {}, story_counts: {} }.freeze

    def self.load_roadmap_view(project_slug: nil)
      project = project_slug ? store.find_project_by_slug(project_slug) : resolve_active_project
      unless project
        return { project: nil, active_epics: [], archived_epics: [], active_epic: nil, active_story: nil,
                 stories_by_epic: {}, criteria: [], graph: EMPTY_EPIC_GRAPH }
      end

      epics        = store.list_epics(project['id'])
      active_epic  = resolve_active_epic(project)
      active_story = active_epic ? store.in_progress_story(active_epic['id']) : nil
      criteria     = active_story ? store.criteria_for_story(active_story['id']) : []
      graph        = store.epic_graph(project['id'])

      stories_by_epic = {}
      decorated_epics = epics.map do |e|
        stories = store.stories_for_epic(e['id'])
        stories_by_epic[e['id']] = stories
        e.merge(
          'story_stats'      => story_counts(stories),
          'max_last_note_at' => max_note_at(stories),
          'unmet'            => store.unmet_prereqs(e, graph),
          'child_stats'      => store.epic_seal_stats(e['id'], graph)
        )
      end

      active_epics   = decorated_epics.reject { |e| e['archived_at'] }
      archived_epics = decorated_epics.select { |e| e['archived_at'] }

      {
        project: project, active_epics: active_epics, archived_epics: archived_epics,
        active_epic: active_epic, active_story: active_story,
        stories_by_epic: stories_by_epic, criteria: criteria, graph: graph
      }
    end

    # fleet-visibility/global-view-activity-sort: activity and lane state now
    # come from Liveness::Snapshot.current instead of the per-epic max_note_at
    # fan-out this replaced. project_activity is read off the snapshot
    # (snapshot['project_activity']), not queried a second time -- Snapshot
    # already ran that four-subquery read once per build, and calling
    # Store#project_activity again here would let this card's activity_at
    # (fresh) and its worst_lane_state (as old as the snapshot's TTL) describe
    # two different moments. Everything else about the card (counts,
    # disc_summary, card_status) is untouched.
    def self.load_global_view
      projects = store.list_projects
      snapshot = Tyrion::Liveness::Snapshot.current(store)
      activity = snapshot['project_activity']
      lanes_by_project = snapshot['rows'].select { |r| r['status'] == 'in_progress' }
                                          .group_by { |r| r['project_id'] }

      project_cards = projects.map do |proj|
        epics = store.list_epics(proj['id'])
        active_epic = resolve_active_epic(proj)

        done_count = pending_count = blocked_count = active_count = 0

        epics.each do |e|
          stories = store.stories_for_epic(e['id'])
          counts  = story_counts(stories)
          done_count    += counts[:done]
          pending_count += counts[:pending]
          blocked_count += counts[:blocked]
          active_count  += counts[:in_progress]
        end

        in_progress = active_epic ? store.in_progress_story(active_epic['id']) : nil
        total = done_count + pending_count + blocked_count + active_count
        disc_summary = load_discovery_summary(proj['id'])

        # activity_at unions stories.updated_at/last_note_at, criteria.checked_at
        # and discoveries activity (Store#project_activity) -- a real event time,
        # falling back to projects.updated_at (row touch time) only when nil,
        # per the design's stated sort key.
        activity_row = activity[proj['id']] || {}
        activity_at  = activity_row['activity_at'] # already NULLIF'd to NULL in SQL, never ''
        sort_key     = activity_at || proj['updated_at']

        # display_state, not the raw ladder state -- LANE_STATE_RANK ranks
        # "stalled?" (evidence: ledger only) at the same weight as "stalled",
        # so this loses no ordering precision while letting the glyph render
        # the uncertainty marker when that's the row actually driving it.
        lanes = lanes_by_project[proj['id']] || []
        worst_lane_state = TyrionWeb::Presenter.worst_lane_state(lanes.map { |r| r['display_state'] })

        # Precedence is load-bearing: story activity of any kind outranks discovery
        # activity, so :discovery only fires for a project with zero stories at all
        # (the spike-only case that used to misreport as :idle). A project with
        # pending stories AND open marks still reads :idle — the story lane stays
        # the honest headline, and the discovery strip already carries the rest.
        card_status = if active_count.positive?
          in_progress && TyrionWeb::Presenter.stale?(in_progress['last_note_at']) ? :stale : :active
        elsif total.positive? && done_count == total
          :done
        elsif total.zero? && TyrionWeb::Presenter.discovery_activity?(disc_summary)
          :discovery
        else
          :idle
        end

        {
          project: proj, active_epic: active_epic, in_progress: in_progress,
          done: done_count, pending: pending_count, blocked: blocked_count, active: active_count,
          total: total, last_note_at: activity_at, status: card_status, disc_summary: disc_summary,
          activity_at: activity_at, sort_key: sort_key,
          worst_lane_state: worst_lane_state, lane_count: lanes.size
        }
      end

      # Descending by real activity; a nil sort_key (no activity ever, no
      # project row touch either) sorts last rather than first.
      sorted = project_cards.sort_by { |c| c[:sort_key] || '' }.reverse

      { project_cards: sorted }
    end

    # Fingerprint for GET /api/global_poll. Every element is a stored value --
    # an id, a bucket, a count, or an event timestamp -- never a wall-clock-
    # derived age, so the token changes only when something actually changed,
    # in the page's own sort order (a re-sort is itself a change worth seeing).
    def self.global_poll_token(project_cards)
      fingerprint = project_cards.map do |c|
        [c[:project]['slug'], c[:status], c[:worst_lane_state], c[:done], c[:total], c[:activity_at]]
      end
      Digest::SHA256.hexdigest(fingerprint.to_s)[0, 16]
    end

    # fleet-visibility/fleet-board: cross-project board, one row per
    # in-progress story grouped by project. Reads Liveness::Snapshot.current
    # exclusively -- no per-row queries, no git calls from this layer.
    def self.load_fleet_view
      snapshot  = Tyrion::Liveness::Snapshot.current(store)
      activity  = snapshot['project_activity']
      projects  = store.list_projects

      # Rows, not the blocked stories the same snapshot also carries -- the
      # fleet board's row unit is "one row per in-progress story" (blocked
      # stories still surface via the attention band below, which the
      # snapshot already derives from the same underlying rows).
      in_progress_rows = snapshot['rows'].select { |r| r['status'] == 'in_progress' }
      by_project = in_progress_rows.group_by { |r| r['project_id'] }

      grouped = projects.filter_map do |proj|
        prows = by_project[proj['id']]
        next nil if prows.nil? || prows.empty?

        # Attention weight then newest_at descending, per the design's own
        # words -- attention weight IS Tyrion::Liveness::SEVERITY, the same
        # table attention_items sorts by, not a second ranking table.
        sorted = prows.sort_by { |r| [TyrionWeb::Presenter.attention_weight(r['state']), -(r['newest_at'] || 0)] }
        { project: proj, rows: sorted }
      end
      # Groups themselves sort worst-first too ("everything waiting on me on
      # one screen, worst first") -- a project holding a dead lane must not
      # render below three quiet ones just because store.list_projects said so.
      grouped.sort_by! { |g| g[:rows].map { |r| TyrionWeb::Presenter.attention_weight(r['state']) }.min }

      idle_projects = projects.reject { |proj| by_project.key?(proj['id']) }.map do |proj|
        act = activity[proj['id']] || {}
        { project: proj, last_activity_at: Tyrion::Liveness.epoch(act['activity_at'] || proj['updated_at']) }
      end

      {
        projects: grouped,
        idle_projects: idle_projects,
        attention: snapshot['attention'],
        live_count: in_progress_rows.count { |r| r['state'] == 'live' },
        generation: snapshot['generation'],
        built_at: snapshot['built_at'],
        stale: snapshot['stale'],
        partial: snapshot['partial']
      }
    end

    # Shared by fleet_poll_token and cockpit_poll_token ("the fleet token
    # restricted to the epic" is the cockpit design's own words for reusing
    # this exact fingerprint over a smaller row set) -- one place to remember
    # when a field LaneRow renders needs to be added to the token.
    def self.lane_row_fingerprint(rows)
      rows.map do |r|
        [
          r['story_id'], r['status'], r['claimed_by'], r['met'], r['total'],
          r['display_state'], r['resolution_state'],
          r['signals']['note'], r['signals']['criterion'], r['signals']['gate'], r['signals']['commit'],
          r['signals']['edit'], r['signals']['process'],
          r['commit_sha'], r['dirty_count'], r['newest_dirty_mtime']
        ]
      end
    end

    def self.attention_fingerprint(items)
      items.map { |a| [a['story_id'], a['kind']] }
    end

    # Fingerprint for GET /api/fleet_poll: per-story identity/status/liveness/
    # resolution plus every newest-per-source event timestamp the row
    # displays, the newest commit sha, dirty count and newest dirty-file
    # mtime (an epoch integer -- a file timestamp, not a rendered age), and
    # each attention item's story_id + kind. No rendered age anywhere in it;
    # ages tick client-side from data-at between reloads.
    def self.fleet_poll_token(fleet_view)
      row_fp = lane_row_fingerprint(fleet_view[:projects].flat_map { |g| g[:rows] })
      attention_fp = attention_fingerprint(fleet_view[:attention])
      idle_fp = fleet_view[:idle_projects].map { |ip| [ip[:project]['slug'], ip[:last_activity_at]] }

      Digest::SHA256.hexdigest([row_fp, attention_fp, idle_fp].to_s)[0, 16]
    end

    # "Needs your attention": one pure fold (Tyrion::Attention) over every
    # project's active/paused epics, plus the same Liveness::Snapshot the
    # fleet board reads for lane pid/liveness/worktree info. Never computed
    # twice -- `tyrion attention --json` and this view call the identical
    # Attention.build over the identical gather.
    def self.load_attention_view(stale_days: Tyrion::Attention::DEFAULT_STALE_DAYS, project_slug: nil)
      gathered = Tyrion::Attention.gather(store)
      snapshot = Tyrion::Liveness::Snapshot.current(store)
      Tyrion::Attention.build(gathered, snapshot_rows: snapshot['rows'], stale_days: stale_days, project_slug: project_slug)
    end

    # Fingerprint for GET /api/attention_poll. Every element is a value the
    # page actually renders -- never a rendered age -- so the token changes
    # only when the fold's own output would look different.
    def self.attention_poll_token(report)
      fingerprint = report['epics'].map do |e|
        [e['project_slug'], e['epic_slug'], e['category'], e['counts'], e['idle_days'],
         e['waiting_reasons'], e['current_story'], e['lanes']]
      end
      Digest::SHA256.hexdigest([report['stale_days'], fingerprint].to_s)[0, 16]
    end

    COCKPIT_TABS = %w[now changes trail].freeze

    def self.normalize_cockpit_tab(tab)
      COCKPIT_TABS.include?(tab.to_s) ? tab.to_s : 'now'
    end

    EMPTY_STORY_COUNTS = { done: 0, in_progress: 0, blocked: 0, pending: 0, total: 0 }.freeze

    # fleet-visibility/cockpit-now-tab + cockpit-changes-trail-tabs: one
    # epic's slice of the same Liveness::Snapshot the fleet board reads, plus
    # the Changes feed's merged events and (only when the Trail tab actually
    # needs it) the full uncapped note timeline. project_slug/epic_slug are
    # the string params straight off the URL; a nil epic (unknown slug, or no
    # project to resolve it against) is the caller's 404 signal -- this
    # method never raises for that, it just returns nothing to render.
    def self.load_cockpit_view(project_slug: nil, epic_slug: nil, tab: 'now')
      project = project_slug ? store.find_project_by_slug(project_slug) : resolve_active_project
      epic    = project && epic_slug ? store.find_epic(project['id'], epic_slug) : nil
      tab     = normalize_cockpit_tab(tab)

      unless project && epic
        return {
          project: project, epic: nil, tab: tab, rows: [], attention: [], story_counts: EMPTY_STORY_COUNTS,
          events: [], trail_notes: [], stories: [], disc_summary: empty_disc_summary, epic_switcher: [],
          generation: nil, built_at: nil, stale: false, partial: false
        }
      end

      snapshot = Tyrion::Liveness::Snapshot.current(store)
      observe_dead_lanes(snapshot['rows'])

      in_epic = ->(r) { r['project_slug'] == project['slug'] && r['epic_slug'] == epic['slug'] }
      rows      = snapshot['rows'].select { |r| in_epic.call(r) && r['status'] == 'in_progress' }
      attention = snapshot['attention'].select { |a| a['project_slug'] == project['slug'] && a['epic_slug'] == epic['slug'] }
      dead_events = dead_lane_events_for(project['slug'], epic['slug'])

      events = (Tyrion::Liveness.epic_events(store, epic['id']) + dead_events)
               .sort_by { |e| -(e[:at] || 0) }.first(Tyrion::Liveness::EVENT_FEED_LIMIT)

      # -1 is SQLite's own "no LIMIT" sentinel (epic_notes_recent's own doc
      # comment) -- Trail wants the complete timeline, only fetched when the
      # Trail tab is actually the one being rendered.
      trail_notes = tab == 'trail' ? store.epic_notes_recent(epic['id'], limit: -1) : []

      base = load_sidebar_data(project, epic)

      {
        project: project, epic: epic, tab: tab,
        rows: rows, attention: attention, story_counts: story_counts(store.stories_for_epic(epic['id'])),
        events: events, trail_notes: trail_notes,
        stories: base[:stories], disc_summary: base[:disc_summary], epic_switcher: base[:epic_switcher],
        generation: snapshot['generation'], built_at: snapshot['built_at'],
        stale: snapshot['stale'], partial: snapshot['partial']
      }
    end

    # Fingerprint for GET /api/cockpit_poll: "the fleet token restricted to
    # the epic" (design's own words) -- the same row/attention fields
    # fleet_poll_token fingerprints, but only for this epic's rows/attention
    # -- plus the newest Changes event (kind+at+story_id, so a new event of an
    # already-seen kind still changes it) and the epic's status counts.
    def self.cockpit_poll_token(view)
      row_fp = lane_row_fingerprint(view[:rows])
      attention_fp = attention_fingerprint(view[:attention])
      newest = view[:events]&.first
      newest_fp = newest && [newest[:kind], newest[:at], newest[:story_id] || newest[:story_slug]]
      counts_fp = view[:story_counts]&.values_at(:done, :in_progress, :blocked, :pending, :total)

      Digest::SHA256.hexdigest([row_fp, attention_fp, newest_fp, counts_fp].to_s)[0, 16]
    end

    # In-memory only: the "lane dead" Changes event (fleet-visibility/cockpit-
    # changes-trail-tabs) has no persisted event log to read from -- it is a
    # transition THIS process observed between two Liveness::Snapshot builds.
    # @dead_lane_known/@dead_lane_events are plain module ivars, not the DB:
    # restarting the web process forgets every prior observation (a lane
    # still dead after a restart is simply re-observed on the next request),
    # which the design calls out as acceptable. Idempotent by construction --
    # calling this twice with an unchanged snapshot's rows records nothing
    # new the second time, since @dead_lane_known already reflects the first
    # call -- so it's safe to call on every /cockpit render and every poll
    # regardless of how often the snapshot itself actually rebuilt.
    #
    # Guarded by its own Mutex -- the same precedent Liveness::Snapshot sets
    # right next to this (a private class-level Mutex around its build) --
    # because Puma serves this web app with more than one thread, and an
    # unguarded check-then-act ("was this story already known dead?") could
    # let two overlapping requests each see "not yet dead" and both record
    # the same transition.
    DEAD_LANE_MUTEX = Mutex.new
    private_constant :DEAD_LANE_MUTEX

    def self.observe_dead_lanes(rows)
      DEAD_LANE_MUTEX.synchronize do
        @dead_lane_known  ||= {}
        @dead_lane_events ||= []
        Array(rows).each do |row|
          story_id = row['story_id']
          was_dead = @dead_lane_known[story_id] == Tyrion::Liveness::DEAD
          is_dead  = row['state'] == Tyrion::Liveness::DEAD
          if is_dead && !was_dead
            @dead_lane_events << {
              kind: 'lane_dead', at: Time.now.to_i, story_id: story_id, story_slug: row['slug'],
              epic_slug: row['epic_slug'], project_slug: row['project_slug']
            }
          end
          # Not pruned like @dead_lane_events below -- every story ID this
          # process has ever seen stays a key for the process's lifetime.
          # Harmless at Tyrion's scale (one entry per story ever in progress),
          # so a real cap isn't worth the complexity, but it's the one
          # unbounded structure here and worth naming as such.
          @dead_lane_known[story_id] = row['state']
        end
        @dead_lane_events = @dead_lane_events.last(200)
      end
    end

    # A snapshot of the observed lane_dead events, filtered to one project +
    # epic -- reading @dead_lane_events through the same mutex observe_dead_
    # lanes writes it under, so a caller never sees a half-appended array.
    def self.dead_lane_events_for(project_slug, epic_slug)
      DEAD_LANE_MUTEX.synchronize do
        Array(@dead_lane_events).select { |e| e[:project_slug] == project_slug && e[:epic_slug] == epic_slug }
      end
    end

    # Specs only -- nothing in the running system has a reason to forget an
    # observation deliberately (mirrors Liveness::Snapshot.reset!).
    def self.reset_dead_lane_observations!
      DEAD_LANE_MUTEX.synchronize do
        @dead_lane_known  = {}
        @dead_lane_events = []
      end
    end

    def self.load_discoveries_view(project_slug: nil)
      project = project_slug ? store.find_project_by_slug(project_slug) : resolve_active_project
      return { project: nil, spike: nil, findings_ready: [], marks: [] } unless project

      spike          = store.active_spike_for(project['id'])
      findings_ready = store.list_discoveries(project_id: project['id'], status: 'findings_ready')
      # A mark filed under an active_spike (parent_spike_id set) is shown nested
      # under that spike's own show page instead -- excluded here so it isn't
      # listed twice.
      marks          = store.list_discoveries(project_id: project['id'], status: 'mark')
                             .reject { |m| m['parent_spike_id'] }

      { project: project, spike: spike, findings_ready: findings_ready, marks: marks }
    end

    # Aging thresholds — the single source both the token (discoveries_token,
    # below) and Views::DiscoveriesView's badge rendering (render_ready_section
    # / render_marks_section) call through .aged? for, so the "⚠ aging" badge
    # and the fingerprint that decides whether to reload can never disagree
    # about which side of the threshold a row is on.
    READY_AGING_DAYS = 3
    MARK_AGING_DAYS  = 14

    def self.aged?(created_at, days)
      return false unless created_at

      (Time.now - Time.parse(created_at.to_s)) / 86_400.0 >= days
    rescue ArgumentError
      false
    end

    # Discoveries index poll token — reload-on-change (active_story.rb's /api/poll
    # pattern), not ambient's DOM-patch: this is a full list page, not a narrow
    # glance pane someone is mid-read in, so a reload costs nothing. Fingerprints
    # every field the page renders: the spike (id/question/hypothesis/exit_criteria
    # — all editable mid-flight), every findings_ready/mark id + glance-relevant
    # content, and each row's aged? boolean — a new mark, a spike closing (spike
    # disappears, a findings_ready row appears), an edited finding, or a row
    # crossing its aging threshold on a tab left open all day all change the
    # fingerprint. Booleans, not raw created_at/wall-clock time: that would churn
    # the token every tick the way ambient_token's comment warns against — a
    # threshold crossing flips the boolean exactly once.
    def self.discoveries_token(spike:, findings_ready:, marks:)
      fingerprint = [
        spike && [spike['id'], spike['question'], spike['hypothesis'], spike['exit_criteria']],
        findings_ready.map { |d| [d['id'], d['headline'], d['question'], d['finding'], d['confidence'], d['recommendation'], aged?(d['created_at'], READY_AGING_DAYS)] },
        marks.map { |d| [d['id'], d['headline'], d['question'], aged?(d['created_at'], MARK_AGING_DAYS)] }
      ]
      Digest::SHA256.hexdigest(fingerprint.to_s)[0, 16]
    end

    # Ambient pane data — deliberately just the newest open marks plus a
    # findings_ready count. Unlike the other loaders, an unknown ?project=
    # slug falls back to the resolved active project instead of rendering an
    # empty page: the ambient pane is glance-only, so a stale bookmarked slug
    # should still show something true rather than a blank surface.
    def self.load_ambient_view(project_slug: nil, mark_limit: 10)
      slug    = project_slug&.strip&.then { |s| s.empty? ? nil : s }
      project = (slug && store.find_project_by_slug(slug)) || resolve_active_project
      return { project: nil, marks: [], findings_ready_count: 0 } unless project

      marks = store.list_discoveries(project_id: project['id'], status: 'mark')
                   .sort_by { |d| [d['created_at'].to_s, d['id'].to_s] }.reverse.first(mark_limit)

      {
        project: project,
        marks: marks,
        findings_ready_count: store.list_discoveries(project_id: project['id'], status: 'findings_ready').size
      }
    end

    # Ambient poll token — deliberately derived ONLY from the marks' ids,
    # glance text (headline/question), and the findings_ready count. Aging is
    # a pure function of created_at and wall-clock time, so folding it in here
    # would make the token churn on every tick; the pane recomputes aging
    # client-side instead. Headline is included so `tyrion discovery headline`
    # sharpening an existing mark's text (no new mark, no status change)
    # still triggers a repaint.
    def self.ambient_token(marks:, findings_ready_count:)
      fingerprint = marks.map { |m| [m['id'], m['headline'], m['question']] } << findings_ready_count.to_i
      Digest::SHA256.hexdigest(fingerprint.to_s)[0, 16]
    end

    # Everything the ambient pane needs to repaint BOTH sections — never just the
    # token. Same shape whether or not a project resolved, so the 404 empty-state
    # body is something the page can render rather than an error it can't.
    def self.ambient_poll_payload(view)
      marks = view[:marks]
      count = view[:findings_ready_count].to_i

      {
        token: ambient_token(marks: marks, findings_ready_count: count),
        # headline/question separate (not just the merged `text`) so the
        # inline-expanded state can show both — the compact glance text alone
        # isn't enough once you're looking at more than the headline.
        marks: marks.map { |m| { id: m['id'], text: Tyrion::Output.discovery_glance_text(m),
                                  headline: m['headline'], question: m['question'], created_at: m['created_at'] } },
        findings_ready_count: count
      }
    end

    # The dedicated per-discovery page (design: 2026-08-18 discovery glance/detail spec).
    # epics: the promote-to-story epic picker's source — Store#promote_discovery_to_story
    # requires a real epic_id with no safe default (the CLI gets one from
    # .tyrion/active-epic, a lane concept with no web equivalent), so the form always
    # needs a real list to choose from.
    def self.load_discovery_show_view(disc_id)
      disc = store.find_discovery(disc_id)
      return { discovery: nil, project: nil, epic: nil, epics: [], stories: [], disc_summary: empty_disc_summary, epic_switcher: [], child_marks: [], git_branch: 'unknown', dirty_count: 0 } unless disc

      project = store.find_project_by_id(disc['project_id'])
      # The discovery's TRUE epic (possibly nil, e.g. filed via `tyrion spike
      # start`, which doesn't set epic_id) -- what the page's own content
      # ("Epic: none -- filed as a standalone observation") must report
      # accurately. sidebar_epic is different on purpose: it falls back to the
      # resolved active epic (same fallback /about and the 404 view use) so
      # Layout's sidebar has something to show instead of its "No active
      # project" empty state, which is really "no epic," not "no project" --
      # conflating the two would make the page falsely claim ownership of
      # whatever epic happens to be active.
      epic         = disc['epic_id'] && store.find_epic_by_id(disc['epic_id'])
      sidebar_epic = epic || resolve_active_epic(project)

      # Marks filed under this discovery while it was the project's active_spike
      # (parent_spike_id == disc['id']) -- shown nested here instead of on the
      # flat /discoveries index (load_discoveries_view excludes them for the
      # same reason). Scoped to status='mark' to mirror exactly what got
      # excluded there; a mark that has since moved on (promoted, deferred)
      # keeps its own show page rather than reappearing nested on this one.
      child_marks = project ? store.list_discoveries(project_id: project['id'], status: 'mark')
                                    .select { |m| m['parent_spike_id'] == disc['id'] } : []

      {
        discovery: disc, project: project, epic: epic, sidebar_epic: sidebar_epic,
        epics: project ? store.list_epics(project['id']) : [],
        stories: sidebar_epic ? store.stories_for_epic(sidebar_epic['id']) : [],
        disc_summary: project ? load_discovery_summary(project['id']) : empty_disc_summary,
        epic_switcher: epic_switcher_epics(project),
        child_marks: child_marks,
        git_branch:  safe_git_branch,
        dirty_count: safe_dirty_count
      }
    end

    def self.load_war_room_view(project_slug: nil, epic_slug: nil)
      project = project_slug ? store.find_project_by_slug(project_slug) : resolve_active_project
      return { project: nil, epic: nil, queue: [], active: [], active_count: 0, blocked: [], done: [] } unless project

      # No explicit ?epic= scope: preserve the cross-epic "no lane hidden" view
      # (the whole point of the live-lanes-board feature). An explicit but
      # unknown epic_slug returns an empty board rather than silently falling
      # back to the cross-epic view — a bad slug should read as "not found,"
      # not "show everything."
      if epic_slug
        epic = store.find_epic(project['id'], epic_slug)
        return { project: project, epic: nil, queue: [], active: [], active_count: 0, blocked: [], done: [] } unless epic

        epics_to_scan = [epic]
      else
        epic = nil
        epics_to_scan = store.list_epics(project['id'])
      end

      stories = epics_to_scan.flat_map do |e|
        store.stories_for_epic(e['id']).map { |s| s.merge('epic_slug' => e['slug']) }
      end.map { |s| s.merge(criteria_progress(s['id'])) }
      by_status = stories.group_by { |s| s['status'] }

      {
        project:      project,
        epic:         epic,
        queue:        by_status.fetch('pending', []),
        active:       by_status.fetch('in_progress', []),
        active_count: by_status.fetch('in_progress', []).size,
        blocked:      by_status.fetch('blocked', []),
        done:         by_status.fetch('done', []).last(8)
      }
    end

    # Acceptance-criteria progress for a story card (War Room). 'criteria_total'
    # zero means the story has no criteria — cards render no bar in that case.
    def self.criteria_progress(story_id)
      criteria = store.criteria_for_story(story_id)
      { 'criteria_met' => TyrionWeb::Presenter.criteria_met_count(criteria), 'criteria_total' => criteria.size }
    end

    def self.load_sidebar_data(project, epic)
      return { stories: [], disc_summary: empty_disc_summary, epic_switcher: [] } unless project
      stories = epic ? store.stories_for_epic(epic['id']) : []
      disc_summary = load_discovery_summary(project['id'])
      { stories: stories, disc_summary: disc_summary, epic_switcher: epic_switcher_epics(project) }
    end

    # Epics for the topbar epic-switcher dropdown: every epic in the project,
    # decorated with done/total story counts and whether it's the CLI's
    # .tyrion/active-epic pointer (the raw file value, not resolve_active_epic's
    # DB-status fallback) so the dropdown's ⚑ badge tracks the execution pointer
    # exactly, not just "some active epic."
    def self.epic_switcher_epics(project)
      return [] unless project

      cli_active_slug = cli_active_epic_slug(project)
      store.list_epics(project['id']).reject { |e| e['archived_at'] }.map do |e|
        counts = story_counts(store.stories_for_epic(e['id']))
        {
          'slug' => e['slug'],
          'done' => counts[:done],
          'total' => counts[:total],
          'cli_active' => e['slug'] == cli_active_slug
        }
      end
    end

    def self.cli_active_epic_slug(project)
      base = project['primary_repo_identity'] || repo_root
      root = Tyrion::Repo.tyrion_root(base)
      root ? Tyrion::Repo.active_epic(root) : nil
    end

    def self.load_discovery_summary(project_id)
      spike = store.active_spike_for(project_id)
      ready = store.list_discoveries(project_id: project_id, status: 'findings_ready')
      marks = store.list_discoveries(project_id: project_id, status: 'mark')
      { spike: spike, ready_count: ready.size, mark_count: marks.size }
    end

    def self.empty_disc_summary
      { spike: nil, ready_count: 0, mark_count: 0 }
    end

    def self.story_counts(stories)
      by_status = stories.group_by { |s| s['status'] }
      {
        done:        by_status.fetch('done', []).size,
        in_progress: by_status.fetch('in_progress', []).size,
        blocked:     by_status.fetch('blocked', []).size,
        pending:     by_status.fetch('pending', []).size,
        total:       stories.size
      }
    end

    def self.max_note_at(stories)
      stories.filter_map { |s| s['last_note_at'] }.max
    end

    def self.safe_git_branch
      project = resolve_active_project
      path = project&.dig('primary_repo_identity') || repo_root
      Tyrion::Repo.git_branch(path)
    rescue StandardError
      'unknown'
    end

    def self.safe_dirty_count
      project = resolve_active_project
      path = project&.dig('primary_repo_identity') || repo_root
      Tyrion::Repo.dirty_count(path)
    rescue StandardError
      0
    end
  end
end
