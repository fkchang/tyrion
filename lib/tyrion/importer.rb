# frozen_string_literal: true

require 'digest'

module Tyrion
  module Importer
    NARRATIVE_PREFIXES = ['As a ', 'As an ', 'In order to ', 'I want ', 'I would like '].freeze

    def self.run(args, store)
      confirm_abandon = args.delete('--confirm-abandon')
      force           = args.delete('--force')
      path = args.first
      die "Usage: tyrion import <file.feature> [--confirm-abandon] [--force]" unless path
      die "File not found: #{path}" unless File.exist?(path)

      project_slug = Repo.active_project
      die "No active project. Run: tyrion project activate <slug>" unless project_slug

      project = store.find_project_by_slug(project_slug)
      die "Active project '#{project_slug}' not found in DB." unless project

      parsed = parse_feature(File.read(path))
      die "No Feature block found in #{path}" unless parsed[:feature_name]

      epic_slug = File.basename(path, '.feature')
      file_hash = Digest::SHA256.file(path).hexdigest

      existing = store.find_epic(project['id'], epic_slug)
      if existing && existing['feature_source_hash'] == file_hash && !force
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
        feature_source_hash: file_hash
      )

      puts "Epic: #{epic['name']} [#{epic_slug}]"

      parsed[:scenarios].each_with_index do |scenario, idx|
        story = store.upsert_story(
          epic_id:  epic['id'],
          slug:     scenario[:slug],
          title:    scenario[:title],
          sequence: idx + 1,
          intent:   scenario[:intent]
        )

        next if scenario[:criteria].empty?

        existing_criteria = store.criteria_for_story(story['id'])
        store.delete_pending_criteria(story['id']) if existing_criteria.any?

        store.add_criteria(story['id'], scenario[:criteria])
        puts "  Story: #{story['slug']} (#{scenario[:criteria].length} criteria)"
      end

      puts "Import complete: #{parsed[:scenarios].length} story/stories."
    end

    # ── Parser ──────────────────────────────────────────────────────────────

    def self.parse_feature(text)
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
          current_scenario = { title: title, slug: slug, intent: nil, narrative: [], criteria: [] }
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

        current_scenario[:criteria] << {
          keyword:       keyword,
          semantic_kind: semantic_kind || last_semantic_kind || 'then',
          text:          text
        }
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
