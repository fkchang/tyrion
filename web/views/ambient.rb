# frozen_string_literal: true

module Views
  # Standalone ambient status page — deliberately NOT wrapped in Views::Layout.
  # It lives in a 300-360px browser pane split alongside a terminal, so navbar
  # and sidebar chrome would be width the marks can't use, and any story /
  # criteria / git detail would be something to read rather than glance at.
  class Ambient < Phlex::HTML
    AGING_DAYS  = 14   # same threshold as the Discoveries marks aging badge
    TRUNCATE_AT = 140

    def initialize(project:, marks: [], findings_ready_count: 0)
      @project              = project
      @marks                = marks || []
      @findings_ready_count = findings_ready_count.to_i
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
        body do
          if @project.nil?
            div(class: "am-empty") { "no project" }
          else
            div(class: "am-project") { @project['slug'] || @project['name'] || '' }
            render_marks
            render_ready_line
          end
        end
      end
    end

    private

    # Zero open marks blanks this section only — the findings_ready line below
    # still renders, so the pane never goes fully dark on a half-empty state.
    def render_marks
      @marks.each do |m|
        div(class: aged?(m) ? "am-mark aged" : "am-mark") do
          div(class: "am-mark-q") { truncate(m['question'].to_s) }
          div(class: "am-mark-meta") { "#{m['id']} · #{TyrionWeb::Presenter.time_ago(m['created_at'])}" }
        end
      end
    end

    def render_ready_line
      div(class: "am-ready") do
        "#{@findings_ready_count} findings ready"
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
