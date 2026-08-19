# frozen_string_literal: true

module Views
  class DiscoveriesView < Phlex::HTML
    def initialize(project:, spike:, findings_ready:, marks:, epic:, stories:, disc_summary:, epic_switcher: [], git_branch: 'main', dirty_count: 0, project_slug: nil)
      @project = project; @spike = spike; @findings_ready = findings_ready; @marks = marks
      @epic = epic; @stories = stories; @disc_summary = disc_summary
      @epic_switcher = epic_switcher
      @git_branch = git_branch; @dirty_count = dirty_count; @project_slug = project_slug
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
      end
    end

    private

    def render_origin(disc)
      tag = TyrionWeb::Presenter.origin_tag(disc['origin'])
      span(class: tag[:css]) { tag[:text] }
    end

    def render_spike_section
      div(class: "dv-section") do
        div(class: "dv-section-header") do
          div(class: "dv-mini-seal spike") { "⚗" }
          div(class: "dv-section-title") { "active_spike — 1 in flight" }
        end
        div(class: "dv-card spike", id: @spike['id']) do
          div(class: "dv-card-id") do
            plain "#{@spike['id']} · started #{TyrionWeb::Presenter.time_ago(@spike['created_at'])}"
            render_origin(@spike)
          end
          div(class: "dv-card-q") { "\"#{@spike['question']}\"" }
          div(class: "dv-card-meta") do
            plain "Hypothesis: #{@spike['hypothesis']}" if @spike['hypothesis']
            br if @spike['hypothesis'] && @spike['exit_criteria']
            plain "Exit criteria: #{@spike['exit_criteria']}" if @spike['exit_criteria']
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
          age_days = d['created_at'] ? ((Time.now - Time.parse(d['created_at'])) / 86400).round : 0
          aging = age_days >= 3
          div(class: "dv-card ready", id: d['id']) do
            div(class: "dv-card-id") do
              plain "#{d['id']} · found #{TyrionWeb::Presenter.time_ago(d['created_at'])}"
              render_origin(d)
              span(class: "dv-aging-badge") { " ⚠ aging" } if aging
            end
            div(class: "dv-card-headline") { d['headline'] } if d['headline']
            div(class: "dv-card-q") { "\"#{d['question']}\"" }
            div(class: "dv-card-meta") do
              plain "Finding: #{d['finding']}" if d['finding']
              br if d['finding'] && d['confidence']
              plain "Confidence: #{d['confidence']} · Recommendation: #{d['recommendation']}" if d['confidence']
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
          # Unrounded so the badge flips at a full 14 days, not at 13.5 like the
          # rounded age findings_ready uses.
          age_days = d['created_at'] ? (Time.now - Time.parse(d['created_at'])) / 86400 : 0
          aging = age_days >= 14
          div(class: "dv-card mark", id: d['id']) do
            div(class: "dv-card-id") do
              plain "#{d['id']} · #{TyrionWeb::Presenter.time_ago(d['created_at'])}"
              render_origin(d)
              span(class: "dv-aging-badge") { " ⚠ aging" } if aging
            end
            div(class: "dv-card-headline") { d['headline'] } if d['headline']
            div(class: "dv-card-q") { "\"#{d['question']}\"" }
            div(class: "dv-actions") do
              span(class: "dv-code-chip") { "tyrion discover #{d['id']}" }
            end
          end
        end
      end
    end
  end
end
