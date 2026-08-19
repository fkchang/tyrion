# frozen_string_literal: true

module Views
  # Standalone ambient status page — deliberately NOT wrapped in Views::Layout.
  # It lives in a 300-360px browser pane split alongside a terminal, so navbar
  # and sidebar chrome would be width the marks can't use, and any story /
  # criteria / git detail would be something to read rather than glance at.
  class Ambient < Phlex::HTML
    AGING_DAYS  = 14   # same threshold as the Discoveries marks aging badge
    # ~37 chars/line at 14px IBM Plex Mono in the 340px window (312px usable
    # after padding) -- 72 keeps a mark's question to 2 lines, a glance
    # instead of a paragraph. .am-mark-q also line-clamps to 2 as a backstop
    # for any word that doesn't wrap as tightly as the char-count assumes.
    TRUNCATE_AT = 72
    POLL_INTERVAL_MS = 60_000   # slower than the story pane's 30s — glance surface, not a monitor

    def initialize(project:, marks: [], findings_ready_count: 0, token: nil)
      @project              = project
      @marks                = marks || []
      @findings_ready_count = findings_ready_count.to_i
      @token                = token
    end

    def view_template
      doctype
      html(lang: "en") do
        head do
          meta(charset: "UTF-8")
          meta(name: "viewport", content: "width=device-width, initial-scale=1.0")
          title { "tyrion · ambient" }
          link(rel: "stylesheet", href: "/ambient.css")
        end
        body(data: { project: project_slug, token: @token }) do
          if @project.nil?
            div(class: "am-empty") { "no project" }
          else
            div(class: "am-project") { project_slug }
            render_marks
            render_ready_line
            render_js
          end
        end
      end
    end

    private

    def project_slug
      @project && (@project['slug'] || @project['name'] || '')
    end

    # The dedicated per-discovery page (design: 2026-08-18 discovery glance/detail
    # spec) — target=_blank so clicking from the narrow ambient pane doesn't
    # navigate it away from the glance surface it's meant to stay pinned to. No
    # escaping needed: project slugs are always slugify()'d elsewhere in the app.
    def discovery_url(disc_id)
      "/discoveries/#{disc_id}"
    end

    def ambient_url
      "/ambient?project=#{project_slug}"
    end

    # Zero open marks blanks this section only — the findings_ready line below
    # still renders, so the pane never goes fully dark on a half-empty state.
    # The container and the per-mark created_at are what the poller repaints
    # from; created_at also lets aging be recomputed without a round trip.
    def render_marks
      div(id: "am-marks") do
        @marks.each { |m| render_mark(m) }
      end
    end

    # Compact row (always visible) + a hidden expand section revealed on click —
    # progressive disclosure in place, no navigation required for the common
    # case. The expand section is server-rendered every time (not fetched on
    # click) so it works with JS doing nothing but a class toggle.
    def render_mark(m)
      is_aged = aged?(m)
      div(class: is_aged ? "am-mark aged" : "am-mark", data: { created_at: m['created_at'] }) do
        div(class: "am-mark-toggle") do
          div(class: "am-mark-q") { truncate(Tyrion::Output.discovery_glance_text(m)) }
          div(class: "am-mark-meta") do
            plain m['id']
            plain " · #{TyrionWeb::Presenter.time_ago(m['created_at'])}"
            # Always in the DOM; CSS shows it only under .am-mark.aged, so
            # refreshAging()'s class toggle (every tick, token or not) is
            # the only thing that needs to control it — no separate JS path.
            span(class: "am-stale-label") { " · stale" }
          end
        end
        render_mark_full(m)
      end
    end

    def render_mark_full(m)
      div(class: "am-mark-full") do
        if m['headline'] && m['headline'] != m['question']
          div(class: "am-mark-full-question") { m['question'] }
        end
        div(class: "am-mark-actions") do
          form(method: "post", action: "/discoveries/#{m['id']}/defer", class: "am-defer-form") do
            input(type: "hidden", name: "return_to", value: ambient_url)
            button(type: "submit") { "Defer" }
          end
          a(href: discovery_url(m['id']), target: "_blank", rel: "noopener") { "Open full view →" }
        end
      end
    end

    def render_ready_line
      div(id: "am-ready", class: "am-ready") do
        "#{@findings_ready_count} findings ready"
      end
    end

    # Two independent jobs per tick, and the split is the whole point:
    #   1. token changed -> repaint BOTH sections from the payload
    #   2. aging recomputed from created_at every tick, token or not
    # AGING_DAYS / TRUNCATE_AT are interpolated from the Ruby constants above so
    # the client repaint can't drift from the server-side first render.
    def render_js
      script do
        raw safe(<<~JS)
          (function () {
            var AGING_MS   = #{AGING_DAYS} * 86400000;
            var TRUNCATE   = #{TRUNCATE_AT};
            var INTERVAL   = #{POLL_INTERVAL_MS};
            var slug       = document.body.dataset.project;
            var knownToken = document.body.dataset.token || null;
            var marksHost  = document.getElementById('am-marks');
            var readyLine  = document.getElementById('am-ready');
            if (!slug || !marksHost || !readyLine) return;

            function truncate(t) { return t.length > TRUNCATE ? t.slice(0, TRUNCATE) + '\\u2026' : t; }

            function timeAgo(ts) {
              if (!ts) return '\\u2014';
              var secs = Math.floor((Date.now() - Date.parse(ts)) / 1000);
              if (secs < 60) return 'just now';
              var mins = Math.floor(secs / 60);
              if (mins < 60) return mins + 'm ago';
              var hrs = Math.floor(mins / 60);
              if (hrs < 24) return hrs + 'h ago';
              return Math.floor(hrs / 24) + 'd ago';
            }

            // A mark crossing the threshold changes neither its id nor its text,
            // so no token moves — this can never be gated on a token diff.
            function refreshAging() {
              var nodes = marksHost.querySelectorAll('.am-mark');
              for (var i = 0; i < nodes.length; i++) {
                var ts = nodes[i].dataset.createdAt;
                nodes[i].classList.toggle('aged', ts ? (Date.now() - Date.parse(ts)) >= AGING_MS : false);
              }
            }

            var ambientUrl = '/ambient?project=' + encodeURIComponent(slug);

            // Marks list and findings_ready line always repaint together —
            // repainting one alone would leave the pane self-contradicting.
            // NOTE: a repaint always collapses any expanded card back to
            // compact (no expand-state carried across a real content change)
            // — an accepted gap, not a bug: see the design spec's "deliberately
            // out of scope" section.
            function apply(data) {
              marksHost.textContent = '';
              (data.marks || []).forEach(function (m) {
                var wrap = document.createElement('div');
                wrap.className = 'am-mark';
                wrap.dataset.createdAt = m.created_at || '';

                var toggle = document.createElement('div');
                toggle.className = 'am-mark-toggle';
                var q = document.createElement('div');
                q.className = 'am-mark-q';
                q.textContent = truncate(String(m.text || ''));
                var meta = document.createElement('div');
                meta.className = 'am-mark-meta';
                meta.appendChild(document.createTextNode(m.id + ' \\u00b7 ' + timeAgo(m.created_at)));
                var stale = document.createElement('span');
                stale.className = 'am-stale-label';
                stale.textContent = ' \\u00b7 stale';
                meta.appendChild(stale);
                toggle.appendChild(q);
                toggle.appendChild(meta);
                wrap.appendChild(toggle);

                var full = document.createElement('div');
                full.className = 'am-mark-full';
                if (m.headline && m.headline !== m.question) {
                  var qFull = document.createElement('div');
                  qFull.className = 'am-mark-full-question';
                  qFull.textContent = m.question || '';
                  full.appendChild(qFull);
                }
                var actions = document.createElement('div');
                actions.className = 'am-mark-actions';
                var deferForm = document.createElement('form');
                deferForm.method = 'post';
                deferForm.action = '/discoveries/' + m.id + '/defer';
                deferForm.className = 'am-defer-form';
                var returnTo = document.createElement('input');
                returnTo.type = 'hidden'; returnTo.name = 'return_to'; returnTo.value = ambientUrl;
                var deferBtn = document.createElement('button');
                deferBtn.type = 'submit'; deferBtn.textContent = 'Defer';
                deferForm.appendChild(returnTo); deferForm.appendChild(deferBtn);
                var openLink = document.createElement('a');
                openLink.href = '/discoveries/' + m.id;
                openLink.target = '_blank'; openLink.rel = 'noopener';
                openLink.textContent = 'Open full view \\u2192';
                actions.appendChild(deferForm); actions.appendChild(openLink);
                full.appendChild(actions);
                wrap.appendChild(full);

                marksHost.appendChild(wrap);
              });
              readyLine.textContent = (data.findings_ready_count || 0) + ' findings ready';
            }

            // A 404 still carries a renderable empty-state body, so it flows
            // through the same path rather than being treated as an error.
            function poll() {
              fetch('/api/ambient_poll?project=' + encodeURIComponent(slug))
                .then(function (r) { return r.json(); })
                .then(function (data) {
                  if (data.token !== knownToken) { knownToken = data.token; apply(data); }
                  refreshAging();
                })
                .catch(function () { refreshAging(); });
            }

            // Delegated so it keeps working after apply() rebuilds #am-marks.
            marksHost.addEventListener('click', function (ev) {
              var toggle = ev.target.closest('.am-mark-toggle');
              if (!toggle) return;
              toggle.parentElement.classList.toggle('expanded');
            });

            refreshAging();
            setInterval(poll, INTERVAL);
          })();
        JS
      end
    end

    # Unrounded day math against created_at, matching the marks aging badge.
    def aged?(mark)
      ts = mark['created_at']
      return false unless ts

      (Time.now - Time.parse(ts.to_s)) / 86_400.0 >= AGING_DAYS
    rescue ArgumentError
      false
    end

    # Hard cap for very long marks; CSS wraps unbroken tokens that survive it.
    def truncate(text)
      text.length > TRUNCATE_AT ? "#{text[0, TRUNCATE_AT]}…" : text
    end
  end
end
