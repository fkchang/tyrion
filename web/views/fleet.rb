# frozen_string_literal: true

module Views
  class Fleet < Phlex::HTML
    # Below the snapshot's own POLL_INTERVAL_SECONDS (15) would mean racing a
    # snapshot that hasn't rebuilt yet; matching it keeps every tick worth a look.
    POLL_INTERVAL_MS = 15_000

    def initialize(fleet:, project:, epic:, stories:, disc_summary:, epic_switcher: [], git_branch: 'main', dirty_count: 0, token: nil)
      @fleet = fleet
      @project = project; @epic = epic; @stories = stories; @disc_summary = disc_summary
      @epic_switcher = epic_switcher
      @git_branch = git_branch; @dirty_count = dirty_count
      @token = token
    end

    def view_template
      render Views::Layout.new(project: @project, epic: @epic, stories: @stories,
                                disc_summary: @disc_summary, epic_switcher: @epic_switcher, active_tab: :fleet,
                                git_branch: @git_branch, dirty_count: @dirty_count) do
        div(class: "main-content visible", id: "s-fleet", data: { token: @token }) do
          div(class: "fl-outer") do
            render_header
            render_needs_you
            render_projects
            render_idle_footer
          end
        end
        render_monitor_badge
        render_js
      end
    end

    private

    def render_header
      div(class: "fl-header") do
        h1(class: "rm-title", style: "font-size:24px;margin:0;") { "Fleet" }
        div(class: "fl-summary") do
          plain "#{@fleet[:live_count]} live · #{@fleet[:attention].size} need you · snapshot "
          span(id: "fl-snapshot-age", data: { at: @fleet[:built_at] }) { TyrionWeb::Presenter.time_ago_epoch(@fleet[:built_at]) }
          # A board built on "never fake it" can't show a confident snapshot
          # age while the snapshot itself admits it's behind or incomplete.
          plain " · stale" if @fleet[:stale]
          plain " · partial" if @fleet[:partial]
        end
      end
    end

    def render_needs_you
      return if @fleet[:attention].empty?

      div(class: "fl-needs-you") do
        div(class: "sidebar-section") { "Needs you" }
        @fleet[:attention].each do |item|
          a(href: cockpit_href(item['project_slug'], item['epic_slug']), class: "fl-need-row", style: "text-decoration:none;") do
            span(class: "fl-need-reason") { item['reason'] }
            plain " · #{item['slug']} · "
            span(data: { at: item['at'] }) { TyrionWeb::Presenter.time_ago_epoch(item['at']) }
          end
        end
      end
    end

    def render_projects
      @fleet[:projects].each do |group|
        proj = group[:project]
        div(class: "fl-project-group") do
          a(href: cockpit_href(proj['slug'], nil), class: "fl-project-header", style: "text-decoration:none;") do
            plain proj['name'] || proj['slug']
          end
          group[:rows].each { |row| render Views::Components::LaneRow.new(row: row) }
        end
      end
    end

    # last_activity_at is already an epoch integer (or nil) by the time it
    # reaches here -- Data.load_fleet_view normalizes it via Tyrion::Liveness.
    # epoch, so this view never parses a timestamp itself.
    def render_idle_footer
      return if @fleet[:idle_projects].empty?

      div(class: "fl-idle-footer") do
        @fleet[:idle_projects].each do |ip|
          epoch = ip[:last_activity_at]
          span(class: "fl-idle-item") do
            plain "#{ip[:project]['slug']} — "
            if epoch
              span(data: { at: epoch }) { TyrionWeb::Presenter.time_ago_epoch(epoch) }
            else
              plain "no activity yet"
            end
          end
        end
      end
    end

    def cockpit_href(project_slug, epic_slug)
      qs = ["project=#{project_slug}"]
      qs << "epic=#{epic_slug}" if epic_slug
      "/cockpit?#{qs.join('&')}"
    end

    # Same fixed-position badge markup and ids Discoveries/Global View use.
    def render_monitor_badge
      div(id: "poll-badge",
          style: "position:fixed;bottom:16px;right:16px;background:rgba(20,16,10,.88);border:1px solid rgba(180,140,80,.35);border-radius:20px;padding:6px 14px;display:flex;align-items:center;gap:6px;font-size:12px;font-family:'IBM Plex Mono',monospace;color:var(--amber-dim);z-index:900;backdrop-filter:blur(4px);cursor:default;user-select:none;",
          data: { token: @token }) do
        span(id: "poll-dot", style: "width:7px;height:7px;border-radius:50%;background:var(--amber);display:inline-block;") {}
        span(id: "poll-label") { "monitoring" }
      end
    end

    # Two independent jobs, same split ambient.rb documents: (1) reload the
    # whole page on a token change, since every row's evidence/signals/
    # resolution state genuinely needs a fresh Liveness snapshot rather than
    # a DOM patch; (2) tick every [data-at] element's text every interval,
    # token or not, so ages stay honest between reloads without ever riding
    # on the token itself. Every data-at element in this page is a LEAF span
    # with no children (LaneRow's own comment explains why that's load-
    # bearing) so overwriting its textContent can never destroy sibling
    # markup. A failed poll flips the badge to offline but keeps polling --
    # this board's entire job is telling you a lane went dead, so it must
    # not freeze looking like nothing is happening on the first blip
    # (same reasoning as Global View's poller); the feature file's literal
    # "stops polling on a non-200" wording predates that reasoning and is
    # flagged as a decision note on this story rather than silently ignored.
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

            function timeAgo(epoch) {
              if (!epoch) return '—';
              var secs = Math.floor(Date.now() / 1000) - parseInt(epoch, 10);
              if (secs < 0) secs = 0;
              if (secs < 60) return 'just now';
              var mins = Math.floor(secs / 60);
              if (mins < 60) return mins + 'm ago';
              var hrs = Math.floor(mins / 60);
              if (hrs < 24) return hrs + 'h ago';
              return Math.floor(hrs / 24) + 'd ago';
            }

            function refreshAges() {
              var nodes = document.querySelectorAll('[data-at]');
              for (var i = 0; i < nodes.length; i++) {
                var at = nodes[i].dataset.at;
                if (!at) continue;
                var lbl = nodes[i].dataset.label;
                nodes[i].textContent = (lbl ? lbl + ' ' : '') + timeAgo(at);
              }
            }

            function poll() {
              fetch('/api/fleet_poll')
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

            refreshAges();
            poll();
            setInterval(function () { refreshAges(); poll(); }, INTERVAL);
          })();
        JS
      end
    end
  end
end
