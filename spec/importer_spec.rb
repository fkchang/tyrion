# frozen_string_literal: true

require 'spec_helper'
require 'tyrion/importer'

FEATURE_CONTENT = <<~FEATURE
  Feature: Sample Epic
    A sample epic for testing.

    Scenario: first-story
      # Intent: test the basic import path
      Given a precondition
      When an action occurs
      Then an outcome is observed
FEATURE

CRITERIA_THEN_FEATURE_CONTENT = <<~FEATURE
  Feature: Criteria Mode Epic

    Scenario: then-only-story
      As a developer
      In order to get clean criteria
      I want then-only import

      Given first setup step
      Given second setup step
      When the trigger action
      Then first outcome
      Then second outcome
      And third outcome continues
FEATURE

NARRATIVE_FEATURE_CONTENT = <<~FEATURE
  Feature: Narrative Epic
    Epic with Gherkin narrative format.

    Scenario: story-with-narrative
      As a developer using AI coding agents
      In order to track exploratory work without losing context
      I want to capture spikes and promote them to stories

      Given a precondition
      When an action occurs
      Then an outcome is observed

    Scenario: story-intent-wins
      # Intent: explicit intent takes priority over narrative
      As a developer
      In order to do something
      I want something else

      Given a precondition
      When an action occurs
      Then an outcome is observed
FEATURE

