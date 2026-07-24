# frozen_string_literal: true

module Tyrion
  # Output — terminal formatting helpers. Color only when stdout is a TTY.
  module Output
    COLORS = {
      green:  32,
      yellow: 33,
      red:    31,
      cyan:   36,
      dim:    90,
      bold:   1
    }.freeze

    def self.color(text, name)
      return text.to_s unless $stdout.tty?
      "\e[#{COLORS.fetch(name)}m#{text}\e[0m"
    end

    def self.green(t)  = color(t, :green)
    def self.yellow(t) = color(t, :yellow)
    def self.red(t)    = color(t, :red)
    def self.cyan(t)   = color(t, :cyan)
    def self.dim(t)    = color(t, :dim)
    def self.bold(t)   = color(t, :bold)

    STALE_HOURS = 4

    def self.stale?(last_note_at)
      return false unless last_note_at
      (Time.now - Time.parse(last_note_at)) > STALE_HOURS * 3600
    end

    def self.stale_label(last_note_at)
      return '' unless last_note_at
      hours = ((Time.now - Time.parse(last_note_at)) / 3600).round
      "⚠ stale #{hours}h ago"
    end

    def self.time_ago(ts)
      return '—' unless ts
      secs = (Time.now - Time.parse(ts)).to_i
      return 'just now' if secs < 60
      mins = secs / 60
      return "#{mins}m ago" if mins < 60
      hrs = mins / 60
      return "#{hrs}h ago" if hrs < 24
      "#{hrs / 24}d ago"
    end

    def self.story_icon(status)
      case status
      when 'done'        then green('✓')
      when 'in_progress' then yellow('⚡')
      when 'blocked'     then red('✗')
      when 'abandoned'   then dim('✗')
      else dim('·')
      end
    end

    def self.status_label(status)
      case status
      when 'in_progress' then yellow(status)
      when 'done'        then green(status)
      when 'blocked'     then red(status)
      else dim(status)
      end
    end

    def self.criterion_icon(status)
      status == 'met' ? green('[✓]') : '[ ]'
    end

    def self.dark_factory?(epic) = epic['mode'] == 'dark_factory'

    # Bare badge text, no leading space — callers own their own spacing.
    # Empty string for shape/NULL (the deliberate quiet default).
    def self.epic_mode_badge(epic)
      dark_factory?(epic) ? '🏭 dark_factory' : ''
    end
  end
end
