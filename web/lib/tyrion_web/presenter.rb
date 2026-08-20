# frozen_string_literal: true

require 'cgi'

module TyrionWeb
  module Presenter
    STALE_HOURS = 4

    # Minimal markdown -- not a general renderer. Spike/discovery prose is
    # short free text (question, hypothesis, finding, recommendation), so this
    # covers what that prose actually uses: paragraphs, inline code, bold,
    # italic, and bullet lists. No gem dependency. Every markup char this
    # emits is one it added itself -- there is no path from raw user text to
    # an unescaped tag. Returns a plain String; the caller decides how to mark
    # it safe for its own template engine (e.g. Phlex's `raw(safe(...))`) --
    # this module deals in data, not view-framework types.
    #
    # Blocks (blank-line-separated) are split BEFORE any inline (bold/code)
    # processing, and a list block has its "- "/"* " marker stripped before
    # that processing runs per line -- doing it in the other order (inline
    # pass over the raw block, list-detection after) lets a bullet's own "* "
    # marker pair up with a later "*" on the same line and get swallowed as an
    # emphasis delimiter, silently eating the whole list.
    def self.markdown_lite(text)
      text.to_s.split(/\n{2,}/).reject { |block| block.strip.empty? }
          .map { |block| render_block(block) }.join
    end

    BULLET_RE = /\A[-*]\s+/

    # A block renders as a list only when EVERY line in it is a bullet -- a
    # block mixing prose and bullets is rarer in this discovery/spike prose
    # (short free text) than a stray leading "-" in a sentence, so treating a
    # partial match as a list would misrender more often than it helps.
    # Ordered lists aren't covered -- discovery prose doesn't use them, and
    # scope stays to what's actually asked for (bold, code, lists = bullets).
    def self.render_block(block)
      lines = block.split("\n")
      if lines.all? { |line| line.match?(BULLET_RE) }
        "<ul>#{lines.map { |line| "<li>#{render_inline(line.sub(BULLET_RE, ''))}</li>" }.join}</ul>"
      else
        "<p>#{lines.map { |line| render_inline(line) }.join('<br>')}</p>"
      end
    end
    private_class_method :render_block

    # Escape + bold/italic/code for a single line (never crosses a newline --
    # a physical line is the unit both list items and paragraph lines share).
    # Code spans are pulled out before the bold/italic passes and restored
    # after, so `` `*.rb` `` or `` `a* b*` `` can't have its asterisks read as
    # emphasis markers -- discovery prose is routinely about code (globs,
    # flags), so that collision is the common case, not an edge case. The
    # placeholder uses \0, which CGI.escapeHTML output can never contain, so
    # it can't collide with the source text the way a printable-character
    # marker could.
    def self.render_inline(line)
      spans = []
      escaped = CGI.escapeHTML(line).gsub(/`([^`\n]+)`/) do
        spans << "<code>#{Regexp.last_match(1)}</code>"
        "\0#{spans.size - 1}\0"
      end
      escaped = escaped.gsub(/\*\*([^*\n]+)\*\*/, '<strong>\1</strong>')
                        .gsub(/(?<!\*)\*([^*\n]+)\*(?!\*)/, '<em>\1</em>')
      escaped.gsub(/\0(\d+)\0/) { spans[Regexp.last_match(1).to_i] }
    end
    private_class_method :render_inline

    def self.story_status(status)
      case status
      when 'done'        then { glyph: '✓', css: 'done',        label: 'done' }
      when 'in_progress' then { glyph: '⚡', css: 'in-progress', label: 'in_progress' }
      when 'blocked'     then { glyph: '✗', css: 'blocked',     label: 'blocked' }
      when 'abandoned'   then { glyph: '✗', css: 'abandoned',   label: 'abandoned' }
      else                    { glyph: '·', css: 'pending',     label: 'pending' }
      end
    end

    def self.criterion_glyph(status)
      status == 'met' ? '✓' : ' '
    end

    def self.criterion_met?(row)
      row['status'] == 'met'
    end

    def self.stale?(last_note_at)
      return false unless last_note_at
      (Time.now - Time.parse(last_note_at.to_s)) > STALE_HOURS * 3600
    end

    def self.stale_label(last_note_at)
      return '' unless last_note_at
      hours = ((Time.now - Time.parse(last_note_at.to_s)) / 3600).round
      "⚠ stale #{hours}h ago"
    end

    def self.time_ago(ts)
      return '—' unless ts
      secs = (Time.now - Time.parse(ts.to_s)).to_i
      return 'just now' if secs < 60
      mins = secs / 60
      return "#{mins}m ago" if mins < 60
      hrs = mins / 60
      return "#{hrs}h ago" if hrs < 24
      "#{hrs / 24}d ago"
    end

    def self.note_kind_css(kind)
      "as-note-entry #{kind}"
    end

    def self.criteria_met_count(criteria)
      criteria.count { |c| c['status'] == 'met' }
    end

    # Derive the canonical display state for an epic from its stories + status.
    # `epic` is expected to carry the 'unmet' and 'child_stats' keys that
    # Data.load_roadmap_view decorates from a single epic_graph snapshot
    # (nil/[] are fine for callers that don't have a graph — those epics
    # simply never reach :container or :waiting).
    #
    # Precedence is explicit, not incidental: :sealed outranks :container so
    # a sealed empty container (every child sealed, none of its own stories)
    # reads sealed rather than being mistaken for an empty leaf. :active and
    # :cold outrank :waiting so an epic with live in-progress work still
    # reads active even if one of its prerequisites later regressed — the
    # prerequisite going unmet again doesn't retroactively stop work already
    # underway.
    #
    # Returns { state:, color_css:, glyph:, label:, action:, focus:, archived: }.
    def self.epic_state(epic, stories, active_epic_id)
      in_progress  = stories.select { |s| s['status'] == 'in_progress' }
      done_count   = stories.count  { |s| s['status'] == 'done' }
      blocked_count = stories.count { |s| s['status'] == 'blocked' }
      story_count  = stories.size
      max_note_at  = in_progress.map { |s| s['last_note_at'] }.compact.max
      child_stats  = epic['child_stats']
      unmet        = epic['unmet'] || []

      state =
        if epic['status'] == 'done'
          :sealed
        elsif child_stats && story_count.zero?
          :container
        elsif story_count.zero?
          :empty
        elsif done_count == story_count
          :ready
        elsif in_progress.any? && !stale?(max_note_at)
          :active
        elsif in_progress.any?
          :cold
        elsif epic['status'] == 'active' && unmet.any?
          :waiting
        elsif epic['status'] == 'paused'
          :paused
        elsif blocked_count.positive?
          :blocked
        elsif done_count.positive?
          :started
        else
          :queued
        end

      color_css, glyph, label, action =
        case state
        when :empty     then ['rm-seal future',  nil, 'empty',          :import]
        when :container then ['rm-seal pivot',   '◆', "container · #{child_stats[:done]}/#{child_stats[:total]} sealed", nil]
        when :sealed    then ['rm-seal',          '✓', 'sealed',         nil]
        when :ready     then ['rm-seal ready',    '✦', 'READY TO SEAL',  :seal]
        when :active    then ['rm-seal active',   '●', 'active',         nil]
        when :cold      then ['rm-seal cold',     '⚠', "cold · #{time_ago(max_note_at)}", :resume]
        when :waiting   then ['rm-seal waiting',  '⌛', "waiting — requires: #{Tyrion::Output.unmet_prereqs_text(unmet)}", nil]
        when :paused    then ['rm-seal paused',   '‖', 'paused',         :resume]
        when :blocked   then ['rm-seal blocked',  '✕', "#{blocked_count} blocked", :blocker]
        when :started   then ['rm-seal active',   nil, 'active',         nil]
        when :queued    then ['rm-seal future',   nil, 'queued',         nil]
        end

      {
        state:     state,
        color_css: color_css,
        glyph:     glyph,
        label:     label,
        action:    action,
        focus:     epic['id'] == active_epic_id,
        archived:  !epic['archived_at'].nil?
      }
    end

    def self.epic_seal_css(epic, active_epic_id)
      if epic['status'] == 'done'
        'rm-seal'
      elsif epic['id'] == active_epic_id
        'rm-seal active'
      else
        'rm-seal future'
      end
    end

    # Same [agent]/[human] wording the CLI prints — delegated to Output.origin_label, not
    # re-derived, so the web can never drift out of step with `tyrion status` /
    # `tyrion discovery list`. Uses the uncolored label; origin_tag carries ANSI codes.
    def self.origin_tag(origin)
      css = Tyrion::Output.agent_origin?(origin) ? 'dv-origin agent' : 'dv-origin human'
      { text: Tyrion::Output.origin_label(origin), css: css }
    end

    # Renders orthogonally to status (dv-mini-seal/dv-card already carry that) so a
    # findings_ready card can show "did the hypothesis hold up" without being mistaken
    # for the lifecycle badge. nil (unscored) means no badge at all -- there is nothing
    # honest to show, same reasoning as the CLI's '(unscored)' text.
    def self.verdict_tag(verdict)
      return nil unless verdict

      { text: Tyrion::Output.verdict_label(verdict), css: "dv-verdict dv-verdict-#{verdict.tr('_', '-')}" }
    end

    # Both expect the {spike:, ready_count:, mark_count:} shape
    # Data.load_discovery_summary returns (global-view-discovery-momentum).

    def self.discovery_activity?(disc_summary)
      return true if disc_summary[:spike]
      disc_summary[:ready_count].positive? || disc_summary[:mark_count].positive?
    end

    # One-line summary for a project card that has no epic story activity to
    # describe instead.
    def self.discovery_summary_text(disc_summary)
      parts = []
      parts << 'spike active' if disc_summary[:spike]
      parts << "#{disc_summary[:ready_count]} ready to promote" if disc_summary[:ready_count].positive?
      if disc_summary[:mark_count].positive?
        n = disc_summary[:mark_count]
        parts << "#{n} mark#{'s' unless n == 1}"
      end
      parts.join(' · ')
    end

    def self.epic_seal_glyph(epic, active_epic_id)
      if epic['status'] == 'done'       then '✓'
      elsif epic['id'] == active_epic_id then '⚑'
      else                                   '◇'
      end
    end
  end
end
