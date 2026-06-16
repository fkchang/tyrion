# frozen_string_literal: true

module Views
  class WarRoomView < Phlex::HTML
    def initialize(project:, queue:, active:, blocked:, done:, epic:, stories:, disc_summary:, git_branch: 'main', dirty_count: 0, project_slug: nil)
      @project = project; @queue = queue; @active = active; @blocked = blocked; @done = done
      @epic = epic; @stories = stories; @disc_summary = disc_summary
      @git_branch = git_branch; @dirty_count = dirty_count; @project_slug = project_slug
    end

    def view_template
      render Views::Layout.new(project: @project, epic: @epic, stories: @stories,
                                disc_summary: @disc_summary, active_tab: :warroom,
                                git_branch: @git_branch, dirty_count: @dirty_count,
                                project_slug: @project_slug) do
        div(class: "main-content visible", id: "s-warroom") do
          div(class: "wr-board") do
            div(class: "wr-thread-line") do
              raw safe(<<~SVG)
                <svg viewBox="0 0 1200 700" preserveAspectRatio="none" fill="none">
                  <path d="M 380 400 Q 500 500 600 560 Q 700 500 820 400" stroke="rgba(215,176,102,0.35)" stroke-width="2" fill="none"/>
                  <path d="M 380 400 Q 500 500 600 560 Q 700 500 820 400" stroke="rgba(245,190,80,0.15)" stroke-width="6" fill="none" filter="url(#glow)"/>
                  <defs><filter id="glow"><feGaussianBlur stdDeviation="4" result="blur"/><feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>
                </svg>
              SVG
            end

            div(class: "wr-dragon-zone") do
              div do
                img(src: "/assets/dragon.png", alt: "dragon")
                div(class: "wr-dragon-zone-copy") do
                  h3 { "Here Be Dragons" }
                  p { raw safe("Uncertain requirements<br>External dependency<br>Needs human decision") }
                end
              end
            end

            div(class: "wr-columns") do
              render_col("Queue", "Pending", @queue.size, "wr-col") do
                @queue.each { |s| render_card(s) }
              end

              render_col("Active Campaign", "In Progress", @active.size, "wr-col", header_class: "active-hdr") do
                @active.each { |s| render_card(s, stale: TyrionWeb::Presenter.stale?(s['last_note_at'])) }
              end

              render_col("Blocked Frontier", "Blocked", @blocked.size, "wr-col", header_class: "dragons-hdr", show_dragon: true) do
                @blocked.each { |s| render_card(s, blocked: true) }
              end

              render_col("Shipped Keep", "Done", @done.size, "wr-col", header_class: "done-hdr") do
                @done.each { |s| render_done_card(s) }
              end
            end

            in_progress_story = @active.first
            if in_progress_story
              div(class: "wr-resume-strip") do
                div(class: "wr-thread-card") do
                  div(class: "wr-tc-label") { "⚡ Active" }
                  div(class: "wr-tc-text") { in_progress_story['slug'] }
                end
                div(class: "wr-thread-card beacon-card") do
                  div(class: "wr-tc-label") do
                    img(src: "/assets/lantern.png", style: "height:22px;filter:drop-shadow(0 0 8px rgba(245,158,11,.8));")
                    plain " Resume Point"
                  end
                  div(class: "wr-tc-title") { in_progress_story['slug'] }
                  div(class: "wr-tc-meta") { "🕐 #{TyrionWeb::Presenter.time_ago(in_progress_story['last_note_at'])}" }
                end
                div(class: "wr-thread-card") do
                  div(class: "wr-tc-label") { "→ Next Action" }
                  div(class: "wr-tc-text") do
                    na = in_progress_story['next_action']&.strip
                    plain(na && na.length > 0 ? (na.length > 120 ? "#{na.slice(0, 120)}…" : na) : "(not set)")
                  end
                end
              end
            end
          end
        end
      end
    end

    private

    def render_col(title, sub, count, col_class, header_class: nil, show_dragon: false, &block)
      div(class: col_class) do
        div(class: ["wr-col-header", header_class].compact.join(" ")) do
          if show_dragon
            img(src: "/assets/dragon.png", style: "height:22px;opacity:.85;filter:drop-shadow(0 2px 4px rgba(0,0,0,.4));")
          end
          div do
            div(class: "wr-col-title") { title }
            div(class: "wr-col-sub") { sub }
          end
          span(class: count > 0 && show_dragon ? "wr-col-count danger" : "wr-col-count") { count.to_s }
        end
        yield
      end
    end

    def render_card(s, stale: false, blocked: false)
      card_style = blocked ? "border-left:3px solid #b91c1c;background:linear-gradient(180deg,rgba(220,180,160,.97),rgba(190,150,120,.94));" : ""
      a(href: "/stories/#{s['id']}", style: "text-decoration:none;display:block;") do
        div(class: stale ? "wr-card stale" : "wr-card", style: card_style) do
          div(class: "wr-stale-badge") { "⚠ STALE #{TyrionWeb::Presenter.stale_label(s['last_note_at']).gsub('⚠ ', '')}" } if stale
          span(class: "wr-card-id") { s['epic_slug'] || "" }
          h4(class: "wr-card-title") { s['slug'] }
          if s['current_context']
            p(class: "wr-card-ctx") { s['current_context']&.slice(0, 60) }
          end
          div(class: "wr-card-tags") do
            span(class: "wr-tag") { s['status'] }
          end
        end
      end
    end

    def render_done_card(s)
      a(href: "/stories/#{s['id']}", style: "text-decoration:none;display:block;") do
        div(class: "wr-card done-card") do
          span(class: "wr-card-id") { s['epic_slug'] || "" }
          h4(class: "wr-card-title") { s['slug'] }
          div(class: "wr-card-tags") do
            span(style: "font-size:11px;color:#166534;") { "✓ done · #{TyrionWeb::Presenter.time_ago(s['completed_at'])}" }
          end
        end
      end
    end
  end
end
