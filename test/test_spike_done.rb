# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require_relative '../lib/tyrion'

class TestSpikeDone < Minitest::Test
  def setup
    @tmpdir  = Dir.mktmpdir('tyrion-spike-done-test-')
    @db_path = File.join(@tmpdir, 'test.db')
    @store   = Tyrion::Store.new(db_path: @db_path)

    @project = @store.create_project(slug: 'myproj', name: 'My Project')

    @store.create_discovery(
      project_id: @project['id'],
      status:     'active_spike',
      question:   'Can concurrent writes cause scan duplication?'
    )

    FileUtils.mkdir_p(File.join(@tmpdir, '.tyrion'))
    File.write(File.join(@tmpdir, '.tyrion', 'marker'), '')
    File.write(File.join(@tmpdir, '.tyrion', 'active-project'), "myproj\n")

    Tyrion::Repo.define_singleton_method(:worktree_root)  { |*| @tmpdir }
    Tyrion::Repo.define_singleton_method(:active_project) { |*| 'myproj' }
    Tyrion::Repo.define_singleton_method(:active_epic)    { |*| nil }
    Tyrion::Repo.define_singleton_method(:git_branch)     { |*| 'feature/scan-worker' }
    Tyrion::Repo.define_singleton_method(:dirty_count)    { |*| 0 }
    Tyrion::Repo.define_singleton_method(:last_commit)    { |*| 'deadbeef' }
    Tyrion::Repo.define_singleton_method(:touched_files)  { |*| [] }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    %i[worktree_root active_project active_epic git_branch dirty_count last_commit touched_files].each do |m|
      Tyrion::Repo.singleton_class.remove_method(m)
    end
  end

  # Criterion 1 — happy path
  def test_spike_done_happy_path
    input  = StringIO.new("Concurrent writes do cause duplication\nhigh\nUse a mutex\n")
    output = StringIO.new

    Tyrion::Commands.cmd_spike_done([], @store, input: input, output: output)

    out = output.string
    assert_match(/\[findings_ready\] disc-\d+/, out)

    disc_id = out.match(/\[findings_ready\] (disc-\d+)/)[1]
    disc = @store.find_discovery(disc_id)
    refute_nil disc

    assert_equal 'findings_ready',                          disc['status'],         'status mismatch'
    assert_equal 'Concurrent writes do cause duplication',  disc['finding'],        'finding mismatch'
    assert_equal 'high',                                    disc['confidence'],     'confidence mismatch'
    assert_equal 'Use a mutex',                             disc['recommendation'], 'recommendation mismatch'
  end

  # Criterion 2 — no active spike
  def test_spike_done_no_active_spike_exits
    other = @store.create_project(slug: 'other', name: 'Other')
    Tyrion::Repo.define_singleton_method(:active_project) { |*| 'other' }

    _, err = capture_io do
      assert_raises(SystemExit) do
        Tyrion::Commands.cmd_spike_done([], @store)
      end
    end

    assert_match(/[Nn]o active spike/, err)
    assert_equal [], @store.list_discoveries(project_id: other['id'], status: 'findings_ready')
  end

  # Criterion 3 — confidence re-prompt on invalid input
  def test_spike_done_reprompts_invalid_confidence
    # finding first, then invalid confidence values, then valid, then recommendation
    input  = StringIO.new("finding text\nbadvalue\nalsobad\nmedium\nrec text\n")
    output = StringIO.new

    Tyrion::Commands.cmd_spike_done([], @store, input: input, output: output)

    out = output.string
    assert_match(/\[findings_ready\] disc-\d+/, out)

    disc_id = out.match(/\[findings_ready\] (disc-\d+)/)[1]
    disc = @store.find_discovery(disc_id)
    refute_nil disc

    assert_equal 'findings_ready', disc['status'],     'status mismatch'
    assert_equal 'medium',         disc['confidence'], 'confidence mismatch'
    assert_equal 'finding text',   disc['finding'],    'finding mismatch'
    assert_equal 'rec text',       disc['recommendation'], 'recommendation mismatch'
  end
end
