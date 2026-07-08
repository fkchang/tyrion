# frozen_string_literal: true

require 'json'

module Tyrion
  # Deterministic (no-LLM) scan of Claude Code session JSONL transcripts for
  # recurring correction signals. Produces candidate lessons grouped by a
  # suggested --at trigger for a human to review and approve — never writes
  # anything itself. See `tyrion lesson mine` in Commands for the approval loop.
  module LessonMiner
    # User-message correction signals — text the human typed to correct the agent.
    CORRECTION_SIGNALS = [
      /^no[,.]/,
      /\bdon't\b|\bdo not\b/,
      /\bactually,?\b/,
      /\bstop (doing|using|adding|generating)\b/,
      /\bthat'?s (not|wrong|incorrect)\b/,
      /\btry again\b|\bredo\b/,
      /\bi said\b/,
      /\b2nd time\b|\bsecond time\b/,
      /\byou keep\b/
    ].freeze

    # Assistant self-correction signals — the agent admitting it was wrong.
    SELF_CORRECTION_SIGNALS = [
      /you're right/,
      /\bi should have\b/
    ].freeze

    # Truncate stored candidate text so a single huge transcript blob (e.g. an
    # injected skill prompt that happens to match a signal) stays reviewable.
    MAX_TEXT_LENGTH = 300

    # Scans every *.jsonl file in +dir+ and returns candidates grouped by
    # suggested trigger: { 'uat' => [...], 'pre-push-pass' => [...], ... }
    # Candidates are deduplicated (normalized text, within trigger) across files.
    def self.scan(dir)
      candidates = Dir.glob(File.join(dir, '*.jsonl')).sort.flat_map { |file| scan_file(file) }
      dedupe(candidates)
    end

    def self.scan_file(file)
      found = []
      File.foreach(file) do |line|
        entry = safe_parse(line)
        next unless entry.is_a?(Hash)

        msg = entry['message']
        next unless msg.is_a?(Hash)

        role = msg['role']
        next unless %w[user assistant].include?(role)

        text = extract_text(msg['content'])
        next if text.nil? || text.strip.empty?

        haystack = text.downcase
        signals = role == 'user' ? CORRECTION_SIGNALS : SELF_CORRECTION_SIGNALS
        next unless signals.any? { |sig| haystack.match?(sig) }

        found << {
          text:    text.strip[0, MAX_TEXT_LENGTH],
          role:    role,
          trigger: suggested_trigger(text),
          file:    File.basename(file)
        }
      end
      found
    end
    private_class_method :scan_file

    def self.safe_parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
    private_class_method :safe_parse

    # +content+ is either a plain string, or an array of content blocks (some
    # of which are tool_use/tool_result/thinking — only 'text' blocks reflect
    # what the human or assistant actually said).
    def self.extract_text(content)
      case content
      when String
        content
      when Array
        content.select { |b| b.is_a?(Hash) && b['type'] == 'text' }
               .map { |b| b['text'] }
               .compact
               .join("\n")
      end
    end
    private_class_method :extract_text

    def self.suggested_trigger(text)
      t = text.downcase
      return 'uat' if t.match?(/\buat\b|\brspec\b|\btest suite\b|\bspecs?\b/)
      return 'pre-push-pass' if t.match?(/\bpre-push\b|\bstop\b|\bwait\b|\bproceed\b/)
      return 'import-existing' if t.match?(/\bimport\b/)

      'start'
    end
    private_class_method :suggested_trigger

    def self.dedupe(candidates)
      candidates
        .uniq { |c| [c[:trigger], c[:text].downcase.strip] }
        .group_by { |c| c[:trigger] }
    end
    private_class_method :dedupe
  end
end
