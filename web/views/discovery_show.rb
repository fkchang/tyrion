# frozen_string_literal: true

module Views
  # The dedicated per-discovery page (design: docs/superpowers/specs/2026-08-18-...).
  # Earns its own URL for two things the ambient/inline-expand card can't do well:
  # real form fields (a defer reason, an editable promote title + epic picker) and
  # a stable address every other surface (ambient, status, discovery search) can
  # link to consistently.
  class DiscoveryShow < Phlex::HTML
    def initialize(project:, epic:, discovery:, epics:, stories:, disc_summary:, epic_switcher: [],
                    git_branch: 'main', dirty_count: 0, flash: nil, sidebar_epic: nil, child_marks: [])
      @project = project; @epic = epic; @discovery = discovery; @epics = epics
      @stories = stories; @disc_summary = disc_summary; @epic_switcher = epic_switcher
      @git_branch = git_branch; @dirty_count = dirty_count; @flash = flash
      @sidebar_epic = sidebar_epic || epic
      @child_marks = child_marks
    end

    def view_template
      # Layout gets @sidebar_epic (falls back to the active epic when this
      # discovery has none of its own), NOT @epic -- the content below uses
      # @epic directly so it never claims an epic the discovery doesn't have.
      render Views::Layout.new(project: @project, epic: @sidebar_epic, stories: @stories,
                                disc_summary: @disc_summary, epic_switcher: @epic_switcher, active_tab: :discoveries,
                                git_branch: @git_branch, dirty_count: @dirty_count,
                                project_slug: @project && @project['slug']) do
        div(class: "main-content visible") do
          div(class: "dv-outer") do
            div(class: "dv-ledger") do
              div(class: "rm-worn-edge")
              div(class: "rm-content") do
                div(class: "rm-eyebrow") { "Findings Scroll" }
                if @flash
                  div(style: "margin-bottom:16px;padding:10px 14px;background:var(--surface-2);border:1px solid var(--border-2);border-radius:4px;color:var(--text)") { @flash }
                end
                a(href: discoveries_url, style: "font-size:13px;color:var(--ink-faint);text-decoration:none") { "← Back to Discoveries" }
                div(style: "height:12px")
                render_card
              end
            end
          end
        end
      end
    end

    private

    def discoveries_url
      @project ? "/discoveries?project=#{@project['slug']}" : "/discoveries"
    end

    def render_card
      d = @discovery
      div(class: "dv-card #{d['status']}") do
        div(class: "dv-card-id") do
          plain "#{d['id']} · #{d['status']} · #{TyrionWeb::Presenter.time_ago(d['created_at'])}"
          render_origin
        end
        div(class: "dv-card-headline") { d['headline'] } if d['headline']
        div(class: "dv-card-q dv-md") { raw(safe(TyrionWeb::Presenter.markdown_lite(d['question']))) }
        render_fields
        render_epic_line
        render_child_marks if @child_marks.any?
        div(style: "height:20px")
        render_actions
      end
    end

    def render_origin
      tag = TyrionWeb::Presenter.origin_tag(@discovery['origin'])
      span(class: tag[:css]) { tag[:text] }
    end

    # Every field beyond question/headline, each on its own presence -- a
    # discovery can carry a recommendation without a confidence rating (or a
    # verdict without a finding), and this page's whole job is showing the
    # full record, so no field is gated behind another. This is the same
    # field set Commands.cmd_discovery_show prints for the CLI (plus
    # `verdict`, this epic's addition, and nested marks). `verdict` has no
    # column yet -- landing via a sibling story in parallel -- so it reads as
    # nil and is skipped until that story merges, same as any other unset
    # field. Markdown is interpreted for the free-text fields; confidence is
    # a short label, not prose, so it renders plain.
    def render_fields
      render_field('Confidence', @discovery['confidence'], markdown: false)
      render_field('Hypothesis', @discovery['hypothesis'])
      render_field('Exit criteria', @discovery['exit_criteria'])
      render_field('Finding', @discovery['finding'])
      render_field('Recommendation', @discovery['recommendation'])
      render_field('Verdict', @discovery['verdict'])
      render_field('Defer reason', @discovery['defer_reason'])
    end

    def render_field(label, text, markdown: true)
      return unless text && !text.to_s.strip.empty?

      div(class: "dv-card-meta", style: "margin-top:10px") do
        div(style: field_label_style) { label }
        if markdown
          div(class: "dv-md") { raw(safe(TyrionWeb::Presenter.markdown_lite(text))) }
        else
          plain text
        end
      end
    end

    def field_label_style
      "font-weight:600;color:var(--ink-faint);font-size:12px;text-transform:uppercase;" \
        "letter-spacing:.04em;margin-bottom:2px"
    end

    # Marks filed while this discovery was the project's active_spike
    # (parent_spike_id) -- nested here instead of the flat /discoveries index,
    # which excludes them for the same reason (see load_discoveries_view).
    def render_child_marks
      div(style: "margin-top:16px;padding-top:14px;border-top:1px solid var(--border-2)") do
        div(style: field_label_style + ";margin-bottom:8px") { "Marks filed under this spike (#{@child_marks.size})" }
        @child_marks.each { |m| render_child_mark(m) }
      end
    end

    def render_child_mark(m)
      div(style: "padding:8px 0;border-bottom:1px solid var(--border-2)") do
        div(style: "font-size:12px;color:var(--ink-faint);margin-bottom:2px") do
          plain "#{m['id']} · #{TyrionWeb::Presenter.time_ago(m['created_at'])}"
        end
        a(href: "/discoveries/#{m['id']}", style: "color:var(--ink);text-decoration:none;font-size:13px") do
          plain Tyrion::Output.discovery_glance_text(m)
        end
      end
    end

    def render_epic_line
      div(style: "font-size:13px;color:var(--ink-faint);margin-top:6px") do
        if @epic
          plain "Epic: #{@epic['slug']}"
        else
          plain "Epic: none — filed as a standalone observation"
        end
      end
    end

    DEFERRABLE = %w[mark findings_ready].freeze

    def render_actions
      status = @discovery['status']
      div(class: "dv-actions", style: "flex-direction:column;align-items:flex-start;gap:20px") do
        render_defer_form if DEFERRABLE.include?(status)
        render_promote_form if status == 'findings_ready'
        render_headline_form
      end
    end

    def render_defer_form
      div do
        div(style: "font-weight:600;margin-bottom:6px") { "Defer" }
        form(method: "post", action: "/discoveries/#{@discovery['id']}/defer") do
          input(type: "text", name: "reason", placeholder: "Reason (optional)", style: form_input_style)
          button(type: "submit", class: "dv-code-chip", style: "cursor:pointer") { "Defer" }
        end
      end
    end

    def render_promote_form
      div do
        div(style: "font-weight:600;margin-bottom:6px") { "Promote to story" }
        if @epics.empty?
          div(style: "font-size:13px;color:var(--ink-faint)") { "No epics in this project yet — create one first." }
        else
          form(method: "post", action: "/discoveries/#{@discovery['id']}/promote") do
            select(name: "epic_slug", style: form_input_style) do
              @epics.each { |e| option(value: e['slug']) { e['slug'] } }
            end
            input(type: "text", name: "title", value: @discovery['question'], style: form_input_style)
            button(type: "submit", class: "dv-code-chip", style: "cursor:pointer") { "Promote" }
          end
        end
      end
    end

    def render_headline_form
      div do
        div(style: "font-weight:600;margin-bottom:6px") { "Headline (shown on ambient, status, and list glance views)" }
        form(method: "post", action: "/discoveries/#{@discovery['id']}/headline") do
          input(type: "text", name: "headline", value: @discovery['headline'], placeholder: @discovery['question'],
                style: form_input_style + ";min-width:360px")
          button(type: "submit", class: "dv-code-chip", style: "cursor:pointer") { "Save" }
        end
      end
    end

    def form_input_style
      "padding:6px 10px;margin-right:8px;border:1px solid var(--border-2);border-radius:4px;" \
        "background:var(--surface);color:var(--text);font-family:var(--font-mono);font-size:13px"
    end
  end
end
