# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/tyrion'
require_relative '../lib/tyrion/importer'

class TestImporter < Minitest::Test
  FEATURE_CONTENT = <<~FEATURE
    Feature: Sample Epic
      A sample epic for testing.

      Scenario: first-story
        # Intent: test the basic import path
        Given a precondition
        When an action occurs
        Then an outcome is observed
  FEATURE

  def setup
    @tmpdir  = Dir.mktmpdir('tyrion-importer-test-')
    @db_path = File.join(@tmpdir, 'test.db')
    @store   = Tyrion::Store.new(db_path: @db_path)

    # Create the project fixture the importer will look up
    @project = @store.create_project(slug: 'test-proj', name: 'Test Project')

    # Write the .feature file to tmpdir
    @feature_path = File.join(@tmpdir, 'sample-epic.feature')
    File.write(@feature_path, FEATURE_CONTENT)

    Tyrion::Repo.define_singleton_method(:worktree_root)  { |*| @tmpdir }
    Tyrion::Repo.define_singleton_method(:active_project) { |*| 'test-proj' }
    Tyrion::Repo.define_singleton_method(:active_epic)    { |*| 'sample-epic' }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    %i[worktree_root active_project active_epic].each do |m|
      Tyrion::Repo.singleton_class.remove_method(m)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  def run_import(extra_args = [])
    out, _err = capture_io do
      Tyrion::Importer.run([@feature_path] + extra_args, @store)
    end
    out
  end

  def first_story
    epic = @store.find_epic(@project['id'], 'sample-epic')
    return nil unless epic
    @store.stories_for_epic(epic['id']).first
  end

  # ── tests ─────────────────────────────────────────────────────────────────

  def test_basic_import_creates_epic
    run_import
    epic = @store.find_epic(@project['id'], 'sample-epic')
    refute_nil epic
    assert_equal 'Sample Epic', epic['name']
  end

  def test_basic_import_creates_story
    run_import
    story = first_story
    refute_nil story
    assert_equal 'first-story', story['slug']
    assert_equal 'first-story', story['title']
  end

  def test_basic_import_adds_criteria_to_story
    run_import
    story    = first_story
    criteria = @store.criteria_for_story(story['id'])
    assert_equal 3, criteria.length
  end

  def test_basic_import_criteria_texts
    run_import
    story    = first_story
    criteria = @store.criteria_for_story(story['id'])
    texts = criteria.map { |c| c['text'] }
    assert_includes texts, 'a precondition'
    assert_includes texts, 'an action occurs'
    assert_includes texts, 'an outcome is observed'
  end

  def test_basic_import_output_mentions_epic_and_story
    output = run_import
    assert_match(/Sample Epic/, output)
    assert_match(/first-story/, output)
    assert_match(/Import complete/, output)
  end

  # ── hash-unchanged skip ───────────────────────────────────────────────────

  def test_second_import_same_hash_is_skipped
    run_import                        # first import
    output = run_import               # second import — same file, same hash
    assert_match(/already up to date/, output)
  end

  def test_second_import_does_not_duplicate_criteria
    run_import
    run_import
    story    = first_story
    criteria = @store.criteria_for_story(story['id'])
    assert_equal 3, criteria.length   # still 3, not 6
  end

  # ── --force reimport ──────────────────────────────────────────────────────

  def test_force_reimport_proceeds_despite_unchanged_hash
    run_import                                 # first import
    output = run_import(['--force'])           # --force with same hash
    assert_match(/Import complete/, output)
    refute_match(/already up to date/, output)
  end

  def test_force_reimport_does_not_duplicate_criteria
    run_import
    run_import(['--force'])
    story    = first_story
    criteria = @store.criteria_for_story(story['id'])
    assert_equal 3, criteria.length   # criteria refreshed, not doubled
  end

  def test_force_reimport_output_contains_story_slug
    run_import
    output = run_import(['--force'])
    assert_match(/first-story/, output)
  end
end
