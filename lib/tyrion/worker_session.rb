# frozen_string_literal: true

require 'open3'
require 'pathname'
require 'digest'

module Tyrion
  # The worker-session executable owns terminal creation and reconciliation.
  # Tyrion only supplies its verified story/worktree scope.
  module WorkerSession
    def self.valid_handle?(result, lane:, scope:, attempt:)
      handle = result['handle']
      return false unless handle.is_a?(Hash) && handle['lane'] == lane &&
                          handle['attempt'] == attempt && handle['provider'] == 'claude' &&
                          handle['worker_id'].is_a?(String) && !handle['worker_id'].empty?

      runtime = handle['runtime']
      terminal = handle['terminal']
      process = handle['process']
      native = handle['native_conversation']
      actions = handle['actions']
      return false unless runtime.is_a?(Hash) && runtime['kind'] == 'herdr' &&
                          runtime['scope'] == scope && runtime['identity'].to_s != ''
      return false unless terminal.is_a?(Hash) && terminal['tab_id'] == result['tab_id'] &&
                          terminal['pane_id'] == result['pane_id'] && terminal['terminal_id'].to_s != ''
      return false unless process.is_a?(Hash) && process['pid'].is_a?(Integer) &&
                          process['birth'].to_s != '' && process['observed_at'].to_s != ''
      return false unless native.is_a?(Hash) && native['observed_at'].to_s != ''
      if native['value']
        return false unless native['value'].is_a?(String) &&
                            native['value'].match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i) &&
                            native['kind'] == 'id' && native['source'] == 'launcher_cli_arg+process_argv' &&
                            native['freshness'] == 'current' && native['process_birth'] == process['birth'] &&
                            native['observed_at'] == process['observed_at']
      else
        return false unless native['freshness'] == 'unknown'
      end
      candidate = native['candidate']
      return false if candidate && (!candidate.is_a?(Hash) || candidate['source'].to_s.empty? ||
                                    candidate['value'].to_s.empty?)
      return false unless actions.is_a?(Hash) && actions['follow_up'] == false &&
                          actions['complete_story'] == false

      true
    end

    # Build the actual initial prompt from the imported source, rather than
    # relying on a caller's short task brief to restate the approved contract.
    def self.handoff(store:, epic:, story:, worktree:, task:)
      source = epic['feature_source_path']
      revision = epic['feature_source_hash']
      raise ArgumentError, 'No imported canonical scenario revision; import the feature first' unless source && revision

      feature_path = Pathname.new(source).absolute? ? source : File.join(Repo.main_root || Repo.worktree_root, source)
      raise ArgumentError, 'Canonical scenario source is missing; import the feature first' unless File.file?(feature_path)

      feature = File.read(feature_path, encoding: 'UTF-8')
      raise ArgumentError, 'Canonical scenario revision changed; import the feature first' \
        unless Digest::SHA256.hexdigest(feature) == revision

      lines = feature.lines
      headings, rule_headings = structural_headings(lines)
      matching_index = headings.select do |index|
        title = lines[index].strip.sub(/\AScenario(?: Outline)?:\s*/, '')
        title.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '') == story['slug']
      end
      raise ArgumentError, 'Canonical scenario is missing or ambiguous; import the feature first' unless matching_index.size == 1

      first = matching_index.first
      blocks = (headings + rule_headings).sort
      preceding_rule = rule_headings.select { |index| index < first }.last
      first_block = blocks.first || lines.length
      feature_context = lines[0...leading_metadata_start(lines, first_block, -1)].join.rstrip
      rule_context = if preceding_rule
        prior_block = blocks.select { |index| index < preceding_rule }.last || -1
        next_rule = rule_headings.find { |index| index > preceding_rule } || lines.length
        first_rule_scenario = headings.find { |index| index > preceding_rule && index < next_rule }
        rule_start = leading_metadata_start(lines, preceding_rule, prior_block)
        rule_end = leading_metadata_start(lines, first_rule_scenario, preceding_rule)
        lines[rule_start...rule_end].join.rstrip
      end
      prior_block = blocks.select { |index| index < first }.last || -1
      metadata_start = leading_metadata_start(lines, first, prior_block)
      following = blocks.find { |index| index > first } || lines.length
      scenario_lines = lines[first...following]
      scenario_lines.pop while scenario_lines.any? &&
                               (scenario_lines.last.strip.empty? || scenario_lines.last.strip.start_with?('#', '@'))
      leading_metadata = lines[metadata_start...first].join.rstrip
      scenario_text = [feature_context, rule_context, leading_metadata, scenario_lines.join.rstrip]
                      .compact.reject(&:empty?).join("\n\n")
      notes = store.constraint_notes_for_story(story['id'])
      constraints = notes.map { |note| "[#{note['kind']}] #{note['body']}" }
      guidance = %w[AGENTS.md CLAUDE.md].filter_map do |name|
        path = File.join(worktree, name)
        next unless File.file?(path)

        content = File.read(path, encoding: 'UTF-8')
        "## #{name} (SHA-256 #{Digest::SHA256.hexdigest(content)})\n#{content}"
      end

      body = [
        "# Tyrion worker handoff",
        "Story: #{story['slug']}",
        "Canonical feature: #{epic['slug']} @ SHA-256 #{revision}",
        "Source: #{feature_path}",
        "\n## Complete approved scenario\n#{scenario_text}",
        "\n## Recorded plan and decision constraints\n#{constraints.empty? ? '(none recorded)' : constraints.join("\n\n")}",
        "\n## Applicable worktree guidance\n#{guidance.empty? ? '(none at worktree root)' : guidance.join("\n\n")}",
        "\n## Assigned task\n#{task}"
      ].join("\n")
      { text: body, sha256: Digest::SHA256.hexdigest(body), scenario_revision: revision,
        scenario_source: feature_path }
    end

    def self.leading_metadata_start(lines, heading, floor)
      index = heading
      while index > floor + 1 &&
            (lines[index - 1].strip.empty? || lines[index - 1].strip.start_with?('#', '@'))
        index -= 1
      end
      index
    end
    private_class_method :leading_metadata_start

    # Derive every handoff boundary from the same source scan. A Doc String's
    # contents are task data, even when a line looks like a Scenario or Rule.
    def self.structural_headings(lines)
      scenarios = []
      rules = []
      fence = nil
      lines.each_with_index do |line, index|
        stripped = line.strip
        if fence
          fence = nil if stripped == fence
          next
        end

        delimiter = ['"""', 96.chr * 3].find { |candidate| stripped.start_with?(candidate) }
        if delimiter
          fence = delimiter
          next
        end

        scenarios << index if stripped.match?(/\AScenario(?: Outline)?:/)
        rules << index if stripped.start_with?('Rule:')
      end
      [scenarios, rules]
    end
    private_class_method :structural_headings

    def self.run(*argv)
      binary = ENV['TYRION_WORKER_SESSION_BIN'] || 'worker-session'
      if ENV.key?('TYRION_WORKER_SESSION_BIN') && !Pathname.new(binary).absolute?
        raise ArgumentError, 'TYRION_WORKER_SESSION_BIN must be an absolute path'
      end

      invoke = -> { Open3.capture3(binary, *argv) }
      if defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env)
        Bundler.with_unbundled_env(&invoke)
      else
        invoke.call
      end
    end
  end
end
