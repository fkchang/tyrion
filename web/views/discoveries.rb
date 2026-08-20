# frozen_string_literal: true

module Views
  class DiscoveriesView < Phlex::HTML
    def initialize(project:, spike:, findings_ready:, marks:, epic:, stories:, disc_summary:, epic_switcher: [], git_branch: 'main', dirty_count: 0, project_slug: nil, token: nil)
      @project = project; @spike = spike; @findings_ready = findings_ready; @marks = marks
      @epic = epic; @stories = stories; @disc_summary = disc_summary
      @epic_switcher = epic_switcher
      @git_branch = git_branch; @dirty_count = dirty_count; @project_slug = project_slug
      @token = token
    end

    def view_template
      render Views::Layout.new(project: @project, epic: @epic, stories: @stories,
                                disc_summary: @disc_summary, epic_switcher: @epic_switcher, active_tab: :discoveries,
                                git_branch: @git_branch, dirty_count: @dirty_count,
                                project_slug: @project_slug) do
        div(class: "main-content visible", id: "s-discoveries") do
          div(class: "dv-outer") do
            div(class: "dv-ledger") do
              div(class: "rm-worn-edge")
              div(class: "rm-content") do
                div(class: "rm-eyebrow") { "Findings Scroll" }
                h1(class: "rm-title") { "Discoveries" }
                div(class: "rm-ornament")

                if @spike.nil? && @findings_ready.empty? && @marks.empty?
                  div(style: "text-align:center;padding:48px 0;") do
                    div(style: "font-size:40px;opacity:.25;margin-bottom:16px;") { "🔬" }
                    div(style: "font-family:'Cinzel',serif;font-size:18px;color:var(--ink-dim);margin-bottom:8px;") { "No discoveries yet" }
                    div(style: "font-size:13px;color:var(--ink-faint);font-family:'IBM Plex Mono',monospace;") { "tyrion mark \"observation\" · tyrion spike start \"question?\"" }
                  end
                else
                  render_spike_section if @spike
                  render_ready_section unless @findings_ready.empty?
                  render_marks_section unless @marks.empty?
                end
              end
            end
          end
        end
        if @project
          render_monitor_badge
          render_js
        end
      end
    end

    private

    def render_origin(disc)
      render_tag(TyrionWeb::Presenter.origin_tag(disc['origin']))
    end

    def render_verdict(disc)
      render_tag(TyrionWeb::Presenter.verdict_tag(disc['verdict']))
    end

    # origin_tag always returns a tag; verdict_tag returns nil when unscored (nothing
    # honest to show) -- one nil guard here covers both callers.
    def render_tag(tag)
      return unless tag

      span(class: tag[:css]) { tag[:text] }
    end

    # Markdown-rendered question, same helper for spike/ready/mark cards --
    # matches discovery_show.rb's dv-card-q dv-md treatment (which also
    # dropped the old literal quote marks: they'd otherwise wrap a block-level
    # <p> from markdown_lite, splitting the quotes onto their own lines).
    def render_question(question)
      div(class: "dv-card-q dv-md") { raw safe(TyrionWeb::Presenter.markdown_lite(question)) }
    end

    FIELD_LABEL_STYLE = "font-weight:600;color:var(--ink-faint);font-size:11px;text-transform:uppercase;letter-spacing:.04em"

    # Label above a value, same shape as discovery_show.rb's render_field --
    # a plain inline label butting directly against markdown_lite's
    # block-level <p>/<ul> output reads as an orphaned, unstyled prefix, so
    # the label gets its own line same as the show page.
    def render_labeled(label)
      div(style: "margin-top:6px") do
        div(style: FIELD_LABEL_STYLE) { label }
        yield
      end
    end

    # Markdown-rendered prose fields (finding, recommendation, hypothesis,
    # exit_criteria) so bold/code/lists interpret the same way on both pages.
    def render_labeled_md(label, text)
      return if text.to_s.strip.empty?

      render_labeled(label) { raw safe(TyrionWeb::Presenter.markdown_lite(text)) }
    end

    # Confidence is a short label, not prose -- same "no markdown pass" rule
    # discovery_show.rb's render_field(markdown: false) uses for it.
    def render_labeled_plain(label, text)
      return if text.to_s.strip.empty?

      render_labeled(label) { plain text }
    end

    def render_spike_section
      div(class: "dv-section") do
        div(class: "dv-section-header") do
          div(class: "dv-mini-seal spike") { "⚗" }
          div(class: "dv-section-title") { "active_spike — 1 in flight" }
        end
        div(class: "dv-card spike", id: @spike['id']) do
          div(class: "dv-card-id") do
            a(href: "/discoveries/#{@spike['id']}", class: "dv-card-id-link") { "#{@spike['id']} · started #{TyrionWeb::Presenter.time_ago(@spike['created_at'])}" }
            render_origin(@spike)
          end
          render_question(@spike['question'])
          div(class: "dv-card-meta dv-md") do
            render_labeled_md('Hypothesis', @spike['hypothesis'])
            render_labeled_md('Exit criteria', @spike['exit_criteria'])
          end
          div(class: "dv-actions") do
            span(class: "dv-code-chip") { "tyrion spike done" }
          end
        end
      end
    end

    def render_ready_section
      div(class: "dv-section") do
        div(class: "dv-section-header") do
          div(class: "dv-mini-seal ready") { "✦" }
          div(class: "dv-section-title") { "findings_ready — #{@findings_ready.size} #{@findings_ready.size == 1 ? 'discovery' : 'discoveries'}" }
        end
        @findings_ready.each do |d|
          aging = TyrionWeb::Data.aged?(d['created_at'], TyrionWeb::Data::READY_AGING_DAYS)
          div(class: "dv-card ready", id: d['id']) do
            div(class: "dv-card-id") do
              a(href: "/discoveries/#{d['id']}", class: "dv-card-id-link") { "#{d['id']} · found #{TyrionWeb::Presenter.time_ago(d['created_at'])}" }
              render_origin(d)
              render_verdict(d)
              span(class: "dv-aging-badge") { " ⚠ aging" } if aging
            end
            div(class: "dv-card-headline") { d['headline'] } if d['headline']
            render_question(d['question'])
            div(class: "dv-card-meta dv-md") do
              render_labeled_plain('Confidence', d['confidence'])
              render_labeled_md('Finding', d['finding'])
              render_labeled_md('Recommendation', d['recommendation'])
            end
            div(class: "dv-actions") do
              span(class: "dv-code-chip") { "tyrion spike promote #{d['id']}" }
            end
          end
        end
      end
    end

    def render_marks_section
      div(class: "dv-section") do
        div(class: "dv-section-header") do
          div(class: "dv-mini-seal mark") { "·" }
          div(class: "dv-section-title") { "marks — #{@marks.size} unformalized" }
        end
        @marks.each do |d|
          aging = TyrionWeb::Data.aged?(d['created_at'], TyrionWeb::Data::MARK_AGING_DAYS)
          div(class: "dv-card mark", id: d['id']) do
            div(class: "dv-card-id") do
              a(href: "/discoveries/#{d['id']}", class: "dv-card-id-link") { "#{d['id']} · #{TyrionWeb::Presenter.time_ago(d['created_at'])}" }
              render_origin(d)
              span(class: "dv-aging-badge") { " ⚠ aging" } if aging
            end
            div(class: "dv-card-headline") { d['headline'] } if d['headline']
            render_question(d['question'])
            div(class: "dv-actions") do
              span(class: "dv-code-chip") { "tyrion discover #{d['id']}" }
            end
          end
        end
      end
    end

    POLL_INTERVAL_MS = 30_000

    # Live polling, reload-on-change — same pattern as active_story.rb's
    # /api/poll badge, scoped to the /discoveries index only (see this
    # story's scope note: the per-discovery show page is a separate story).
    # Reuses active_story.rb's #poll-badge/#poll-dot ids (each page has its
    # own DOM, so no collision) so shared.css's fade-in/pulse animations
    # apply here for free instead of needing their own copy.
    def render_monitor_badge
      div(id: "poll-badge",
          style: "position:fixed;bottom:16px;right:16px;background:rgba(20,16,10,.88);border:1px solid rgba(180,140,80,.35);border-radius:20px;padding:6px 14px;display:flex;align-items:center;gap:6px;font-size:12px;font-family:'IBM Plex Mono',monospace;color:var(--amber-dim);z-index:900;backdrop-filter:blur(4px);cursor:default;user-select:none;",
          data: { project: @project['slug'], token: @token }) do
        span(id: "poll-dot", style: "width:7px;height:7px;border-radius:50%;background:var(--amber);display:inline-block;") {}
        span(id: "poll-label") { "monitoring" }
      end
    end

    def render_js
      script do
        raw safe(<<~JS)
          (function() {
            var badge = document.getElementById('poll-badge');
            if (!badge) return;
            var slug = badge.dataset.project;
            var dot = document.getElementById('poll-dot');
            var label = document.getElementById('poll-label');
            // Seeded from the page's own render (same reason /ambient seeds its
            // token) -- no null-sentinel bootstrap branch, and a stray falsy
            // token from a 404 poll response is simply ignored below rather
            // than latching and wedging the poller open.
            var knownToken = badge.dataset.token || null;
            var INTERVAL = #{POLL_INTERVAL_MS};

            function poll() {
              fetch('/api/discoveries_poll?project=' + encodeURIComponent(slug))
                .then(function(r) { if (!r.ok) throw new Error('poll'); return r.json(); })
                .then(function(data) {
                  dot.style.background = 'var(--amber)';
                  if (data.token && data.token !== knownToken) {
                    knownToken = data.token;
                    label.textContent = 'updating…';
                    setTimeout(function() { window.location.reload(); }, 400);
                  } else {
                    label.textContent = 'monitoring';
                  }
                })
                .catch(function() {
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
