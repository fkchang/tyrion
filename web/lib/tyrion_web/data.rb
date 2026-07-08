# frozen_string_literal: true

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
      base = project['primary_repo_identity'] || repo_root
      root = Tyrion::Repo.tyrion_root(base)
      if root
        epic_slug = Tyrion::Repo.active_epic(root)
        if epic_slug
          epic = store.find_epic(project['id'], epic_slug)
          return epic if epic
        end
      end
      store.list_epics(project['id']).find { |e| e['status'] == 'active' }
    end

    def self.repo_root
      ENV['TYRION_REPO_ROOT']&.then { |r| r.strip.empty? ? nil : r } || Dir.pwd
    end

    def self.load_active_story_view(project_slug: nil)
      project = project_slug ? store.find_project_by_slug(project_slug) : resolve_active_project
      epic    = project ? resolve_active_epic(project) : nil
      story   = epic ? store.in_progress_story(epic['id']) : nil

      # Fall back to searching all epics if active epic has no in_progress story
      if project && story.nil?
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
        git_branch: git_branch, dirty_count: dirty_count
      }
    end

    def self.load_story_view(story_id:)
      story = store.find_story_by_id(story_id.to_s)
      return { story: nil, project: nil, epic: nil, criteria: [], notes: [], stories: [], disc_summary: empty_disc_summary, git_branch: 'unknown', dirty_count: 0 } unless story

      epic    = store.find_epic_by_id(story['epic_id'])
      project = epic ? store.find_project_by_id(epic['project_id']) : nil

      {
        project: project, epic: epic, story: story,
        criteria: store.criteria_for_story(story['id']),
        notes:    store.notes_for_story(story['id'], limit: 10),
        stories:  epic ? store.stories_for_epic(epic['id']) : [],
        disc_summary: project ? load_discovery_summary(project['id']) : empty_disc_summary,
        git_branch:  safe_git_branch,
        dirty_count: safe_dirty_count
      }
    end

    def self.load_roadmap_view(project_slug: nil)
      project = project_slug ? store.find_project_by_slug(project_slug) : resolve_active_project
      return { project: nil, active_epics: [], archived_epics: [], active_epic: nil, active_story: nil, stories_by_epic: {}, criteria: [] } unless project

      epics        = store.list_epics(project['id'])
      active_epic  = resolve_active_epic(project)
      active_story = active_epic ? store.in_progress_story(active_epic['id']) : nil
      criteria     = active_story ? store.criteria_for_story(active_story['id']) : []

      stories_by_epic = {}
      decorated_epics = epics.map do |e|
        stories = store.stories_for_epic(e['id'])
        stories_by_epic[e['id']] = stories
        e.merge('story_stats' => story_counts(stories), 'max_last_note_at' => max_note_at(stories))
      end

      active_epics   = decorated_epics.reject { |e| e['archived_at'] }
      archived_epics = decorated_epics.select { |e| e['archived_at'] }

      {
        project: project, active_epics: active_epics, archived_epics: archived_epics,
        active_epic: active_epic, active_story: active_story,
        stories_by_epic: stories_by_epic, criteria: criteria
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
      marks          = store.list_discoveries(project_id: project['id'], status: 'mark')

      { project: project, spike: spike, findings_ready: findings_ready, marks: marks }
    end

    def self.load_war_room_view(project_slug: nil)
      project = project_slug ? store.find_project_by_slug(project_slug) : resolve_active_project
      return { project: nil, queue: [], active: [], blocked: [], done: [] } unless project

      queue = []; active_stories = []; blocked = []; done = []
      store.list_epics(project['id']).each do |epic|
        store.stories_for_epic(epic['id']).each do |s|
          decorated = s.merge('epic_slug' => epic['slug'])
          case s['status']
          when 'pending'     then queue << decorated
          when 'in_progress' then active_stories << decorated
          when 'blocked'     then blocked << decorated
          when 'done'        then done << decorated
          end
        end
      end

      {
        project: project,
        queue: queue,
        active: active_stories,
        blocked: blocked,
        done: done.last(8)
      }
    end

    def self.load_sidebar_data(project, epic)
      return { stories: [], disc_summary: empty_disc_summary } unless project && epic
      stories = store.stories_for_epic(epic['id'])
      disc_summary = load_discovery_summary(project['id'])
      { stories: stories, disc_summary: disc_summary }
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
