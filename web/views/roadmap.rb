# frozen_string_literal: true

module Views
  class RoadmapView < Phlex::HTML
    ATTENTION_WEIGHT = { ready: 1, blocked: 2, cold: 3, active: 4, paused: 5, started: 6, queued: 7, empty: 8, sealed: 9 }.freeze
    GAUGE_GLYPHS     = { ready: '✦', blocked: '✕', cold: '⚠', active: '●', paused: '‖', sealed: '✓' }.freeze

    def initialize(project:, active_epics:, archived_epics:, active_epic:, active_story:, stories_by_epic:, criteria:,
                   sidebar_stories:, disc_summary:, epic_switcher: [], git_branch: 'main', dirty_count: 0, project_slug: nil, flash: nil)
      @project        = project
      @active_epics   = active_epics
      @archived_epics = archived_epics
      @active_epic    = active_epic
      @active_story   = active_story
      @stories_by_epic = stories_by_epic
      @criteria       = criteria
      @sidebar_stories = sidebar_stories
      @disc_summary   = disc_summary
      @epic_switcher  = epic_switcher
      @git_branch     = git_branch
      @dirty_count    = dirty_count
      @project_slug   = project_slug
      @flash          = flash
    end

    def view_template
      render Views::Layout.new(project: @project, epic: @active_epic,
                                stories: @sidebar_stories, disc_summary: @disc_summary,
                                epic_switcher: @epic_switcher,
                                active_tab: :roadmap, git_branch: @git_branch, dirty_count: @dirty_count,
                                project_slug: @project_slug) do
        div(class: "main-content visible", id: "s-roadmap") do
          div(class: "rm-outer") do
            div(class: "rm-wrap") do
              section(class: "rm-ledger") do
                div(class: "rm-worn-edge")
                div(class: "rm-content") do
                  div(class: "rm-eyebrow") { "Campaign Ledger" }
                  h1(class: "rm-title") { @project ? @project['name'] : "No project" }
                  render_flash if @flash
                  div(class: "rm-ornament")

                  if @active_epics.any? || @archived_epics.any?
                    render_progress_header
                    sorted = sorted_active_epics
                    div(class: "rm-epic-list") do
                      sorted.each { |epic, state| render_epic(epic, state) }
                    end
                    render_archived_section if @archived_epics.any?
                  else
                    div(style: "font-size:15px;color:var(--ink-faint);font-style:italic;padding:20px 0;") { "No epics yet" }
                  end
                end
              end
            end
          end
        end
        render_js
      end
    end

    private

    def epic_state_for(epic)
      TyrionWeb::Presenter.epic_state(
        epic,
        @stories_by_epic[epic['id']] || [],
        @active_epic&.dig('id')
      )
    end

    def sorted_active_epics
      @active_epics
        .map     { |e| [e, epic_state_for(e)] }
        .sort_by { |_, st| ATTENTION_WEIGHT.fetch(st[:state]) }
    end

    def render_progress_header
      states    = @active_epics.map { |e| epic_state_for(e)[:state] }
      counts    = states.group_by(&:itself).transform_values(&:count)

      all_stories  = @active_epics.flat_map { |e| @stories_by_epic[e['id']] || [] }
      story_done   = all_stories.count { |s| s['status'] == 'done' }
      story_total  = all_stories.size

      div(class: "rm-progress-line") do
        div(class: "rm-gauge") do
          segments = ATTENTION_WEIGHT.keys.filter_map do |st|
            n = counts[st]
            next unless n && n > 0
            g = GAUGE_GLYPHS[st]
            [st, n, g]
          end
          segments.each_with_index do |(st, n, g), idx|
            span(class: "rm-gauge-sep") { " · " } if idx > 0
            span(class: "rm-gauge-item") do
              plain "#{n} #{st}"
              plain " #{g}" if g
            end
          end
        end
        span(class: "rm-story-rollup") { "#{story_done}/#{story_total} stories" }
      end
    end

    def render_epic(epic, state)
      stories  = @stories_by_epic[epic['id']] || []
      done_s   = stories.count { |s| s['status'] == 'done' }
      pct      = stories.size > 0 ? (done_s * 100.0 / stories.size).round : 0
      list_id  = "epic-stories-#{epic['id'].to_s.gsub('-', '_')}"
      is_sealed = state[:state] == :sealed
      is_empty  = state[:state] == :empty
      open      = state[:focus] && !is_sealed

      div(class: "rm-epic#{state[:focus] ? ' active' : ''}", data: { epic_id: epic['id'] }) do
        div(class: "rm-epic-header", data: { action: "toggle-epic", target: list_id },
            style: "cursor:pointer;") do
          div(class: state[:color_css]) { state[:glyph] }
          div(class: "rm-epic-name") do
            plain("★ ") if state[:focus]
            plain epic['slug']
          end
          div(class: "rm-epic-meta") do
            span(class: "rm-epic-state-label") { state[:label] }
            span(class: "rm-epic-stats") { "#{done_s}/#{stories.size}" } if stories.any?
          end
          if is_empty
            div(class: "rm-mini-track empty")
          else
            div(class: "rm-mini-track") do
              div(class: "rm-mini-fill", style: "width:#{pct}%")
            end
          end
          div(class: "rm-chev", data: { chev: list_id }) { open ? "⌃" : "⌄" }
        end

        render_action_buttons(epic, state, stories) if state[:action] || state[:archived]

        div(id: list_id, class: "rm-story-list-wrap", style: open ? "" : "display:none;") do
          render_story_list(stories, epic)
        end
      end
    end

    def render_archived_section
      details(class: "rm-archived-section") do
        summary(class: "rm-archived-summary") { "Archived (#{@archived_epics.size})" }
        div(class: "rm-epic-list rm-archived-list") do
          @archived_epics.each do |epic|
            render_epic(epic, epic_state_for(epic))
          end
        end
      end
    end

    def render_story_list(stories, epic)
      if stories.empty?
        div(style: "padding:8px 16px 12px;font-size:13px;color:var(--ink-faint);font-style:italic;") { "No stories yet" }
        return
      end

      div(class: "rm-story-list") do
        stories.each do |s|
          s_cls = case s['status']
                  when 'done'        then 'rm-story done'
                  when 'in_progress' then 'rm-story current'
                  when 'blocked'     then 'rm-story blocked'
                  else 'rm-story'
                  end
          glyph_color = case s['status']
                        when 'done'        then 'var(--emerald)'
                        when 'in_progress' then 'var(--amber)'
                        when 'blocked'     then 'var(--crimson)'
                        else 'var(--ink-muted)'
                        end
          glyph = case s['status']
                  when 'pending'  then '○'
                  when 'blocked'  then '✕'
                  else '●'
                  end

          a(class: s_cls, href: "/stories/#{s['id']}", style: "text-decoration:none;display:flex;align-items:center;gap:10px;") do
            span(class: s['status'] == 'in_progress' ? 's-icon-pulse' : '',
                 style: "color:#{glyph_color};flex-shrink:0;") { glyph }
            span(style: "flex:1;") { s['slug'] }
            if s['status'] == 'blocked' && s['blocked_on']
              span(style: "font-size:11px;color:#b91c1c;opacity:.8;font-style:italic;") { s['blocked_on']&.slice(0, 40) }
            end
          end
        end
      end
    end

    def render_flash
      css = @flash.start_with?("Error") ? "rm-flash-error" : "rm-flash-success"
      div(class: css) { plain @flash }
    end

    def render_action_buttons(epic, state, stories)
      div(class: "rm-epic-actions") do
        if state[:archived]
          form(method: "post", action: "/epic/#{epic['slug']}/unarchive", style: "display:inline;") do
            input(type: "hidden", name: "project", value: @project_slug) if @project_slug
            button(type: "submit", class: "rm-act-btn") { "[Unarchive]" }
          end
        else
          case state[:action]
          when :seal
            form(method: "post", action: "/epic/#{epic['slug']}/seal", style: "display:inline;") do
              input(type: "hidden", name: "project", value: @project_slug) if @project_slug
              button(type: "submit", class: "rm-act-btn primary") { "[Seal]" }
            end
          when :resume
            warroom_url = "/warroom#{@project_slug ? "?project=#{@project_slug}" : ""}"
            a(href: warroom_url, class: "rm-act-btn") { "[Resume]" }
          when :blocker
            blocked = stories.find { |s| s['status'] == 'blocked' }
            a(href: "/stories/#{blocked['id']}", class: "rm-act-btn") { "[blocker]" } if blocked
          when :import
            import_url = "/import?epic=#{epic['slug']}#{@project_slug ? "&project=#{@project_slug}" : ""}"
            a(href: import_url, class: "rm-act-btn") { "[import]" }
          end
        end
      end
    end

    def render_js
      script do
        raw safe(<<~JS)
          document.addEventListener('click', function(e) {
            var hdr = e.target.closest('[data-action="toggle-epic"]');
            if (!hdr) return;
            var targetId = hdr.dataset.target;
            var body = document.getElementById(targetId);
            var chev = hdr.querySelector('[data-chev]');
            if (!body) return;
            var open = body.style.display !== 'none';
            body.style.display = open ? 'none' : 'block';
            if (chev) chev.textContent = open ? '⌄' : '⌃';
          });
        JS
      end
    end
  end
end
