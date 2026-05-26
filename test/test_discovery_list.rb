# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require_relative '../lib/tyrion'

class TestDiscoveryList < Minitest::Test
  def setup
    @tmpdir  = Dir.mktmpdir('tyrion-discovery-list-test-')
    @db_path = File.join(@tmpdir, 'test.db')
    @store   = Tyrion::Store.new(db_path: @db_path)

    @project = @store.create_project(slug: 'myproj', name: 'My Project')
    @store.create_epic(project_id: @project['id'], slug: 'epic-1', name: 'Epic One')

    # Create three discoveries with different statuses
    @disc_mark = @store.create_discovery(
      project_id: @project['id'],
      status:     'mark',
      question:   'Is this worth exploring?'
    )
    @disc_spike = @store.create_discovery(
      project_id: @project['id'],
      status:     'active_spike',
      question:   'Can we cache the results?'
    )
    @disc_ready = @store.create_discovery(
      project_id:     @project['id'],
      status:         'findings_ready',
      question:       'What is the optimal batch size?',
      finding:        'Batch size of 100 yields best throughput',
      confidence:     'high',
      recommendation: 'Use batch size 100 in production'
    )

    FileUtils.mkdir_p(File.join(@tmpdir, '.tyrion'))
    File.write(File.join(@tmpdir, '.tyrion', 'marker'), '')
    File.write(File.join(@tmpdir, '.tyrion', 'active-project'), "myproj\n")
    File.write(File.join(@tmpdir, '.tyrion', 'active-epic'), "epic-1\n")

    Tyrion::Repo.define_singleton_method(:worktree_root)  { |*| @tmpdir }
    Tyrion::Repo.define_singleton_method(:active_project) { |*| 'myproj' }
    Tyrion::Repo.define_singleton_method(:active_epic)    { |*| 'epic-1' }
    Tyrion::Repo.define_singleton_method(:git_branch)     { |*| 'main' }
    Tyrion::Repo.define_singleton_method(:dirty_count)    { |*| 0 }
    Tyrion::Repo.define_singleton_method(:last_commit)    { |*| 'deadbeef' }
    Tyrion::Repo.define_singleton_method(:touched_files)  { |*| [] }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  ensure
    %i[worktree_root active_project active_epic git_branch dirty_count last_commit touched_files].each do |m|
      Tyrion::Repo.singleton_class.remove_method(m) if Tyrion::Repo.singleton_class.method_defined?(m)
    end
  end

  def test_discovery_list_status_filter
    out, _err = capture_io { Tyrion::Commands.cmd_discovery_list(['--status', 'ready'], @store) }

    assert_match @disc_ready['id'], out
    refute_match @disc_mark['id'],  out
    refute_match @disc_spike['id'], out
    assert_match 'findings_ready',  out
    assert_match 'What is the optimal batch size?', out
  end

  def test_discovery_list_no_filter_shows_all
    out, _err = capture_io { Tyrion::Commands.cmd_discovery_list([], @store) }

    assert_match @disc_mark['id'],  out
    assert_match @disc_spike['id'], out
    assert_match @disc_ready['id'], out
  end

  def test_discovery_show_full_detail
    disc_id = @disc_ready['id']
    out, _err = capture_io { Tyrion::Commands.cmd_discovery_show([disc_id], @store) }

    assert_match disc_id,                                    out
    assert_match 'findings_ready',                           out
    assert_match 'What is the optimal batch size?',          out
    assert_match 'Batch size of 100 yields best throughput', out
    assert_match 'high',                                     out
    assert_match 'Use batch size 100 in production',         out
  end

  def test_discovery_show_unknown_id
    _out, err = capture_io do
      assert_raises(SystemExit) { Tyrion::Commands.cmd_discovery_show(['disc-999'], @store) }
    end

    assert_match 'disc-999',  err
    assert_match 'not found', err
  end

  def test_discovery_list_invalid_status_alias
    _out, err = capture_io do
      assert_raises(SystemExit) { Tyrion::Commands.cmd_discovery_list(['--status', 'bogus'], @store) }
    end

    assert_match 'bogus',    err
    assert_match 'active',   err
    assert_match 'ready',    err
    assert_match 'promoted', err
    assert_match 'deferred', err
    assert_match 'all',      err
  end

  def test_discovery_dispatch_unknown_subcommand
    _out, err = capture_io do
      assert_raises(SystemExit) { Tyrion::Commands.run(['discovery', 'bogus']) }
    end
    assert_match 'tyrion discovery', err
  end
end
