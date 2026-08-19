# frozen_string_literal: true

module Views
  class RoadmapView < Phlex::HTML
    ATTENTION_WEIGHT = { ready: 1, blocked: 2, cold: 3, active: 4, waiting: 5, paused: 6,
                         started: 7, queued: 8, container: 9, empty: 10, sealed: 11 }.freeze
    GAUGE_GLYPHS     = { ready: '✦', blocked: '✕', cold: '⚠', active: '●', waiting: '⌛',
                         paused: '‖', container: '◆', sealed: '✓' }.freeze

    def initialize(project:, active_epics:, archived_epics:, active_epic:, active_story:, stories_by_epic:, criteria:,
                   sidebar_stories:, disc_summary:, graph: TyrionWeb::Data::EMPTY_EPIC_GRAPH, epic_switcher: [],
                   git_branch: 'main', dirty_count: 0, project_slug: nil, flash: nil)
      @project        = project
      @active_epics   = active_epics
      @archived_epics = archived_epics
      @active_epic    = active_epic
      @active_story   = active_story
      @stories_by_epic = stories_by_epic
      @criteria       = criteria
      @graph          = graph
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
                      sorted.each { |epic, depth, parent_archived| render_epic(epic, depth: depth, parent_archived: parent_archived) }
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

    # Memoized -- both sorted_active_epics and render_progress_header need
    # every epic's state, and it's the same computation each time.
    def epic_state_for(epic)
      (@epic_states ||= {})[epic['id']] ||= TyrionWeb::Presenter.epic_state(
        epic,
        @stories_by_epic[epic['id']] || [],
        @active_epic&.dig('id')
      )
    end

    # The actual tree walk (roots-detection, depth, parent_archived) is
    # Store.epic_tree_order — the same method the CLI's `tyrion epic list`
    # uses, so there is exactly one tree-traversal implementation, not two.
    # What's web-specific is root *order*: attention weight, not the created_at
    # order epic_tree_order takes its input in. So the tree is walked once in
    # natural order, then whole root-subtrees (a root and everything nested
    # under it) are reordered as units by the root's attention weight —
    # children never move independently of their parent.
    def sorted_active_epics
      ordered = Tyrion::Store.epic_tree_order(@active_epics, @graph)
      ordered.slice_when { |_prev, curr| curr[1].zero? }
             .sort_by { |chunk| ATTENTION_WEIGHT.fetch(epic_state_for(chunk.first[0])[:state]) }
             .flatten(1)
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

    def render_epic(epic, depth:, parent_archived:)
      state     = epic_state_for(epic)
      stories   = @stories_by_epic[epic['id']] || []
      done_s    = stories.count { |s| s['status'] == 'done' }
      is_sealed = state[:state] == :sealed
      list_id   = "epic-stories-#{epic['id'].to_s.gsub('-', '_')}"
      open      = state[:focus] && !is_sealed

      div(class: ["rm-epic", (state[:focus] ? "active" : nil), (depth.positive? ? "rm-epic-child" : nil)],
          style: (depth.positive? ? "margin-left:#{depth * 20}px;" : nil),
          data: { epic_id: epic['id'] }) do
        div(class: "rm-epic-header", data: { action: "toggle-epic", target: list_id },
            style: "cursor:pointer;") do
          div(class: state[:color_css]) { state[:glyph] }
          div(class: "rm-epic-name") do
            plain("★ ") if state[:focus]
            plain epic['slug']
            span(style: "font-size:11px;color:var(--ink-faint);font-style:italic;") { " (parent archived)" } if parent_archived
          end
          div(class: "rm-epic-meta") do
            span(class: "rm-epic-state-label") { state[:label] }
            span(class: "rm-epic-stats") { "#{done_s}/#{stories.size}" } if stories.any?
          end
          render_mini_track(epic, state, done_s, stories.size)
          div(class: "rm-chev", data: { chev: list_id }) { open ? "⌃" : "⌄" }
        end

        render_action_buttons(epic, state, stories) if state[:action] || state[:archived]

        div(id: list_id, class: "rm-story-list-wrap", style: open ? "" : "display:none;") do
          render_story_list(stories, epic)
        end
      end
    end

    # A container shows its sealed-descendant-epics roll-up (child_stats) in
    # purple, since its own story fraction is usually empty and would be
    # misleading. A genuinely empty leaf gets the dashed placeholder. Anything
    # else shows its own done/total.
    def render_mini_track(epic, state, done_s, story_total)
      if state[:state] == :container
        stats = epic['child_stats'] || { done: 0, total: 0 }
        pct   = stats[:total].positive? ? (stats[:done] * 100.0 / stats[:total]).round : 0
        div(class: "rm-mini-track") { div(class: "rm-mini-fill purple", style: "width:#{pct}%") }
      elsif state[:state] == :empty
        div(class: "rm-mini-track empty")
      else
        pct = story_total.positive? ? (done_s * 100.0 / story_total).round : 0
        div(class: "rm-mini-track") { div(class: "rm-mini-fill", style: "width:#{pct}%") }
      end
    end

    def render_archived_section
      details(class: "rm-archived-section") do
        summary(class: "rm-archived-summary") { "Archived (#{@archived_epics.size})" }
        div(class: "rm-epic-list rm-archived-list") do
          Tyrion::Store.epic_tree_order(@archived_epics, @graph).each do |epic, depth, parent_archived|
            render_epic(epic, depth: depth, parent_archived: parent_archived)
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
