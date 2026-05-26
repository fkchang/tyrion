# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/tyrion'

class TestPocket < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('tyrion-pocket-test-')
    @db_path = File.join(@tmpdir, 'test.db')

    # Point Store at the temp DB
    @store = Tyrion::Store.new(db_path: @db_path)

    # Create project, epic, and story fixtures
    @project = @store.create_project(slug: 'myproj', name: 'My Project')
    @epic    = @store.create_epic(project_id: @project['id'], slug: 'auth-epic', name: 'Auth Epic')
    @story   = @store.create_story(epic_id: @epic['id'], slug: 'login-story', title: 'Login Story')

    # Add two criteria: one met, one pending
    @store.add_criteria(@story['id'], [
      { keyword: 'Given', semantic_kind: 'given', text: 'a registered user' },
      { keyword: 'Then',  semantic_kind: 'then',  text: 'the user sees the dashboard' }
    ])
    @store.check_criterion(@story['id'], 1, 'user exists in DB')
    # criterion 2 remains pending (unchecked)

    # Set up active-project and active-epic files in tmpdir so resolve_project_epic works
    FileUtils.mkdir_p(File.join(@tmpdir, '.tyrion'))
    File.write(File.join(@tmpdir, '.tyrion', 'active-project'), "myproj\n")
    File.write(File.join(@tmpdir, '.tyrion', 'active-epic'), "auth-epic\n")
    File.write(File.join(@tmpdir, '.tyrion', 'marker'), '')

    # Stub Repo to return our tmpdir paths
    @original_worktree_root = Tyrion::Repo.method(:worktree_root)
    @original_active_project = Tyrion::Repo.method(:active_project)
    @original_active_epic    = Tyrion::Repo.method(:active_epic)
    repo_root = @tmpdir
    Tyrion::Repo.define_singleton_method(:worktree_root)  { |*| repo_root }
    Tyrion::Repo.define_singleton_method(:active_project) { |*| 'myproj' }
    Tyrion::Repo.define_singleton_method(:active_epic)    { |*| 'auth-epic' }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    Tyrion::Repo.define_singleton_method(:worktree_root,  @original_worktree_root)
    Tyrion::Repo.define_singleton_method(:active_project, @original_active_project)
    Tyrion::Repo.define_singleton_method(:active_epic,    @original_active_epic)
  end

  def capture_pocket
    out, _err = capture_io { Tyrion::Commands.cmd_pocket([], @store) }
    out
  end

  def test_pocket_shows_epic_and_story_slugs
    output = capture_pocket
    assert_match(/^epic: auth-epic$/, output)
    assert_match(/^story: login-story$/, output)
  end

  def test_pocket_shows_unchecked_criterion
    output = capture_pocket
    assert_match(/\[\s*\]\s*Then\s+the user sees the dashboard/, output)
  end

  def test_pocket_does_not_show_met_criterion
    output = capture_pocket
    refute_match(/a registered user/, output)
  end

  def test_pocket_does_not_show_branch_worktree_dirty
    output = capture_pocket
    refute_match(/Branch:/, output)
    refute_match(/Worktree:/, output)
    refute_match(/Dirty:/, output)
  end

  def test_pocket_prefers_in_progress_story_over_pending
    # Start the story so it becomes in_progress
    @store.start_story(@story['id'])

    # Create a second pending story
    story2 = @store.create_story(epic_id: @epic['id'], slug: 'second-story', title: 'Second Story')
    @store.add_criteria(story2['id'], [
      { keyword: 'Then', semantic_kind: 'then', text: 'second story criterion' }
    ])

    output = capture_pocket
    assert_match(/^story: login-story$/, output)
    refute_match(/second-story/, output)
  end

  def test_pocket_falls_back_to_first_pending_when_no_in_progress
    output = capture_pocket
    assert_match(/^story: login-story$/, output)
  end

  def test_pocket_no_story_message
    # Abandon the only story so nothing is active or pending
    @store.update_story(@story['id'], 'status' => 'abandoned')

    out, _err = capture_io { Tyrion::Commands.cmd_pocket([], @store) }
    assert_match(/No active or pending story/, out)
  end
end