RSpec.describe Tyrion::Importer do
  let(:ctx)          { tyrion_worktree(project_slug: 'test-proj', project_name: 'Test Project') }
  let(:store)        { ctx.store }
  let(:feature_path) do
    path = File.join(ctx.tmpdir, 'sample-epic.feature')
    File.write(path, FEATURE_CONTENT)
    path
  end
  let(:narrative_feature_path) do
    path = File.join(ctx.tmpdir, 'narrative-epic.feature')
    File.write(path, NARRATIVE_FEATURE_CONTENT)
    path
  end
  let(:criteria_then_feature_path) do
    path = File.join(ctx.tmpdir, 'criteria-mode-epic.feature')
    File.write(path, CRITERIA_THEN_FEATURE_CONTENT)
    path
  end

  before { feature_path }

  # ── Helpers ────────────────────────────────────────────────────────────────

  def run_import(extra_args = [])
    out, _err = capture_io do
      Tyrion::Importer.run([feature_path] + extra_args, store)
    end
    out
  end

  def first_story
    project = ctx.project
    epic = store.find_epic(project['id'], 'sample-epic')
    return nil unless epic
    store.stories_for_epic(epic['id']).first
  end

  # ── Happy path ─────────────────────────────────────────────────────────────

  describe '.run' do
    context 'basic import (first run)' do
      it 'creates the epic' do
        run_import
        epic = store.find_epic(ctx.project['id'], 'sample-epic')
        expect(epic).not_to be_nil
        expect(epic['name']).to eq 'Sample Epic'
      end

      it 'creates the story with correct slug and title' do
        run_import
        story = first_story
        expect(story).not_to be_nil
        expect(story['slug']).to eq 'first-story'
        expect(story['title']).to eq 'first-story'
      end

      it 'adds 3 acceptance criteria to the story' do
        run_import
        criteria = store.criteria_for_story(first_story['id'])
        expect(criteria.length).to eq 3
      end

      it 'stores the correct criteria texts' do
        run_import
        texts = store.criteria_for_story(first_story['id']).map { |c| c['text'] }
        expect(texts).to include('a precondition')
        expect(texts).to include('an action occurs')
        expect(texts).to include('an outcome is observed')
      end

      it 'outputs the epic name, story slug, and Import complete' do
        output = run_import
        expect(output).to match(/Sample Epic/)
        expect(output).to match(/first-story/)
        expect(output).to match(/Import complete/)
      end
    end

    # ── Thin-scenario warning ───────────────────────────────────────────────

    context 'thin scenario (bare title, no Given/When/Then)' do
      let(:mixed_feature_path) do
        path = File.join(ctx.tmpdir, 'mixed-epic.feature')
        File.write(path, <<~FEATURE)
          Feature: Mixed Epic

            Scenario: full-story
              Given a precondition
              When an action occurs
              Then an outcome is observed

            Scenario: bare-story
        FEATURE
        path
      end

      def run_mixed_import
        out, _err = capture_io { Tyrion::Importer.run([mixed_feature_path], store) }
        out
      end

      it 'prints a visible warning line for the zero-criteria story' do
        output = run_mixed_import
        expect(output).to match(/⚠ Story: bare-story imported with 0 criteria/)
        expect(output).to match(/full Given\/When\/Then scenario body included/)
      end

      it 'still prints the normal Story line with count for the story with criteria' do
        output = run_mixed_import
        expect(output).to match(/  Story: full-story \(3 criteria\)/)
      end
    end

    # ── Criteria lint (subjective phrasing) ──────────────────────────────────

    context 'criteria containing subjective phrasing' do
      let(:lint_feature_path) do
        path = File.join(ctx.tmpdir, 'lint-epic.feature')
        File.write(path, <<~FEATURE)
          Feature: Lint Epic

            Scenario: vague-story
              Given a precondition
              When an action occurs
              Then readers find the guidance helpful and easy to understand

            Scenario: sharp-story
              Given a precondition
              When an action occurs
              Then GET /status returns HTTP 200 with a body containing "ok"
        FEATURE
        path
      end

      def run_lint_import
        out, _err = capture_io { Tyrion::Importer.run([lint_feature_path], store) }
        out
      end

      it 'prints a per-criterion warning naming the flagged phrase and suggesting a rewrite' do
        output = run_lint_import
        expect(output).to match(/⚠ vague-story: criterion/)
        expect(output).to match(/subjective phrase 'helpful'/)
        expect(output).to match(/rewrite as an observable check/)
      end

      it 'produces no warning for a criterion without flagged phrasing' do
        output = run_lint_import
        expect(output).not_to match(/⚠ sharp-story/)
      end

      it 'still imports the story so the lint warns rather than refuses' do
        run_lint_import
        epic = store.find_epic(ctx.project['id'], 'lint-epic')
        story = store.find_story(epic['id'], 'vague-story')
        expect(story).not_to be_nil
        expect(store.criteria_for_story(story['id']).length).to eq 3
      end
    end

    # ── Hash-unchanged skip ─────────────────────────────────────────────────

    context 'second import with unchanged file hash' do
      it 'reports already up to date' do
        run_import            # first import
        output = run_import   # second import — same file, same hash
        expect(output).to match(/already up to date/)
      end

      it 'does not duplicate criteria (still 3, not 6)' do
        run_import
        run_import
        criteria = store.criteria_for_story(first_story['id'])
        expect(criteria.length).to eq 3
      end
    end

    # ── Gherkin narrative format (As a / In order to / I want) ─────────────

    context 'narrative format — As a / In order to / I want' do
      def run_narrative_import
        capture_io { Tyrion::Importer.run([narrative_feature_path], store) }
      end

      def narrative_story(slug)
        epic = store.find_epic(ctx.project['id'], 'narrative-epic')
        store.stories_for_epic(epic['id']).find { |s| s['slug'] == slug }
      end

      it 'sets intent from narrative lines when no # Intent: comment is present' do
        run_narrative_import
        story = narrative_story('story-with-narrative')
        expect(story['intent']).to include('In order to track exploratory work without losing context')
      end

      it 'includes all three narrative clauses in the intent' do
        run_narrative_import
        story = narrative_story('story-with-narrative')
        expect(story['intent']).to include('As a developer using AI coding agents')
        expect(story['intent']).to include('I want to capture spikes and promote them to stories')
      end

      it 'does not count narrative lines as criteria' do
        run_narrative_import
        story = narrative_story('story-with-narrative')
        expect(store.criteria_for_story(story['id']).length).to eq 3
      end

      it '# Intent: takes priority over narrative lines' do
        run_narrative_import
        story = narrative_story('story-intent-wins')
        expect(story['intent']).to eq 'explicit intent takes priority over narrative'
      end
    end

    # ── --force reimport ────────────────────────────────────────────────────

    context 'second import with --force flag' do
      it 'proceeds despite unchanged hash and outputs Import complete' do
        run_import
        output = run_import(['--force'])
        expect(output).to match(/Import complete/)
        expect(output).not_to match(/already up to date/)
      end

      it 'does not duplicate criteria (refreshes, not doubles)' do
        run_import
        run_import(['--force'])
        criteria = store.criteria_for_story(first_story['id'])
        expect(criteria.length).to eq 3
      end

      it 'output contains the story slug' do
        run_import
        output = run_import(['--force'])
        expect(output).to match(/first-story/)
      end
    end

    # ── --confirm-abandon guard: block on ANY active lane ───────────────────

    context 're-import guard with in-progress lanes' do
      # A two-scenario feature so the epic can hold two active lanes at once.
      TWO_STORY_FEATURE = <<~FEATURE
        Feature: Two Story Epic

          Scenario: story-a
            Given a precondition
            When an action occurs
            Then an outcome is observed

          Scenario: story-b
            Given a precondition
            When an action occurs
            Then an outcome is observed
      FEATURE

      let(:two_story_path) do
        path = File.join(ctx.tmpdir, 'two-story-epic.feature')
        File.write(path, TWO_STORY_FEATURE)
        path
      end

      def import_two(extra_args = [])
        capture_io { Tyrion::Importer.run([two_story_path] + extra_args, store) }
      end

      def epic
        store.find_epic(ctx.project['id'], 'two-story-epic')
      end

      def start(slug, token)
        s = store.find_story(epic['id'], slug)
        store.start_story(s['id'], claimed_by: token)
      end

      before { import_two } # first import creates the epic + both stories

      it 'blocks re-import when one lane is active (no --confirm-abandon)' do
        start('story-a', 'lane-A')
        expect { Tyrion::Importer.run([two_story_path, '--force'], store) }
          .to raise_error(SystemExit)
          .and output(/story-a/).to_stderr
      end

      it 'names EVERY active lane when multiple lanes are in progress' do
        start('story-a', 'lane-A')
        start('story-b', 'lane-B')
        expect { Tyrion::Importer.run([two_story_path, '--force'], store) }
          .to raise_error(SystemExit)
          .and output(/story-a.*story-b|story-b.*story-a/m).to_stderr
      end

      it 'proceeds when --confirm-abandon is passed despite active lanes' do
        start('story-a', 'lane-A')
        start('story-b', 'lane-B')
        out, = import_two(['--force', '--confirm-abandon'])
        expect(out).to match(/Import complete/)
      end

      it 'does not block when no lane is active' do
        out, = import_two(['--force'])
        expect(out).to match(/Import complete/)
      end
    end

    # ── --criteria=then flag ────────────────────────────────────────────────

    context '--criteria=then flag' do
      def run_criteria_then_import
        capture_io { Tyrion::Importer.run([criteria_then_feature_path, '--criteria=then'], store) }
      end

      def then_only_story
        epic = store.find_epic(ctx.project['id'], 'criteria-mode-epic')
        return nil unless epic
        store.stories_for_epic(epic['id']).find { |s| s['slug'] == 'then-only-story' }
      end

      before { criteria_then_feature_path }

      it 'creates only the 3 Then/And-under-Then steps as criteria' do
        run_criteria_then_import
        criteria = store.criteria_for_story(then_only_story['id'])
        expect(criteria.length).to eq 3
      end

      it 'criteria contain only Then step texts' do
        run_criteria_then_import
        texts = store.criteria_for_story(then_only_story['id']).map { |c| c['text'] }
        expect(texts).to include('first outcome')
        expect(texts).to include('second outcome')
        expect(texts).to include('third outcome continues')
        expect(texts).not_to include('first setup step')
        expect(texts).not_to include('the trigger action')
      end

      it 'stores Given/When lines in an observation note' do
        run_criteria_then_import
        story = then_only_story
        notes = store.notes_for_story(story['id'], limit: 10)
        obs = notes.find { |n| n['kind'] == 'observation' }
        expect(obs).not_to be_nil
        expect(obs['body']).to include('Given first setup step')
        expect(obs['body']).to include('Given second setup step')
        expect(obs['body']).to include('When the trigger action')
      end

      it 'does not clobber the narrative intent' do
        run_criteria_then_import
        story = then_only_story
        expect(story['intent']).to include('As a developer')
        expect(story['intent']).to include('In order to get clean criteria')
      end

      it 'default behavior (no flag) still creates all steps as criteria' do
        capture_io { Tyrion::Importer.run([criteria_then_feature_path], store) }
        criteria = store.criteria_for_story(then_only_story['id'])
        expect(criteria.length).to eq 6
      end
    end

    # ── .context.md sibling import ──────────────────────────────────────────

    context '.context.md sibling file' do
      let(:context_content) { "# My Context\n\nThis is the context." }
      let(:context_path)    { File.join(ctx.tmpdir, 'sample-epic.context.md') }

      def epic
        store.find_epic(ctx.project['id'], 'sample-epic')
      end

      it 'loads context_md into the epic when sibling file exists' do
        File.write(context_path, context_content)
        run_import
        expect(epic['context_md']).to eq context_content
      end

      it 'stores context_source_hash when sibling file exists' do
        File.write(context_path, context_content)
        run_import
        expected_hash = Digest::SHA256.hexdigest(context_content)
        expect(epic['context_source_hash']).to eq expected_hash
      end

      it 'is idempotent when neither feature nor context.md changes (hash match = no-op)' do
        File.write(context_path, context_content)
        run_import
        output = run_import
        expect(output).to match(/already up to date/)
      end

      it 'leaves context_md nil when no sibling .context.md file exists' do
        run_import
        expect(epic['context_md']).to be_nil
      end

      it 'leaves context_source_hash nil when no sibling .context.md file exists' do
        run_import
        expect(epic['context_source_hash']).to be_nil
      end

      it 're-imports when context.md changes even if feature hash is unchanged' do
        File.write(context_path, context_content)
        run_import
        File.write(context_path, context_content + "\nAdded line.")
        output = run_import
        expect(output).to match(/Import complete/)
        expect(epic['context_md']).to include('Added line.')
      end

      it 'clears context_md when sibling file is deleted after a prior import' do
        File.write(context_path, context_content)
        run_import
        expect(epic['context_md']).to eq context_content

        File.delete(context_path)
        run_import
        expect(epic['context_md']).to be_nil
        expect(epic['context_source_hash']).to be_nil
      end

      it 'is idempotent after deleting the sibling file (third import is no-op)' do
        File.write(context_path, context_content)
        run_import
        File.delete(context_path)
        run_import
        output = run_import
        expect(output).to match(/already up to date/)
      end
    end
  end
end
