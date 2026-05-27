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
  end
end
