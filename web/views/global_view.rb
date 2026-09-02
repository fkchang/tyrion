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

    POLL_INTERVAL_MS = 60_000

    def initialize(project_cards:, project:, epic:, stories:, disc_summary:, epic_switcher: [], git_branch: 'main', dirty_count: 0, token: nil)
      @project_cards = project_cards
      @project = project; @epic = epic; @stories = stories; @disc_summary = disc_summary
      @epic_switcher = epic_switcher
      @git_branch = git_branch; @dirty_count = dirty_count
      @token = token
    end

    def view_template
      render Views::Layout.new(project: @project, epic: @epic, stories: @stories,
                                disc_summary: @disc_summary, epic_switcher: @epic_switcher, active_tab: :global,
                                git_branch: @git_branch, dirty_count: @dirty_count) do
        div(class: "main-content visible", id: "s-global", data: { token: @token }) do
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
        render_monitor_badge
        render_js
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

        # Style varies per branch below exactly as it did before this change;
        # only the glyph is new, and it renders unconditionally on whether any
        # lane exists in the project -- NOT nested inside the `story` branch,
        # since a project's in-progress lane can live outside the active epic
        # (in_progress is the legacy active-epic-only pick) and would otherwise
        # go glyph-less the one time this feature exists to show it.
        subject_style =
          if story then nil
          elsif status == :done then "color:#1e9e54;"
          elsif status == :discovery then "color:var(--gold-bright);"
          else "color:var(--ink-faint);font-style:italic;"
          end

        div(class: "gv-card-story", style: subject_style) do
          render_lane_glyph(card)
          if story
            plain story['slug']
            if TyrionWeb::Presenter.stale?(story['last_note_at'])
              span(class: "gv-stale-badge") { TyrionWeb::Presenter.stale_label(story['last_note_at']) }
            end
          elsif status == :done
            plain "✓ All stories complete"
          elsif status == :discovery
            plain TyrionWeb::Presenter.discovery_summary_text(card[:disc_summary])
          else
            plain "No story in progress"
          end
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

    # Worst state across EVERY in-progress lane in the project, regardless of
    # which story is shown below it. Renders nothing when the project has no
    # lane at all, since there is nothing honest to show.
    def render_lane_glyph(card)
      return if card[:lane_count].zero?

      lane = TyrionWeb::Presenter.liveness_glyph(card[:worst_lane_state])
      span(class: lane[:css], style: "margin-right:6px;", title: lane[:label]) { lane[:glyph] }
      plain " ×#{card[:lane_count]}" if card[:lane_count] > 1
    end

    # Same fixed-position badge markup and ids Discoveries uses (poll-badge /
    # poll-dot / poll-label), so shared.css's fade-in/pulse rules apply for
    # free and the two pages read the same way at a glance.
    def render_monitor_badge
      div(id: "poll-badge",
          style: "position:fixed;bottom:16px;right:16px;background:rgba(20,16,10,.88);border:1px solid rgba(180,140,80,.35);border-radius:20px;padding:6px 14px;display:flex;align-items:center;gap:6px;font-size:12px;font-family:'IBM Plex Mono',monospace;color:var(--amber-dim);z-index:900;backdrop-filter:blur(4px);cursor:default;user-select:none;",
          data: { token: @token }) do
        span(id: "poll-dot", style: "width:7px;height:7px;border-radius:50%;background:var(--amber);display:inline-block;") {}
        span(id: "poll-label") { "monitoring" }
      end
    end

    # Reload-on-token-change, seeded from the page's own render (Ambient/
    # Discoveries pattern, not Active Story's null-bootstrap). Unlike an
    # earlier draft of this poller, a failed poll does NOT stop polling --
    # this board's entire job is telling you a lane went dead, so a poller
    # that silently gives up on the first wifi blip or `tyrion web restart`
    # would freeze the fleet's most-watched page looking exactly like nothing
    # is happening. It surfaces the failure on the badge instead, same as
    # Discoveries' own poller.
    def render_js
      script do
        raw safe(<<~JS)
          (function () {
            var badge = document.getElementById('poll-badge');
            if (!badge) return;
            var dot   = document.getElementById('poll-dot');
            var label = document.getElementById('poll-label');
            var knownToken = badge.dataset.token || null;
            var INTERVAL = #{POLL_INTERVAL_MS};

            function poll() {
              fetch('/api/global_poll')
                .then(function (r) { if (!r.ok) throw new Error('poll'); return r.json(); })
                .then(function (data) {
                  dot.style.background = 'var(--amber)';
                  if (data.token && data.token !== knownToken) {
                    knownToken = data.token;
                    label.textContent = 'updating…';
                    setTimeout(function () { window.location.reload(); }, 400);
                  } else {
                    label.textContent = 'monitoring';
                  }
                })
                .catch(function () {
                  dot.style.background = '#666';
                  label.textContent = 'offline';
                });
            }

            poll();
            setInterval(poll, INTERVAL);
          })();
        JS
      end
    end
  end
end
