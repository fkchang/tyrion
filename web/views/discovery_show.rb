# frozen_string_literal: true

module Views
  # The dedicated per-discovery page (design: docs/superpowers/specs/2026-08-18-...).
  # Earns its own URL for two things the ambient/inline-expand card can't do well:
  # real form fields (a defer reason, an editable promote title + epic picker) and
  # a stable address every other surface (ambient, status, discovery search) can
  # link to consistently.
  class DiscoveryShow < Phlex::HTML
    def initialize(project:, epic:, discovery:, epics:, stories:, disc_summary:, epic_switcher: [],
                    git_branch: 'main', dirty_count: 0, flash: nil, sidebar_epic: nil)
      @project = project; @epic = epic; @discovery = discovery; @epics = epics
      @stories = stories; @disc_summary = disc_summary; @epic_switcher = epic_switcher
      @git_branch = git_branch; @dirty_count = dirty_count; @flash = flash
      @sidebar_epic = sidebar_epic || epic
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
          render_verdict
        end
        div(class: "dv-card-headline") { d['headline'] } if d['headline']
        div(class: "dv-card-q") { "\"#{d['question']}\"" }
        render_findings if d['finding'] || d['recommendation']
        render_epic_line
        div(style: "height:20px")
        render_actions
      end
    end

    def render_origin
      tag = TyrionWeb::Presenter.origin_tag(@discovery['origin'])
      span(class: tag[:css]) { tag[:text] }
    end

    # nil (unscored) renders nothing -- same "nothing honest to show" rule the
    # Discoveries list view follows via TyrionWeb::Presenter.verdict_tag.
    def render_verdict
      tag = TyrionWeb::Presenter.verdict_tag(@discovery['verdict'])
      return unless tag

      span(class: tag[:css]) { tag[:text] }
    end

    # Each field rendered on its own presence -- recommendation in particular
    # must not be gated behind confidence being set. A discovery can carry a
    # recommendation without a confidence rating, and this page's whole job is
    # showing the full record; hiding the most actionable field behind an
    # unrelated null check defeated that.
    def render_findings
      lines = []
      lines << "Finding: #{@discovery['finding']}" if @discovery['finding']
      lines << "Confidence: #{@discovery['confidence']}" if @discovery['confidence']
      lines << "Recommendation: #{@discovery['recommendation']}" if @discovery['recommendation']

      div(class: "dv-card-meta") do
        lines.each_with_index do |line, i|
          br if i.positive?
          plain line
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
