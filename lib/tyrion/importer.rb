# frozen_string_literal: true

require 'digest'

module Tyrion
  module Importer
    NARRATIVE_PREFIXES = ['As a ', 'As an ', 'In order to ', 'I want ', 'I would like '].freeze

    # Subjective/unverifiable phrases that make an acceptance criterion impossible
    # to check without interpretation — the exact opening an autonomous agent uses
    # to manufacture proxy evidence instead of blocking. Linted (warned, never
    # refused) at import time. Extend this list as new weasel-words surface.
    SUBJECTIVE_PHRASES = [
      'clearly', 'easily', 'helpful', 'easy to understand', 'intuitive',
      'user-friendly', 'user friendly', 'readers find', 'properly',
      'appropriately', 'robust', 'seamless', 'seamlessly', 'nicely',
      'good', 'better', 'best', 'as expected', 'makes sense'
    ].freeze

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
        in_prog = store.in_progress_stories(existing['id'])
        unless in_prog.empty?
          slugs = in_prog.map { |s| s['slug'] }.join(', ')
          if in_prog.length == 1
            noun, pron = 'an in-progress story', 'it'
          else
            noun, pron = "#{in_prog.length} in-progress stories (one per lane)", 'them'
          end
          die "Epic '#{epic_slug}' has #{noun}: #{slugs}. " \
              "Complete or unstart #{pron} before re-importing, or pass --confirm-abandon."
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
        if r[:criteria_count] > 0
          puts "  Story: #{r[:slug]} (#{r[:criteria_count]} criteria)"
        else
          puts "  ⚠ Story: #{r[:slug]} imported with 0 criteria — " \
               "was the full Given/When/Then scenario body included, or just a title?"
        end
      end

      lint_criteria(parsed[:scenarios])

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

    # ── Criteria lint ─────────────────────────────────────────────────────────
    # Warn (never refuse) when a criterion contains subjective phrasing a human or
    # script can't verify without interpretation. This is the mechanical backstop
    # for the judgment-based SHARPEN refusal, which an autonomous agent can talk
    # itself past.

    def self.lint_criteria(scenarios)
      scenarios.each do |scenario|
        scenario[:criteria].each do |criterion|
          flagged_phrases(criterion[:text]).each do |phrase|
            puts "  ⚠ #{scenario[:slug]}: criterion \"#{criterion[:text]}\" contains " \
                 "subjective phrase '#{phrase}' — rewrite as an observable check " \
                 "(a command, output match, or page behavior a reviewer can verify)."
          end
        end
      end
    end

    def self.flagged_phrases(text)
      SUBJECTIVE_PHRASES.select do |phrase|
        text.match?(/\b#{Regexp.escape(phrase)}\b/i)
      end
    end

    # ── Parser ──────────────────────────────────────────────────────────────

    def self.parse_feature(text, criteria_mode: nil)
      lines = text.lines.map(&:rstrip)

      feature_name        = nil
      feature_description = nil
      scenarios           = []
      current_scenario    = nil
      last_semantic_kind  = nil
      intent_continuation = nil # :scenario, :feature, or nil — set after a # Intent: line,
                                 # cleared by any non-comment-continuation line

      lines.each do |line|
        stripped = line.strip

        if stripped.start_with?('Feature:')
          feature_name = stripped.sub(/^Feature:\s*/, '').strip
          intent_continuation = nil
          next
        end

        if stripped.start_with?('Scenario:', 'Scenario Outline:')
          scenarios << finalize_scenario(current_scenario) if current_scenario
          title = stripped.sub(/^Scenario(?: Outline)?:\s*/, '').strip
          slug  = title.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')
          current_scenario = { title: title, slug: slug, intent: nil, narrative: [], criteria: [], setup_context: [] }
          last_semantic_kind = nil
          intent_continuation = nil
          next
        end

        if stripped.start_with?('# Intent:')
          intent_text = stripped.sub(/^#\s*Intent:\s*/, '').strip
          if current_scenario
            current_scenario[:intent] = intent_text
            intent_continuation = :scenario
          else
            feature_description = intent_text
            intent_continuation = :feature
          end
          next
        end

        # Contiguous plain comment lines immediately following # Intent: wrap the
        # same intent (agent-drafted feature files wrap long intents across lines).
        if intent_continuation && stripped.start_with?('#')
          continuation_text = stripped.sub(/^#\s*/, '').strip
          if intent_continuation == :scenario
            current_scenario[:intent] = "#{current_scenario[:intent]} #{continuation_text}"
          else
            feature_description = "#{feature_description} #{continuation_text}"
          end
          next
        end
        intent_continuation = nil

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
