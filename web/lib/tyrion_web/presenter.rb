# frozen_string_literal: true

module TyrionWeb
  module Presenter
    STALE_HOURS = 4

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
    # Returns { state:, color_css:, glyph:, label:, action:, focus:, archived: }.
    def self.epic_state(epic, stories, active_epic_id)
      in_progress  = stories.select { |s| s['status'] == 'in_progress' }
      done_count   = stories.count  { |s| s['status'] == 'done' }
      blocked_count = stories.count { |s| s['status'] == 'blocked' }
      story_count  = stories.size
      max_note_at  = in_progress.map { |s| s['last_note_at'] }.compact.max

      state =
        if story_count.zero?
          :empty
        elsif epic['status'] == 'done'
          :sealed
        elsif done_count == story_count
          :ready
        elsif in_progress.any? && !stale?(max_note_at)
          :active
        elsif in_progress.any?
          :cold
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
        when :empty   then ['rm-seal future',  nil, 'empty',          :import]
        when :sealed  then ['rm-seal',          '✓', 'sealed',         nil]
        when :ready   then ['rm-seal ready',    '✦', 'READY TO SEAL',  :seal]
        when :active  then ['rm-seal active',   '●', 'active',         nil]
        when :cold    then ['rm-seal cold',     '⚠', "cold · #{time_ago(max_note_at)}", :resume]
        when :paused  then ['rm-seal paused',   '‖', 'paused',         :resume]
        when :blocked then ['rm-seal blocked',  '✕', "#{blocked_count} blocked", :blocker]
        when :started then ['rm-seal active',   nil, 'active',         nil]
        when :queued  then ['rm-seal future',   nil, 'queued',         nil]
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
      agent = origin.to_s == 'agent'
      { text: Tyrion::Output.origin_label(origin), css: agent ? 'dv-origin agent' : 'dv-origin human' }
    end

    def self.epic_seal_glyph(epic, active_epic_id)
      if epic['status'] == 'done'       then '✓'
      elsif epic['id'] == active_epic_id then '⚑'
      else                                   '◇'
      end
    end
  end
end
