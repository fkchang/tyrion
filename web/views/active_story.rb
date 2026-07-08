# frozen_string_literal: true

module Views
  class ActiveStory < Phlex::HTML
    include Phlex::Rails::Helpers::Routes if defined?(Phlex::Rails)

    RESUME_EXCERPT_LEN  = 60
    NEXT_ACTION_MAX_LEN = 120

    def initialize(project:, epic:, story:, criteria:, notes:, stories:, disc_summary:,
                   git_branch: 'main', dirty_count: 0, flash: nil, active_tab: :active, project_slug: nil)
      @project     = project
      @epic        = epic
      @story       = story
      @criteria    = criteria
      @notes       = notes
      @stories     = stories
      @disc_summary = disc_summary
      @git_branch  = git_branch
      @dirty_count = dirty_count
      @flash       = flash
      @active_tab  = active_tab
      @project_slug = project_slug
      @stale       = story ? TyrionWeb::Presenter.stale?(story['last_note_at']) : false
    end

    def view_template
      render Views::Layout.new(
        project: @project, epic: @epic, stories: @stories,
        disc_summary: @disc_summary, active_tab: @active_tab,
        git_branch: @git_branch, dirty_count: @dirty_count, project_slug: @project_slug
      ) do
        div(class: "main-content visible", id: "s-active") do
          div(class: "as-outer") do
            render_attention_rail
            div(class: "as-scroll") do
              render_flash if @flash
              render_nudges
              render_parchment
            end
            render_resume_strip if @story
          end
        end
        render_monitor_badge if @story && @story['status'] == 'in_progress'
        render_js
      end
    end

    private

    def render_attention_rail
      items = []
      if @story && @stale && @story['status'] == 'in_progress'
        items << { type: :stale, label: "⚡ #{@story['slug']} — #{TyrionWeb::Presenter.stale_label(@story['last_note_at'])}" }
      end

      if items.any?
        div(class: "as-attention-rail") do
          span(class: "rail-label") { "⚠ Needs attention" }
          items.each do |item|
            span(class: "rail-item stale") { item[:label] }
          end
        end
      end
    end

    def render_flash
      div(style: "background:rgba(22,163,74,.15);border:1px solid rgba(22,163,74,.3);padding:8px 14px;border-radius:6px;font-size:13px;color:#16a34a;margin-bottom:8px;") do
        plain @flash
      end
    end

    def render_nudges
      return unless @story && @story['status'] == 'in_progress'
      nudges = []
      nudges << { field: 'next_action', msg: "Next Action is missing — agent won't know where to resume.", cmd: "tyrion next #{@story['slug']} \"...\"" } if @story['next_action'].to_s.strip.empty?
      nudges << { field: 'current_context', msg: "Current Context is missing — agent will start cold.", cmd: "tyrion context #{@story['slug']} \"...\"" } if @story['current_context'].to_s.strip.empty?
      return if nudges.empty?

      div(class: "as-nudge-block") do
        nudges.each do |n|
          div(class: "as-nudge") do
            span(class: "nudge-icon") { "⚠" }
            div(class: "nudge-body") do
              span(class: "nudge-msg") { n[:msg] }
              code(class: "nudge-cmd") { n[:cmd] }
            end
          end
        end
      end
    end

    def render_parchment
      div(class: "as-parchment") do
        render_hero
        render_intent_block
        render_context_block
        render_next_action_block
        render_split
        render_cmd_strip
      end
    end

    def render_hero
      if @story
        status = @story['status'] || 'pending'
        badge_css = TyrionWeb::Presenter.story_status(status)[:css]

        if @active_tab != :active
          a(href: "/warroom", style: "display:inline-block;font-size:12px;font-family:'IBM Plex Mono',monospace;color:var(--ink-faint);text-decoration:none;margin-bottom:12px;opacity:.7;") do
            plain "← War Room"
          end
        end

        div(class: "as-hero-status") do
          span(class: "status-badge #{badge_css}") do
            span(class: "dot")
            plain status
          end
          if @story['last_note_at']
            span(style: "font-size:13px;color:var(--ink-muted)") do
              plain "last note #{TyrionWeb::Presenter.time_ago(@story['last_note_at'])}"
            end
          end
        end
        div(class: "as-hero-title") { @story['slug'] }
        if @story['title'] && @story['title'] != @story['slug']
          div(style: "font-size:16px;color:var(--ink-dim);margin:-6px 0 12px;font-family:'Lora',serif;font-style:italic;") { @story['title'] }
        end
      else
        no_story_state
      end
    end

    def render_intent_block
      return unless @story
      intent = @story['intent']&.strip
      return if intent.nil? || intent.empty?

      div(style: "background:rgba(180,140,80,.08);border-left:3px solid rgba(180,140,80,.35);border-radius:0 6px 6px 0;padding:10px 14px;margin-bottom:14px;") do
        div(style: "font-size:10px;font-family:'IBM Plex Mono',monospace;color:var(--ink-faint);letter-spacing:.1em;margin-bottom:6px;") { "MISSION BRIEF" }
        intent.split("\n").each do |line|
          line = line.strip
          next if line.empty?
          div(style: "font-family:'Lora',serif;font-size:14px;color:var(--ink-dim);font-style:italic;line-height:1.6;") { plain line }
        end
      end
    end

    def no_story_state
      div(style: "text-align:center;padding:48px 0;") do
        div(style: "font-size:48px;margin-bottom:16px;opacity:.3") { "⚡" }
        div(style: "font-family:'Cinzel',serif;font-size:20px;color:var(--ink-dim);margin-bottom:8px;") do
          plain @epic ? "No story in progress" : "No active project"
        end
        div(style: "font-size:14px;color:var(--ink-faint);") do
          if @epic
            next_pending = @stories.find { |s| s['status'] == 'pending' }
            if next_pending
              div(style: "margin-bottom:6px;") do
                plain "Next up: "
                span(style: "font-family:'IBM Plex Mono',monospace;color:var(--amber-dim);") { next_pending['slug'] }
              end
              div(style: "font-family:'IBM Plex Mono',monospace;font-size:13px;color:var(--amber);margin-bottom:4px;") { "/tyrion-implement" }
              div(style: "font-size:12px;color:var(--text-faint);") { "or: tyrion start #{next_pending['slug']}" }
            else
              plain "/tyrion-implement"
            end
          else
            plain "Run: tyrion project activate <slug>"
          end
        end
      end
    end

    def render_context_block
      return unless @story
      div(class: "as-block") do
        div(class: "as-block-label") { "Current Context" }
        div(style: "font-size:11px;font-family:'IBM Plex Mono',monospace;color:var(--ink-faint);margin-top:-3px;margin-bottom:5px;") { "set by implementing agent" }
        form(action: "/stories/#{@story['id']}/context", method: "post") do
          if !@story['current_context'].to_s.strip.empty?
            div(class: "as-block-text", id: "ctx-display",
                data: { action: "show-ctx-edit" },
                style: "cursor:pointer;") do
              plain @story['current_context']
            end
          else
            div(class: "as-block-text", id: "ctx-display",
                data: { action: "show-ctx-edit" },
                style: "cursor:pointer;color:var(--ink-faint);font-style:italic;") do
              plain "(none — click to edit)"
            end
          end
          div(id: "ctx-form", style: "display:none;") do
            textarea(name: "text", rows: "3",
                     style: "width:100%;background:rgba(255,255,255,.5);border:1px solid var(--ink-faint);border-radius:4px;padding:6px 8px;font-size:14px;font-family:'Lora',serif;resize:vertical;") do
              plain @story['current_context'].to_s
            end
            div(style: "display:flex;gap:8px;margin-top:6px;") do
              button(type: "submit", style: "background:var(--ink);color:var(--parchment);border:none;padding:4px 12px;border-radius:4px;font-size:12px;cursor:pointer;") { "Save" }
              button(type: "button",
                     data: { action: "cancel-ctx-edit" },
                     style: "background:transparent;border:1px solid var(--ink-faint);color:var(--ink-dim);padding:4px 12px;border-radius:4px;font-size:12px;cursor:pointer;") { "Cancel" }
            end
          end
        end
      end
    end

    def render_next_action_block
      return unless @story
      div(class: "as-block") do
        div(class: "as-block-label") { "Next Action" }
        div(style: "font-size:11px;font-family:'IBM Plex Mono',monospace;color:var(--ink-faint);margin-top:-3px;margin-bottom:5px;") { "agent sets this before handing off" }
        form(action: "/stories/#{@story['id']}/next_action", method: "post") do
          if !@story['next_action'].to_s.strip.empty?
            div(class: "as-block-text", id: "na-display",
                data: { action: "show-na-edit" },
                style: "cursor:pointer;") do
              plain @story['next_action']
            end
          else
            div(class: "as-block-text", id: "na-display",
                data: { action: "show-na-edit" },
                style: "cursor:pointer;color:var(--ink-faint);font-style:italic;") do
              plain "(none — click to edit)"
            end
          end
          div(id: "na-form", style: "display:none;") do
            input(type: "text", name: "text",
                  value: @story['next_action'].to_s,
                  style: "width:100%;background:rgba(255,255,255,.5);border:1px solid var(--ink-faint);border-radius:4px;padding:6px 8px;font-size:14px;font-family:'Lora',serif;")
            div(style: "display:flex;gap:8px;margin-top:6px;") do
              button(type: "submit", style: "background:var(--ink);color:var(--parchment);border:none;padding:4px 12px;border-radius:4px;font-size:12px;cursor:pointer;") { "Save" }
              button(type: "button",
                     data: { action: "cancel-na-edit" },
                     style: "background:transparent;border:1px solid var(--ink-faint);color:var(--ink-dim);padding:4px 12px;border-radius:4px;font-size:12px;cursor:pointer;") { "Cancel" }
            end
          end
        end
      end
    end

    def render_split
      return unless @story
      div(class: "as-split") do
        div do
          div(class: "as-block-label", style: "margin-bottom:8px") { "Criteria" }
          if @criteria.any?
            @criteria.each do |c|
              is_met = c['status'] == 'met'
              div(class: is_met ? "as-crit-row done" : "as-crit-row") do
                form(action: "/stories/#{@story['id']}/criteria/#{c['position']}/#{is_met ? 'uncheck' : 'check'}",
                     method: "post", style: "display:contents;") do
                  button(type: "submit", style: "background:none;border:none;padding:0;cursor:pointer;") do
                    div(class: is_met ? "crit-check checked" : "crit-check")
                  end
                  div(class: "crit-text") { c['text'] }
                end
              end
            end
          else
            div(style: "font-size:13px;color:var(--ink-faint);font-style:italic;") { "No criteria yet" }
          end
        end

        div(style: "display:flex;flex-direction:column;") do
          div(class: "as-block-label", style: "margin-bottom:8px") { "Notes" }
          @notes.each do |note|
            div(class: TyrionWeb::Presenter.note_kind_css(note['kind'])) do
              div(class: "note-meta") { "#{note['kind']} · #{TyrionWeb::Presenter.time_ago(note['created_at'])}" }
              div(class: "note-body", data: { action: "expand-note" }) { note['body'] }
            end
          end

          div(class: "as-quick-note", style: "margin-top:auto;") do
            form(action: "/stories/#{@story['id']}/notes", method: "post",
                 style: "display:flex;gap:6px;width:100%;") do
              input(id: "qnote", type: "text", name: "body",
                    placeholder: "progress note + Enter…",
                    style: "flex:1;",
                    autocomplete: "off")
              button(type: "submit") { "Note" }
            end
          end
        end
      end
    end

    def render_cmd_strip
      return unless @story
      slug = @story['slug']
      div(class: "as-cmd-strip") do
        div(class: "as-cmd-toggle", data: { action: "toggle-cmd" }) do
          plain "› Quick commands for #{slug}"
        end
        div(class: "as-cmd-body", style: "display:none;") do
          [
            "tyrion note #{slug} progress \"...\"",
            "tyrion check #{slug} N \"evidence...\"",
            "tyrion next #{slug} \"next action\"",
            "tyrion context #{slug} \"current state...\"",
            "tyrion done #{slug} \"summary\""
          ].each do |cmd|
            span(class: "as-cmd-chip") { cmd }
          end
        end
      end
    end

    def render_resume_strip
      last_note = @notes.first
      div(class: "as-resume-strip") do
        div(class: "as-rs-panel") do
          div(class: "as-rs-label") { "LAST NOTE" }
          div(class: "as-rs-text") do
            if last_note
              body = last_note['body'].to_s
              excerpt = body.length > RESUME_EXCERPT_LEN ? "#{body.slice(0, RESUME_EXCERPT_LEN)}…" : body
              plain "#{TyrionWeb::Presenter.time_ago(last_note['created_at'])} — \"#{excerpt}\""
            else
              plain "no notes yet"
            end
          end
        end
        div(class: "as-rs-panel as-rs-beacon") do
          img(src: "/assets/lantern.png", alt: "beacon", class: "as-beacon-img")
          div do
            div(class: "as-rs-label") { "RESUME POINT" }
            div(class: "as-rs-text") do
              plain "#{@story['slug']}"
              met_count = @criteria.count { |c| c['status'] == 'met' }
              plain " · #{met_count}/#{@criteria.size} criteria met" if @criteria.any?
            end
          end
        end
        div(class: "as-rs-panel") do
          div(class: "as-rs-label") { "NEXT ACTION" }
          div(class: "as-rs-text") do
            na = @story['next_action']&.strip
            if na && na.length > 0
              plain na.length > NEXT_ACTION_MAX_LEN ? "#{na.slice(0, NEXT_ACTION_MAX_LEN)}…" : na
            else
              plain "(not set)"
            end
          end
        end
      end
    end

    def render_monitor_badge
      story_id = @story['id']
      div(id: "poll-badge",
          style: "position:fixed;bottom:16px;right:16px;background:rgba(20,16,10,.88);border:1px solid rgba(180,140,80,.35);border-radius:20px;padding:6px 14px;display:flex;align-items:center;gap:6px;font-size:12px;font-family:'IBM Plex Mono',monospace;color:var(--amber-dim);z-index:900;backdrop-filter:blur(4px);cursor:default;user-select:none;",
          data: { story_id: story_id }) do
        span(id: "poll-dot", style: "width:7px;height:7px;border-radius:50%;background:var(--amber);display:inline-block;") {}
        span(id: "poll-label") { "monitoring" }
      end
    end

    def render_js
      script do
        raw safe(<<~JS)
          document.addEventListener('click', function(e) {
            var t = e.target.closest('[data-action]');
            if (!t) return;
            var action = t.dataset.action;
            if (action === 'show-ctx-edit') {
              document.getElementById('ctx-display').style.display = 'none';
              document.getElementById('ctx-form').style.display = 'block';
            } else if (action === 'cancel-ctx-edit') {
              document.getElementById('ctx-form').style.display = 'none';
              document.getElementById('ctx-display').style.display = 'block';
            } else if (action === 'show-na-edit') {
              document.getElementById('na-display').style.display = 'none';
              document.getElementById('na-form').style.display = 'block';
            } else if (action === 'cancel-na-edit') {
              document.getElementById('na-form').style.display = 'none';
              document.getElementById('na-display').style.display = 'block';
            } else if (action === 'toggle-cmd') {
              var b = t.nextElementSibling;
              b.style.display = b.style.display === 'none' ? 'flex' : 'none';
            } else if (action === 'expand-note') {
              t.classList.toggle('expanded');
            }
          });

          // Live polling — reload on any change to story token
          (function() {
            var badge = document.getElementById('poll-badge');
            if (!badge) return;
            var storyId = badge.dataset.storyId;
            var dot = document.getElementById('poll-dot');
            var label = document.getElementById('poll-label');
            var knownToken = null;
            var lastCheckAt = Date.now();
            var INTERVAL = 30000;

            function ago(ms) {
              var s = Math.round(ms / 1000);
              if (s < 60) return s + 's ago';
              return Math.round(s / 60) + 'm ago';
            }

            function poll() {
              fetch('/api/poll?story_id=' + encodeURIComponent(storyId))
                .then(function(r) { return r.json(); })
                .then(function(data) {
                  lastCheckAt = Date.now();
                  dot.style.background = 'var(--amber)';
                  if (knownToken === null) {
                    knownToken = data.token;
                    label.textContent = 'monitoring · just checked';
                  } else if (data.token !== knownToken) {
                    label.textContent = 'updating…';
                    setTimeout(function() { window.location.reload(); }, 400);
                  } else {
                    label.textContent = 'monitoring · just checked';
                  }
                })
                .catch(function() {
                  dot.style.background = '#666';
                  label.textContent = 'offline';
                });
            }

            poll();
            setInterval(function() {
              poll();
            }, INTERVAL);

            setInterval(function() {
              if (knownToken !== null) {
                label.textContent = 'monitoring · ' + ago(Date.now() - lastCheckAt);
              }
            }, 5000);
          })();
        JS
      end
    end
  end
end
