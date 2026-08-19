# frozen_string_literal: true

module Views
  class GlobalView < Phlex::HTML
    STATUS_CONFIG = {
      active:    { label: "ACTIVE",    css: "gv-status-active"    },
      stale:     { label: "STALE",     css: "gv-status-stale"     },
      idle:      { label: "IDLE",      css: "gv-status-idle"      },
      done:      { label: "DONE",      css: "gv-status-done"      },
      discovery: { label: "DISCOVERY", css: "gv-status-discovery" },
    }.freeze

    def initialize(project_cards:, project:, epic:, stories:, disc_summary:, epic_switcher: [], git_branch: 'main', dirty_count: 0)
      @project_cards = project_cards
      @project = project; @epic = epic; @stories = stories; @disc_summary = disc_summary
      @epic_switcher = epic_switcher
      @git_branch = git_branch; @dirty_count = dirty_count
    end

    def view_template
      render Views::Layout.new(project: @project, epic: @epic, stories: @stories,
                                disc_summary: @disc_summary, epic_switcher: @epic_switcher, active_tab: :global,
                                git_branch: @git_branch, dirty_count: @dirty_count) do
        div(class: "main-content visible", id: "s-global") do
          div(class: "gv-outer") do
            div(class: "gv-header") do
              div(class: "rm-eyebrow") { "Command Center" }
              h1(class: "rm-title", style: "font-size:28px;margin-bottom:4px;") { "All Projects" }
              div(style: "font-size:13px;color:var(--ink-faint);font-family:'IBM Plex Mono',monospace;margin-bottom:24px;") do
                plain "#{@project_cards.size} project#{@project_cards.size == 1 ? '' : 's'} · DB: #{(ENV['TYRION_DB_PATH'] || '~/.tyrion/tyrion.db')}"
              end
            end

            div(class: "gv-cards") do
              @project_cards.each { |card| render_project_card(card) }
            end

            div(class: "gv-registry-note") do
              span(style: "font-size:12px;color:var(--ink-faint);font-family:'IBM Plex Mono',monospace;") do
                plain "Multi-DB registry: "
                span(style: "color:var(--amber-dim);") { "coming soon" }
                plain " — each project can live in its own DB, global view aggregates them all"
              end
            end
          end
        end
      end
    end

    private

    def render_project_card(card)
      proj    = card[:project]
      epic    = card[:active_epic]
      story   = card[:in_progress]
      status  = card[:status]
      cfg     = STATUS_CONFIG[status] || STATUS_CONFIG[:idle]
      is_current = @project && @project['id'] == proj['id']

      total = card[:total]
      done_pct = total > 0 ? (card[:done] * 100.0 / total).round : 0

      div(class: "gv-card#{is_current ? ' gv-card-current' : ''}") do
        div(class: "gv-card-top") do
          div do
            div(class: "gv-card-name") { proj['name'] || proj['slug'] }
            div(class: "gv-card-epic") { epic ? epic['slug'] : "no active epic" }
          end
          span(class: "gv-status-badge #{cfg[:css]}") { cfg[:label] }
        end

        if story
          div(class: "gv-card-story") do
            span(class: story['status'] == 'in_progress' ? 's-icon-pulse' : '',
                 style: "color:var(--amber);margin-right:6px;") { "●" }
            plain story['slug']
            if TyrionWeb::Presenter.stale?(story['last_note_at'])
              span(class: "gv-stale-badge") { TyrionWeb::Presenter.stale_label(story['last_note_at']) }
            end
          end
        elsif status == :done
          div(class: "gv-card-story", style: "color:#1e9e54;") { "✓ All stories complete" }
        elsif status == :discovery
          div(class: "gv-card-story", style: "color:var(--gold-bright);") do
            plain TyrionWeb::Presenter.discovery_summary_text(card[:disc_summary])
          end
        else
          div(class: "gv-card-story", style: "color:var(--ink-faint);font-style:italic;") { "No story in progress" }
        end

        div(class: "gv-card-counts") do
          span(class: "gv-count done") { "✓ #{card[:done]}" }
          span(class: "gv-count") { "○ #{card[:pending]}" }
          span(class: "gv-count blocked") { "✕ #{card[:blocked]}" } if card[:blocked] > 0
          span(class: "gv-count active") { "● #{card[:active]}" } if card[:active] > 0
        end

        if total > 0
          div(class: "gv-card-progress") do
            div(class: "gv-card-track") do
              div(class: "gv-card-fill", style: "width:#{done_pct}%")
            end
            span(style: "font-size:11px;color:var(--ink-faint);") { "#{card[:done]}/#{total}" }
          end
        end

        div(class: "gv-card-footer") do
          if card[:last_note_at]
            span(style: "font-size:12px;color:var(--ink-faint);font-family:'IBM Plex Mono',monospace;") do
              plain "last activity #{TyrionWeb::Presenter.time_ago(card[:last_note_at])}"
            end
          else
            span(style: "font-size:12px;color:var(--ink-faint);font-style:italic;") { "no activity yet" }
          end

          if is_current
            span(style: "font-size:12px;color:var(--amber);font-family:'IBM Plex Mono',monospace;") { "← current" }
          else
            a(href: "/?project=#{proj['slug']}", style: "text-decoration:none;") do
              span(class: "gv-focus-btn") { "Focus →" }
            end
          end
        end
      end
    end
  end
end
