# frozen_string_literal: true

require 'digest'

module Tyrion
  module Importer
    NARRATIVE_PREFIXES = ['As a ', 'As an ', 'In order to ', 'I want ', 'I would like '].freeze

    def self.run(args, store)
      confirm_abandon = args.delete('--confirm-abandon')
      force           = args.delete('--force')
      criteria_mode   = args.delete('--criteria=then') ? 'then' : nil
      path = args.first
      die "Usage: tyrion import <file.feature> [--confirm-abandon] [--force] [--criteria=then]" unless path
      die "File not found: #{path}" unless File.exist?(path)

      project_slug = Repo.active_project
      die "No active project. Run: tyrion project activate <slug>" unless project_slug

      project = store.find_project_by_slug(project_slug)
      die "Active project '#{project_slug}' not found in DB." unless project

      parsed = parse_feature(File.read(path), criteria_mode: criteria_mode)
      die "No Feature block found in #{path}" unless parsed[:feature_name]

      epic_slug    = File.basename(path, '.feature')
      file_hash    = Digest::SHA256.file(path).hexdigest
      context_path = File.join(File.dirname(path), "#{epic_slug}.context.md")
      context_md, context_hash = if File.exist?(context_path)
        content = File.read(context_path)
        [content, Digest::SHA256.hexdigest(content)]
      else
        [nil, nil]
      end

      existing = store.find_epic(project['id'], epic_slug)
      if existing && existing['feature_source_hash'] == file_hash &&
         existing['context_source_hash'] == context_hash && !force
        puts "Epic '#{epic_slug}' is already up to date (hash unchanged). Nothing to do."
        return
      end

      if existing && !confirm_abandon
        in_prog = store.in_progress_story(existing['id'])
        if in_prog
          die "Epic '#{epic_slug}' has an in-progress story: #{in_prog['slug']}. " \
              "Complete or unstart it before re-importing, or pass --confirm-abandon."
        end
      end

      epic = store.upsert_epic(
        project_id:          project['id'],
        slug:                epic_slug,
        name:                parsed[:feature_name],
        intent:              parsed[:feature_description],
        feature_source_path: path,
        feature_source_hash: file_hash,
        context_md:          context_md,
        context_source_hash: context_hash
      )

      puts "Epic: #{epic['name']} [#{epic_slug}]"

      # All story + criteria writes are atomic in one transaction.
      # Sequence is assigned MAX+1 (not file index) so appending a scenario
      # to an existing epic never collides with existing story sequences.
      results = store.import_stories_for_epic(epic_id: epic['id'], scenarios: parsed[:scenarios])
      results.each do |r|
        puts "  Story: #{r[:slug]} (#{r[:criteria_count]} criteria)" if r[:criteria_count] > 0
      end

      if criteria_mode == 'then'
        parsed[:scenarios].each do |scenario|
          next if scenario[:setup_context].empty?
          story = store.find_story(epic['id'], scenario[:slug])
          next unless story
          context_body = scenario[:setup_context].map { |s| "#{s[:keyword]} #{s[:text]}" }.join("\n")
          store.add_note(story['id'], 'observation', "Setup context (Given/When):\n#{context_body}")
        end
      end

      puts "Import complete: #{parsed[:scenarios].length} story/stories."
    end

    # ── Parser ──────────────────────────────────────────────────────────────

    def self.parse_feature(text, criteria_mode: nil)
      lines = text.lines.map(&:rstrip)

      feature_name        = nil
      feature_description = nil
      scenarios           = []
      current_scenario    = nil
      last_semantic_kind  = nil

      lines.each do |line|
        stripped = line.strip

        if stripped.start_with?('Feature:')
          feature_name = stripped.sub(/^Feature:\s*/, '').strip
          next
        end

        if stripped.start_with?('Scenario:', 'Scenario Outline:')
          scenarios << finalize_scenario(current_scenario) if current_scenario
          title = stripped.sub(/^Scenario(?: Outline)?:\s*/, '').strip
          slug  = title.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')
          current_scenario = { title: title, slug: slug, intent: nil, narrative: [], criteria: [], setup_context: [] }
          last_semantic_kind = nil
          next
        end

        if stripped.start_with?('# Intent:')
          intent_text = stripped.sub(/^#\s*Intent:\s*/, '').strip
          if current_scenario
            current_scenario[:intent] = intent_text
          else
            feature_description = intent_text
          end
          next
        end

        next if stripped.start_with?('#') || stripped.empty?
        next unless current_scenario

        if NARRATIVE_PREFIXES.any? { |p| stripped.start_with?(p) }
          current_scenario[:narrative] << stripped
          next
        end

        keyword, text = split_step(stripped)
        next unless keyword

        semantic_kind = resolve_semantic_kind(keyword, last_semantic_kind)
        last_semantic_kind = semantic_kind if semantic_kind
        kind = semantic_kind || 'then'

        if criteria_mode == 'then' && kind != 'then'
          current_scenario[:setup_context] << { keyword: keyword, text: text }
        else
          current_scenario[:criteria] << { keyword: keyword, semantic_kind: kind, text: text }
        end
      end

      scenarios << finalize_scenario(current_scenario) if current_scenario

      {
        feature_name:        feature_name,
        feature_description: feature_description,
        scenarios:           scenarios
      }
    end

    def self.finalize_scenario(scenario)
      return unless scenario
      scenario[:intent] ||= scenario[:narrative].join("\n") unless scenario[:narrative].empty?
      scenario
    end

    STEP_KEYWORDS = %w[Given When Then And But *].freeze

    def self.split_step(line)
      STEP_KEYWORDS.each do |kw|
        if line.start_with?("#{kw} ") || line == kw
          return [kw, line.sub(/^#{Regexp.escape(kw)}\s*/, '').strip]
        end
      end
      nil
    end

    def self.resolve_semantic_kind(keyword, last_kind)
      case keyword
      when 'Given' then 'given'
      when 'When'  then 'when'
      when 'Then'  then 'then'
      when 'And', 'But', '*' then last_kind
      end
    end

    def self.die(msg)
      $stderr.puts msg
      exit 1
    end
  end
end
