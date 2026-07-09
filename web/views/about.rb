# frozen_string_literal: true

module Views
  class AboutView < Phlex::HTML
    def initialize(project:, epic:, stories:, disc_summary:, epic_switcher: [], git_branch: 'main', dirty_count: 0)
      @project = project; @epic = epic; @stories = stories; @disc_summary = disc_summary
      @epic_switcher = epic_switcher
      @git_branch = git_branch; @dirty_count = dirty_count
    end

    def view_template
      render Views::Layout.new(project: @project, epic: @epic, stories: @stories,
                                disc_summary: @disc_summary, epic_switcher: @epic_switcher, active_tab: :about,
                                git_branch: @git_branch, dirty_count: @dirty_count) do
        div(class: "main-content visible", id: "s-about") do
          div(class: "ab-outer") do
            div(class: "ab-ledger") do
              div(class: "rm-worn-edge")
              div(class: "rm-wax") { "T" }
              div(class: "rm-content") do
                div(class: "rm-eyebrow") { "Tyrion Codex" }
                h1(class: "rm-title") { "What is Tyrion?" }
                div(class: "rm-ornament")

                div(class: "ab-inset") do
                  plain "A "
                  strong { "resumability ledger" }
                  plain " for coding agents. It answers one question: "
                  em { '"What exact story was I implementing, what is done, what did I learn, and what should the next fresh agent do first?"' }
                  plain " The web UI gives you the same answer without opening a terminal."
                end

                div(class: "ab-section-label") { "Hierarchy" }
                div(class: "ab-hierarchy") do
                  raw safe(<<~HTML)
                    <span style="color:var(--ink);font-weight:500">Project</span>  &nbsp;=&nbsp; one conceptual unit, bound to a repo<br>
                    &nbsp;&nbsp;<span style="color:var(--ink-muted)">└─</span> <span style="color:var(--ink);font-weight:500">Epic</span>  &nbsp;&nbsp;&nbsp;=&nbsp; one <code>.feature</code> file — a theme of work<br>
                    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<span style="color:var(--ink-muted)">└─</span> <span style="color:var(--ink);font-weight:500">Story</span>  &nbsp;&nbsp;=&nbsp; one implementable unit (a Scenario)<br>
                    &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<span style="color:var(--ink-muted)">└─</span> <span style="color:var(--ink);font-weight:500">Criterion</span> = one Given/When/Then — definition of done
                  HTML
                end

                div(class: "ab-section-label") { "Glossary" }
                table(class: "ab-table") do
                  tbody do
                    [
                      ["Project", "A conceptual unit of work. Has an ABOUT.md. One project per repo is common."],
                      ["Epic", "One .feature file — a batch of related stories. Multiple epics can be in flight per project."],
                      ["Story", "One implementable unit — a Scenario. Only one story per epic is in_progress at a time."],
                      ["Criterion", "One Given/When/Then assertion. Evidence must be verbatim (pasted output, not paraphrase)."],
                      ["Discovery", "An observation or spike. States: mark → active_spike → findings_ready → promoted_to_story."],
                      ["Mark", "A raw unformalized observation. tyrion mark \"observation\" to capture."],
                    ].each do |term, defn|
                      tr do
                        td(class: "ab-term") { term }
                        td(class: "ab-def") { defn }
                      end
                    end
                  end
                end

                div(class: "ab-section-label") { "Quick CLI Reference" }
                div(class: "ab-cli-block") do
                  raw safe(<<~HTML)
                    <div class="ab-cli-section">Orient</div>
                    <code>tyrion status</code> &nbsp;—&nbsp; plan view: all stories, what's done, what's next<br>
                    <code>tyrion resume &lt;slug&gt;</code> &nbsp;—&nbsp; full context dump for a fresh agent<br>
                    <code>tyrion show &lt;slug&gt;</code> &nbsp;—&nbsp; story detail: intent + criteria + notes
                    <div class="ab-cli-section">Progress</div>
                    <code>tyrion note &lt;slug&gt; progress "..."</code> &nbsp;—&nbsp; add a progress note<br>
                    <code>tyrion check &lt;slug&gt; &lt;N&gt; "evidence"</code> &nbsp;—&nbsp; mark criterion N done<br>
                    <code>tyrion next &lt;slug&gt; "next action"</code> &nbsp;—&nbsp; update next action<br>
                    <code>tyrion done &lt;slug&gt; "summary"</code> &nbsp;—&nbsp; close the story
                    <div class="ab-cli-section">Discoveries</div>
                    <code>tyrion mark "observation"</code> &nbsp;—&nbsp; capture a raw mark<br>
                    <code>tyrion discover disc-NNN</code> &nbsp;—&nbsp; formalize a mark into a discovery<br>
                    <code>tyrion spike start "question?"</code> &nbsp;—&nbsp; start an investigation spike<br>
                    <code>tyrion spike promote disc-NNN</code> &nbsp;—&nbsp; promote finding to a story
                  HTML
                end
              end
            end
          end
        end
      end
    end
  end
end
