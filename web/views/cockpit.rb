# frozen_string_literal: true

module Views
  class Cockpit < Phlex::HTML
    # Matches Liveness::Snapshot::POLL_INTERVAL_SECONDS, same reasoning
    # Views::Fleet documents on its own constant of the same name: below it
    # would mean racing a snapshot that hasn't rebuilt yet.
    POLL_INTERVAL_MS = 15_000

    # Needs You band (disc-164 addendum): a blocked story that's been sitting
    # for months is not the same kind of "needs you" as a dead process or a
    # stalled lane, and a page that shows all of them flat reads as a guilt
    # inbox (Gloria's Law) rather than attention. Liveness items always show
    # in full; blocked items beyond this count collapse behind a details
    # toggle instead.
    BLOCKED_VISIBLE_LIMIT = 5

    def initialize(project:, epic:, tab:, rows:, attention:, story_counts:, events:, trail_notes:,
                   stories:, disc_summary:, epic_switcher: [], git_branch: 'main', dirty_count: 0,
                   token: nil, project_slug: nil, built_at: nil, stale: false, partial: false)
      @project = project; @epic = epic; @tab = tab
      @rows = rows; @attention = attention; @story_counts = story_counts
      @events = events; @trail_notes = trail_notes
      @stories = stories; @disc_summary = disc_summary; @epic_switcher = epic_switcher
      @git_branch = git_branch; @dirty_count = dirty_count
      @token = token; @project_slug = project_slug
      @built_at = built_at; @stale = stale; @partial = partial
    end

    def view_template
      render Views::Layout.new(project: @project, epic: @epic, stories: @stories,
                                disc_summary: @disc_summary, epic_switcher: @epic_switcher,
                                epic_scope_mode: :scoped, active_tab: nil,
                                git_branch: @git_branch, dirty_count: @dirty_count, project_slug: @project_slug) do
        div(class: "main-content visible", id: "s-cockpit", data: { token: @token }) do
          div(class: "fl-outer") do
            render_header
            render_tabs
            case @tab
            when 'changes' then render_changes
            when 'trail'   then render_trail
            else render_now
            end
          end
        end
        render_monitor_badge unless @tab == 'trail'
        render_js unless @tab == 'trail'
      end
    end

    private

    def render_header
      div(class: "fl-header") do
        h1(class: "rm-title", style: "font-size:24px;margin:0;") { @epic['name'] || @epic['slug'] }
        div(class: "fl-summary") do
          plain "#{@rows.size} lane#{'s' unless @rows.size == 1} · #{@attention.size} need you · snapshot "
          span(id: "ck-snapshot-age", data: { at: @built_at }) { TyrionWeb::Presenter.time_ago_epoch(@built_at) }
          plain " · stale" if @stale
          plain " · partial" if @partial
        end
      end
    end

    def render_tabs
      div(class: "ck-tabs") do
        TyrionWeb::Data::COCKPIT_TABS.each do |t|
          a(href: tab_href(t), class: t == @tab ? "ck-tab active" : "ck-tab", style: "text-decoration:none;") { t.capitalize }
        end
      end
    end

    def tab_href(tab)
      "/cockpit?project=#{@project['slug']}&epic=#{@epic['slug']}&tab=#{tab}"
    end

    # ── Now tab ──────────────────────────────────────────────────────────

    def render_now
      render_needs_you
      render_lanes
      render_progress
    end

    def render_needs_you
      return if @attention.empty?

      # attention is already sorted [severity, -age] (Liveness.attention_items),
      # and BLOCKED carries the highest severity number of any qualifying
      # state, so it is already the tail of this list -- no re-sort needed,
      # only a split so the tail can be capped independently.
      liveness_items, blocked_items = @attention.partition { |a| a['kind'] != 'blocked' }
      visible_blocked = blocked_items.first(BLOCKED_VISIBLE_LIMIT)
      hidden_blocked  = blocked_items.drop(BLOCKED_VISIBLE_LIMIT)

      div(class: "fl-needs-you") do
        div(class: "sidebar-section") { "Needs you" }
        liveness_items.each { |item| render_need_row(item) }
        visible_blocked.each { |item| render_need_row(item) }
        render_blocked_overflow(hidden_blocked) if hidden_blocked.any?
      end
    end

    def render_need_row(item)
      a(href: "/stories/#{item['story_id']}", class: "fl-need-row", style: "text-decoration:none;") do
        span(class: "fl-need-reason") { item['reason'] }
        plain " · #{item['slug']} · "
        span(data: { at: item['at'] }) { TyrionWeb::Presenter.time_ago_epoch(item['at']) }
      end
    end

    # A <details> element needs no JS: the browser owns open/closed state, so
    # a long-blocked epic's overflow costs nothing to render and nothing to
    # wire up.
    def render_blocked_overflow(hidden)
      details(class: "ck-blocked-overflow") do
        summary { "+#{hidden.size} more blocked" }
        hidden.each { |item| render_need_row(item) }
      end
    end

    def render_lanes
      div(class: "sidebar-section") { "Lanes" }
      if @rows.empty?
        div(style: "font-size:13px;color:var(--ink-faint);font-style:italic;margin-bottom:16px;") { "No active lanes" }
      else
        @rows.each { |row| render Views::Components::LaneRow.new(row: row) }
      end
    end

    SEGMENT_CSS = {
      done: 'ck-seg-done', in_progress: 'ck-seg-active', blocked: 'ck-seg-blocked', pending: 'ck-seg-pending'
    }.freeze

    def render_progress
      counts = @story_counts
      total  = counts[:total].to_i

      div(class: "ck-progress") do
        div(class: "sidebar-section") { "Progress" }
        if total.zero?
          div(style: "font-size:13px;color:var(--ink-faint);font-style:italic;") { "No stories yet" }
        else
          div(class: "ck-progress-track") do
            SEGMENT_CSS.each { |key, css| render_segment(counts[key], total, css) }
          end
          div(class: "ck-progress-legend") do
            plain "#{counts[:done]} done · #{counts[:in_progress]} active · #{counts[:blocked]} blocked · #{counts[:pending]} pending"
          end
          # PHASE 3 HOOK (typical-time-left, lane D): a "typical Nm/story,
          # remaining ~Xh (n=Y)" line belongs here once Tyrion::Liveness
          # ships a typical-time helper -- see fleet-visibility.feature's
          # typical-time-left scenario for the exact shape.
        end
      end
    end

    def render_segment(count, total, css)
      return if count.to_i.zero?

      pct = (count.to_f / total * 100).round(2)
      div(class: "ck-seg #{css}", style: "width:#{pct}%;", title: count.to_s) {}
    end

    # ── Changes tab (fleshed out by cockpit-changes-trail-tabs) ─────────────

    def render_changes
      div(style: "font-size:13px;color:var(--ink-faint);font-style:italic;") { "Changes feed coming soon." }
    end

    # ── Trail tab (fleshed out by cockpit-changes-trail-tabs) ───────────────

    def render_trail
      div(style: "font-size:13px;color:var(--ink-faint);font-style:italic;") { "Trail coming soon." }
    end

    # ── Poll badge + JS (same shape as Views::Fleet's own) ──────────────────

    def render_monitor_badge
      div(id: "poll-badge",
          style: "position:fixed;bottom:16px;right:16px;background:rgba(20,16,10,.88);border:1px solid rgba(180,140,80,.35);border-radius:20px;padding:6px 14px;display:flex;align-items:center;gap:6px;font-size:12px;font-family:'IBM Plex Mono',monospace;color:var(--amber-dim);z-index:900;backdrop-filter:blur(4px);cursor:default;user-select:none;",
          data: { token: @token }) do
        span(id: "poll-dot", style: "width:7px;height:7px;border-radius:50%;background:var(--amber);display:inline-block;") {}
        span(id: "poll-label") { "monitoring" }
      end
    end

    # Reload-on-token-change, same as Views::Fleet: every row's evidence/
    # signals/resolution state needs a fresh Liveness snapshot, so a DOM
    # patch would only paper over staleness. Every [data-at] element on this
    # page is a leaf span with no children (LaneRow's own regression guard,
    # plus render_need_row's age span here), so the ticker's textContent
    # overwrite can never destroy sibling markup. A failed poll flips the
    # badge to offline but keeps polling -- same reasoning as the fleet
    # board's poller: this page's whole job is telling you a lane went dead,
    # so it must not freeze looking like nothing is happening on one blip.
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
            var project = #{@project['slug'].to_json};
            var epic    = #{@epic['slug'].to_json};

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
              fetch('/api/cockpit_poll?project=' + encodeURIComponent(project) + '&epic=' + encodeURIComponent(epic))
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
