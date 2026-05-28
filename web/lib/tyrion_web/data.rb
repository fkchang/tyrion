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

      root = Tyrion::Repo.tyrion_root(Dir.pwd)
      if root
        slug = Tyrion::Repo.active_project(root)
        return store.find_project_by_slug(slug) if slug
      end
      store.list_projects.first
    end

    def self.resolve_active_epic(project)
      return nil unless project
      root = Tyrion::Repo.tyrion_root(Dir.pwd)
      if root
        epic_slug = Tyrion::Repo.active_epic(root)
        if epic_slug
          epic = store.find_epic(project['id'], epic_slug)
          return epic if epic
        end
      end
      store.list_epics(project['id']).find { |e| e['status'] == 'active' }
    end

    def self.load_active_story_view(project_slug: nil)
      project = project_slug ? store.find_project_by_slug(project_slug) : resolve_active_project
      epic    = project ? resolve_active_epic(project) : nil
      story   = epic ? store.in_progress_story(epic['id']) : nil

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

    def self.load_roadmap_view(project_slug: nil)
      project = project_slug ? store.find_project_by_slug(project_slug) : resolve_active_project
      return { project: nil, epics: [], active_epic: nil, active_story: nil, stories: [], criteria: [] } unless project

      epics       = store.list_epics(project['id'])
      root        = Tyrion::Repo.tyrion_root(Dir.pwd)
      active_epic_slug = root ? Tyrion::Repo.active_epic(root) : nil
      active_epic = active_epic_slug ? epics.find { |e| e['slug'] == active_epic_slug } : epics.find { |e| e['status'] == 'active' }
      active_story = active_epic ? store.in_progress_story(active_epic['id']) : nil
      stories     = active_epic ? store.stories_for_epic(active_epic['id']) : []
      criteria    = active_story ? store.criteria_for_story(active_story['id']) : []

      {
        project: project, epics: epics, active_epic: active_epic,
        active_story: active_story, stories: stories, criteria: criteria
      }
    end

    def self.load_global_view
      projects = store.list_projects
      in_progress = []
      done_today  = []
      today_start = Time.now.strftime('%Y-%m-%d')

      projects.each do |proj|
        store.list_epics(proj['id']).each do |epic|
          story = store.in_progress_story(epic['id'])
          if story
            criteria = store.criteria_for_story(story['id'])
            in_progress << { project: proj, epic: epic, story: story, criteria: criteria }
          end

          store.stories_for_epic(epic['id']).each do |s|
            next unless s['status'] == 'done'
            next unless s['completed_at']&.start_with?(today_start)
            done_today << { project: proj, epic: epic, story: s }
          end
        end
      end

      # Attention rail items: stale stories + blocked notes
      attention = []
      in_progress.each do |item|
        s = item[:story]
        if TyrionWeb::Presenter.stale?(s['last_note_at'])
          attention << { type: :stale, story: s, label: "⚡ #{s['slug']} — #{TyrionWeb::Presenter.stale_label(s['last_note_at'])}" }
        end
      end

      { in_progress: in_progress, done_today: done_today, attention: attention }
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

    def self.safe_git_branch
      Tyrion::Repo.git_branch(Dir.pwd)
    rescue
      'unknown'
    end

    def self.safe_dirty_count
      Tyrion::Repo.dirty_count(Dir.pwd)
    rescue
      0
    end
  end
end
