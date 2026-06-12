# frozen_string_literal: true

module Views
  class RoadmapView < Phlex::HTML
    def initialize(project:, epics:, active_epic:, active_story:, stories_by_epic:, criteria:,
                   sidebar_stories:, disc_summary:, git_branch: 'main', dirty_count: 0)
      @project = project; @epics = epics; @active_epic = active_epic
      @active_story = active_story; @stories_by_epic = stories_by_epic; @criteria = criteria
      @sidebar_stories = sidebar_stories; @disc_summary = disc_summary
      @git_branch = git_branch; @dirty_count = dirty_count
    end

    def view_template
      render Views::Layout.new(project: @project, epic: @active_epic,
                                stories: @sidebar_stories, disc_summary: @disc_summary,
                                active_tab: :roadmap, git_branch: @git_branch, dirty_count: @dirty_count) do
        div(class: "main-content visible", id: "s-roadmap") do
          div(class: "rm-outer") do
            div(class: "rm-wrap") do
              section(class: "rm-ledger") do
                div(class: "rm-worn-edge")
                div(class: "rm-content") do
                  div(class: "rm-eyebrow") { "Campaign Ledger" }
                  h1(class: "rm-title") { @project ? @project['name'] : "No project" }
                  div(class: "rm-ornament")

                  if @epics.any?
                    render_progress_header
                    div(class: "rm-epic-list") do
                      @epics.each { |epic| render_epic(epic) }
                    end
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

    def render_progress_header
      done_count = @epics.count { |e| e['status'] == 'done' }
      active_count = @epics.count { |e| e['status'] == 'active' }
      pct = @epics.empty? ? 0 : (done_count * 100.0 / @epics.size).round
      div(class: "rm-progress-line") do
        span { "♜ #{done_count} of #{@epics.size} epics done" }
        div(class: "rm-progress-track") do
          div(class: "rm-progress-fill", style: "width:#{pct}%")
        end
        span(style: "color:#b26600;font-weight:500") { "♞ #{active_count} in progress" }
      end
    end

    def render_epic(epic)
      stories = @stories_by_epic[epic['id']] || []
      is_active = @active_epic && epic['id'] == @active_epic['id']
      done_s    = stories.count { |s| s['status'] == 'done' }
      blocked_s = stories.count { |s| s['status'] == 'blocked' }
      pct       = stories.empty? ? (epic['status'] == 'done' ? 100 : 0) : (done_s * 100.0 / stories.size).round
      list_id   = "epic-stories-#{epic['id'].gsub('-', '_')}"

      div(class: is_active ? "rm-epic active" : "rm-epic", data: { epic_id: epic['id'] }) do
        div(class: "rm-epic-header", data: { action: "toggle-epic", target: list_id },
            style: "cursor:pointer;") do
          seal_css = TyrionWeb::Presenter.epic_seal_css(epic, @active_epic&.dig('id'))
          div(class: seal_css) { TyrionWeb::Presenter.epic_seal_glyph(epic, @active_epic&.dig('id')) }
          div(class: "rm-epic-name") { epic['slug'] }
          div(class: "rm-epic-meta") do
            if blocked_s > 0
              span(class: "rm-blocked-badge") { "#{blocked_s} blocked" }
            end
            span(class: "rm-epic-stats") do
              plain stories.any? ? "#{done_s}/#{stories.size} stories" : epic['status']
            end
          end
          div(class: "rm-mini-track") do
            div(class: "rm-mini-fill#{is_active ? ' amber' : ''}", style: "width:#{pct}%")
          end
          div(class: "rm-chev", data: { chev: list_id }) { is_active ? "⌃" : "⌄" }
        end

        div(id: list_id, class: "rm-story-list-wrap",
            style: is_active ? "" : "display:none;") do
          render_story_list(stories, epic)
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
