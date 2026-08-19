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

    def self.load_global_view
      projects = store.list_projects
      project_cards = projects.map do |proj|
        epics = store.list_epics(proj['id'])
        active_epic = resolve_active_epic(proj)

        done_count = pending_count = blocked_count = active_count = 0
        last_note_at = nil

        epics.each do |e|
          stories = store.stories_for_epic(e['id'])
          counts  = story_counts(stories)
          done_count    += counts[:done]
          pending_count += counts[:pending]
          blocked_count += counts[:blocked]
          active_count  += counts[:in_progress]
          last_note_at   = [last_note_at, max_note_at(stories)].compact.max
        end

        in_progress = active_epic ? store.in_progress_story(active_epic['id']) : nil
        total = done_count + pending_count + blocked_count + active_count

        card_status = if active_count > 0
          in_progress && TyrionWeb::Presenter.stale?(in_progress['last_note_at']) ? :stale : :active
        elsif total > 0 && pending_count == 0 && blocked_count == 0 && active_count == 0
          :done
        else
          :idle
        end

        {
          project: proj, active_epic: active_epic, in_progress: in_progress,
          done: done_count, pending: pending_count, blocked: blocked_count, active: active_count,
          total: total, last_note_at: last_note_at, status: card_status
        }
      end

      { project_cards: project_cards }
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
      return { stories: [], disc_summary: empty_disc_summary, epic_switcher: [] } unless project && epic
      stories = store.stories_for_epic(epic['id'])
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
