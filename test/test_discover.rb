# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'stringio'
require_relative '../lib/tyrion'

class TestDiscover < Minitest::Test
  def setup
    @tmpdir  = Dir.mktmpdir('tyrion-discover-test-')
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
    @orig_touched_files  = Tyrion::Repo.method(:touched_files)

    repo_root = @tmpdir
    Tyrion::Repo.define_singleton_method(:worktree_root)  { |*| repo_root }
    Tyrion::Repo.define_singleton_method(:active_project) { |*| 'myproj' }
    Tyrion::Repo.define_singleton_method(:active_epic)    { |*| nil }
    Tyrion::Repo.define_singleton_method(:git_branch)     { |*| 'feature/auth-flow' }
    Tyrion::Repo.define_singleton_method(:dirty_count)    { |*| 2 }
    Tyrion::Repo.define_singleton_method(:last_commit)    { |*| 'deadbeef' }
    Tyrion::Repo.define_singleton_method(:touched_files)  { |*| ['lib/tyrion/commands.rb', 'lib/tyrion/repo.rb'] }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    Tyrion::Repo.define_singleton_method(:worktree_root,  @orig_worktree_root)
    Tyrion::Repo.define_singleton_method(:active_project, @orig_active_project)
    Tyrion::Repo.define_singleton_method(:active_epic,    @orig_active_epic)
    Tyrion::Repo.define_singleton_method(:git_branch,     @orig_git_branch)
    Tyrion::Repo.define_singleton_method(:dirty_count,    @orig_dirty_count)
    Tyrion::Repo.define_singleton_method(:last_commit,    @orig_last_commit)
    Tyrion::Repo.define_singleton_method(:touched_files,  @orig_touched_files)
  end

  def test_discover_happy_path_criterion_1
    input  = StringIO.new("testing authentication flow\nJWT expiry not refreshed on activity\nlater\n")
    output = StringIO.new
    Tyrion::Commands.cmd_discover([], @store, input: input, output: output)
    out = output.string

    # stdout contains [findings_ready] disc-NNN
    assert_match(/\[findings_ready\] disc-\d+/, out)

    disc_id = out.match(/\[findings_ready\] (disc-\d+)/)[1]
    disc = @store.find_discovery(disc_id)
    refute_nil disc, "find_discovery(#{disc_id}) should not be nil"

    assert_equal 'findings_ready',                      disc['status'],   "status mismatch"
    assert_equal 'testing authentication flow',         disc['question'], "question mismatch"
    assert_equal 'JWT expiry not refreshed on activity', disc['finding'], "finding mismatch"

    git_ctx = JSON.parse(disc['git_context'])
    assert_equal 'feature/auth-flow',                             git_ctx['branch'],        "branch mismatch"
    assert_equal 2,                                               git_ctx['dirty_files'],   "dirty_files mismatch"
    assert_equal 'deadbeef',                                      git_ctx['last_commit'],   "last_commit mismatch"
    assert_equal ['lib/tyrion/commands.rb', 'lib/tyrion/repo.rb'], git_ctx['touched_files'], "touched_files mismatch"
  end

  def test_discover_no_active_project_exits
    Tyrion::Repo.define_singleton_method(:active_project) { |*| nil }
    assert_raises(SystemExit) do
      Tyrion::Commands.cmd_discover([], @store)
    end
    assert_equal [], @store.list_discoveries(project_id: @project['id'])
  end

  def test_discover_promote_hint_printed_when_user_answers_y
    input  = StringIO.new("what am I building?\nfound the answer\ny\n")
    output = StringIO.new
    Tyrion::Commands.cmd_discover([], @store, input: input, output: output)
    out = output.string

    disc_id = out.match(/\[findings_ready\] (disc-\d+)/)[1]
    assert_match(/tyrion spike promote #{disc_id}/, out)
  end

  def test_discover_no_promote_hint_when_user_answers_later
    input  = StringIO.new("exploring\nfound something\nlater\n")
    output = StringIO.new
    Tyrion::Commands.cmd_discover([], @store, input: input, output: output)
    out = output.string

    refute_match(/tyrion spike promote/, out)
  end
end
