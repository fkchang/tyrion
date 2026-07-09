# frozen_string_literal: true

module Views
  class NotFoundView < Phlex::HTML
    def initialize(message:, project:, epic:, stories: [], disc_summary: {}, epic_switcher: [], git_branch: 'main', dirty_count: 0)
      @message     = message
      @project     = project
      @epic        = epic
      @stories     = stories
      @disc_summary = disc_summary
      @epic_switcher = epic_switcher
      @git_branch  = git_branch
      @dirty_count = dirty_count
    end

    def view_template
      render Views::Layout.new(
        project: @project, epic: @epic, stories: @stories,
        disc_summary: @disc_summary, epic_switcher: @epic_switcher, active_tab: nil,
        git_branch: @git_branch, dirty_count: @dirty_count
      ) do
        div(class: "main-content visible") do
          div(style: "text-align:center;padding:80px 24px;") do
            div(style: "font-size:64px;opacity:.25;margin-bottom:20px;") { "⚔" }
            div(style: "font-family:'Cinzel',serif;font-size:22px;color:var(--gold-bright);margin-bottom:12px;") { "Not Found" }
            div(style: "font-size:15px;color:var(--ink-muted);margin-bottom:28px;") { @message }
            a(href: "/warroom",
              style: "font-size:13px;color:var(--gold-bright);border:1px solid var(--gold-dim);padding:6px 16px;border-radius:4px;text-decoration:none;") do
              plain "← Back to War Room"
            end
          end
        end
      end
    end
  end
end
