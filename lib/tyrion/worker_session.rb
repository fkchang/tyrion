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

      parsed = Importer.parse_feature(feature)
      matching = parsed[:scenarios].select { |scenario| scenario[:slug] == story['slug'] }
      raise ArgumentError, 'Canonical scenario is missing or ambiguous; import the feature first' unless matching.size == 1

      lines = feature.lines
      headings = lines.each_index.select { |index| lines[index].strip.match?(/\AScenario(?: Outline)?:/) }
      matching_index = headings.select do |index|
        title = lines[index].strip.sub(/\AScenario(?: Outline)?:\s*/, '')
        title.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '') == story['slug']
      end
      raise ArgumentError, 'Canonical scenario is missing or ambiguous; import the feature first' unless matching_index.size == 1

      first = matching_index.first
      rule_headings = lines.each_index.select { |index| lines[index].strip.start_with?('Rule:') }
      preceding_rule = rule_headings.select { |index| index < first }.last
      first_block = (headings + rule_headings).min || lines.length
      feature_context = lines[0...first_block].join.rstrip
      rule_context = if preceding_rule
        first_rule_scenario = headings.find { |index| index > preceding_rule }
        lines[preceding_rule...first_rule_scenario].join.rstrip
      end
      previous_scenario = headings.select { |index| index < first }.last
      metadata_floor = [previous_scenario, preceding_rule, first_block - 1].compact.max
      metadata_start = first
      while metadata_start > metadata_floor + 1 &&
            (lines[metadata_start - 1].strip.empty? || lines[metadata_start - 1].strip.start_with?('#', '@'))
        metadata_start -= 1
      end
      following = (headings + rule_headings).select { |index| index > first }.min || lines.length
      scenario_lines = lines[first...following]
      scenario_lines.pop while scenario_lines.any? &&
                               (scenario_lines.last.strip.empty? || scenario_lines.last.strip.start_with?('#'))
      leading_metadata = first == first_block ? '' : lines[metadata_start...first].join.rstrip
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
