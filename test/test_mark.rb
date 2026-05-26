# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../lib/tyrion'

class TestMark < Minitest::Test
  def setup
    @tmpdir  = Dir.mktmpdir('tyrion-mark-test-')
    @db_path = File.join(@tmpdir, 'test.db')
    @store   = Tyrion::Store.new(db_path: @db_path)

    @project = @store.create_project(slug: 'myproj', name: 'My Project')

    FileUtils.mkdir_p(File.join(@tmpdir, '.tyrion'))
    File.write(File.join(@tmpdir, '.tyrion', 'marker'), '')
    File.write(File.join(@tmpdir, '.tyrion', 'active-project'), "myproj\n")

    @orig_worktree_root  = Tyrion::Repo.method(:worktree_root)
    @orig_active_project = Tyrion::Repo.method(:active_project)
    @orig_active_epic    = Tyrion::Repo.method(:active_epic)
    @orig_git_branch     = Tyrion::Repo.method(:git_branch)
    @orig_dirty_count    = Tyrion::Repo.method(:dirty_count)
    @orig_last_commit    = Tyrion::Repo.method(:last_commit)

    repo_root = @tmpdir
    Tyrion::Repo.define_singleton_method(:worktree_root)  { |*| repo_root }
    Tyrion::Repo.define_singleton_method(:active_project) { |*| 'myproj' }
    Tyrion::Repo.define_singleton_method(:active_epic)    { |*| nil }
    Tyrion::Repo.define_singleton_method(:git_branch)     { |*| 'feature/test-branch' }
    Tyrion::Repo.define_singleton_method(:dirty_count)    { |*| 3 }
    Tyrion::Repo.define_singleton_method(:last_commit)    { |*| 'abc1234' }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    Tyrion::Repo.define_singleton_method(:worktree_root,  @orig_worktree_root)
    Tyrion::Repo.define_singleton_method(:active_project, @orig_active_project)
    Tyrion::Repo.define_singleton_method(:active_epic,    @orig_active_epic)
    Tyrion::Repo.define_singleton_method(:git_branch,     @orig_git_branch)
    Tyrion::Repo.define_singleton_method(:dirty_count,    @orig_dirty_count)
    Tyrion::Repo.define_singleton_method(:last_commit,    @orig_last_commit)
  end

  def test_mark_happy_path_stdout_and_store
    out, = capture_io do
      Tyrion::Commands.cmd_mark(['test description'], @store)
    end

    assert_match(/\[mark\] disc-\d+/, out)

    disc_id = out.match(/\[mark\] (disc-\d+)/)[1]
    disc = @store.find_discovery(disc_id)
    refute_nil disc, "find_discovery(#{disc_id}) should not be nil"

    assert_equal 'mark',             disc['status'],   "status should be 'mark'"
    assert_equal 'test description', disc['question'], "question should be 'test description'"

    git_ctx = JSON.parse(disc['git_context'])
    assert_equal 'feature/test-branch', git_ctx['branch'],      "branch mismatch"
    assert_equal 3,                     git_ctx['dirty_files'],  "dirty_files mismatch"
    assert_equal 'abc1234',             git_ctx['last_commit'],  "last_commit mismatch"
  end

  def test_mark_returns_unique_ids
    out1, = capture_io { Tyrion::Commands.cmd_mark(['first'], @store) }
    out2, = capture_io { Tyrion::Commands.cmd_mark(['second'], @store) }

    id1 = out1.match(/\[mark\] (disc-\d+)/)[1]
    id2 = out2.match(/\[mark\] (disc-\d+)/)[1]
    refute_equal id1, id2, "each mark should get a unique id"
  end

  def test_mark_no_active_project_prints_error
    Tyrion::Repo.define_singleton_method(:active_project) { |*| nil }
    out, = capture_io do
      Tyrion::Commands.cmd_mark(['anything'], @store)
    end
    assert_match(/no active project/i, out)
    assert_equal [], @store.list_discoveries(project_id: @project['id'])
  end
end
