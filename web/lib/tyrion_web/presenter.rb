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

    def self.epic_seal_css(epic, active_epic_id)
      if epic['status'] == 'done'
        'rm-seal'
      elsif epic['id'] == active_epic_id
        'rm-seal active'
      else
        'rm-seal future'
      end
    end

    def self.epic_seal_glyph(epic, active_epic_id)
      if epic['status'] == 'done'       then '✓'
      elsif epic['id'] == active_epic_id then '⚑'
      else                                   '◇'
      end
    end
  end
end
