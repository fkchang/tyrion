# frozen_string_literal: true

module Views
  class Attention < Phlex::HTML
    # Matches the fleet board's own snapshot-driven cadence (same TTL the
    # underlying Liveness::Snapshot rebuilds on) -- a poll faster than that
    # would just be re-asking a snapshot that has not changed yet.
    POLL_INTERVAL_MS = 15_000

    def initialize(report:, project:, epic:, stories:, disc_summary:, epic_switcher: [],
                   git_branch: 'main', dirty_count: 0, token: nil)
      @report = report
      @project = project; @epic = epic; @stories = stories; @disc_summary = disc_summary
      @epic_switcher = epic_switcher
      @git_branch = git_branch; @dirty_count = dirty_count
      @token = token
    end

    def view_template
      render Views::Layout.new(project: @project, epic: @epic, stories: @stories,
                                disc_summary: @disc_summary, epic_switcher: @epic_switcher, active_tab: :attention,
                                git_branch: @git_branch, dirty_count: @dirty_count) do
        div(class: "main-content visible", id: "s-attention", data: { token: @token }) do
          div(class: "fl-outer") do
            render_header
            render_section(Tyrion::Attention::STALLED, "STALLED", "at-stalled-title")
            render_section(Tyrion::Attention::WAITING, "WAITING", "at-waiting-title")
            render_fine_footer
          end
        end
        render_monitor_badge
        render_js
      end
    end

    private

    # Cold Open: what this page is, and where things stand, in one glance --
    # never the bare words "stalled"/"waiting" without what they mean here.
    def render_header
      s = @report['summary']
      div(class: "fl-header") do
        h1(class: "rm-title", style: "font-size:24px;margin:0;") { "Needs Your Attention" }
        div(class: "fl-summary") do
          plain "#{s['stalled']} stalled · #{s['waiting']} waiting · #{s['fine']} fine"
        end
      end
      div(class: "at-purpose") do
        plain "Across every project: "
        strong { plain "stalled" }
        plain " = partly done, no activity for longer than #{@report['stale_days']} days · "
        strong { plain "waiting" }
        plain " = paused, or blocked on something · as of #{@report['generated_at']}"
      end
    end

    def render_section(category, title, css_class)
      rows = @report['epics'].select { |e| e['category'] == category }
      return if rows.empty?

      div(class: "at-section-title #{css_class}") { plain "#{title} (#{rows.size})" }
      rows.each { |row| render_epic_card(row) }
    end

    def render_epic_card(row)
      waiting = row['category'] == Tyrion::Attention::WAITING
      div(class: "at-epic-card#{waiting ? ' at-waiting' : ''}") do
        div(class: "at-epic-header") do
          plain "🏭 " if row['mode'] == 'dark_factory'
          a(href: cockpit_href(row['project_slug'], row['epic_slug']), class: "at-epic-link") do
            plain "#{row['project_slug']} / #{row['epic_slug']}"
          end
          plain " — #{row['epic_name']}"
        end
        div(class: "at-epic-detail") { plain epic_detail_text(row) }
        row['waiting_reasons'].each { |reason| div(class: "at-reason") { plain "waiting: #{reason}" } }
        render_current_story(row['current_story'])
        row['lanes'].each { |lane| render_lane(lane) }
        row['suggested_commands'].each { |cmd| div(class: "at-cmd") { plain "→ #{cmd}" } }
      end
    end

    def epic_detail_text(row)
      c = row['counts']
      text = "#{c['done']}/#{c['total']} done"
      text += " · idle #{row['idle_days']} #{row['idle_days'] == 1 ? 'day' : 'days'}" if row['idle_days']
      text
    end

    def render_current_story(story)
      return unless story

      div(class: "at-current") do
        plain "current: #{story['slug']}"
        plain " — #{story['next_action']}" if story['next_action']
      end
    end

    def render_lane(lane)
      div(class: "at-lane") do
        plain(lane['live'] ? "● live" : "○ not live")
        plain " #{lane['token']}"
        plain " (pid #{lane['pid']})" if lane['pid']
      end
    end

    def render_fine_footer
      return if @report['summary']['fine'].zero?

      div(class: "at-fine-footer") do
        plain "#{@report['summary']['fine']} other active/paused #{@report['summary']['fine'] == 1 ? 'epic' : 'epics'} — recently active, unstarted, or fully done. Nothing to do there."
      end
    end

    def cockpit_href(project_slug, epic_slug)
      "/cockpit?project=#{project_slug}&epic=#{epic_slug}"
    end

    # Same fixed-position badge markup/ids the other pollers use.
    def render_monitor_badge
      div(id: "poll-badge",
          style: "position:fixed;bottom:16px;right:16px;background:rgba(20,16,10,.88);border:1px solid rgba(180,140,80,.35);border-radius:20px;padding:6px 14px;display:flex;align-items:center;gap:6px;font-size:12px;font-family:'IBM Plex Mono',monospace;color:var(--amber-dim);z-index:900;backdrop-filter:blur(4px);cursor:default;user-select:none;",
          data: { token: @token }) do
        span(id: "poll-dot", style: "width:7px;height:7px;border-radius:50%;background:var(--amber);display:inline-block;") {}
        span(id: "poll-label") { "monitoring" }
      end
    end

    # Reload-on-token-change, same posture as Discoveries/Global View: this
    # is a full list page with no mid-read state a reload would blank, and a
    # failed poll flips the badge offline but keeps polling rather than
    # freezing (same reasoning as Fleet/Global -- this board's whole job is
    # noticing when something goes stale, so it must not itself go silent).
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
              fetch('/api/attention_poll')
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
