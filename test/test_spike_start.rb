# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'stringio'
require_relative '../lib/tyrion'

class TestSpikeStart < Minitest::Test
  def setup
    @tmpdir  = Dir.mktmpdir('tyrion-spike-start-test-')
    @db_path = File.join(@tmpdir, 'test.db')
    @store   = Tyrion::Store.new(db_path: @db_path)

    @project = @store.create_project(slug: 'myproj', name: 'My Project')

    FileUtils.mkdir_p(File.join(@tmpdir, '.tyrion'))
    File.write(File.join(@tmpdir, '.tyrion', 'marker'), '')
    File.write(File.join(@tmpdir, '.tyrion', 'active-project'), "myproj\n")

    repo_root = @tmpdir
    Tyrion::Repo.define_singleton_method(:worktree_root)  { |*| repo_root }
    Tyrion::Repo.define_singleton_method(:active_project) { |*| 'myproj' }
    Tyrion::Repo.define_singleton_method(:active_epic)    { |*| nil }
    Tyrion::Repo.define_singleton_method(:git_branch)     { |*| 'feature/scan-worker' }
    Tyrion::Repo.define_singleton_method(:dirty_count)    { |*| 3 }
    Tyrion::Repo.define_singleton_method(:last_commit)    { |*| 'cafebabe' }
    Tyrion::Repo.define_singleton_method(:touched_files)  { |*| ['lib/tyrion/store.rb', 'lib/tyrion/commands.rb'] }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    %i[worktree_root active_project active_epic git_branch dirty_count last_commit touched_files].each do |m|
      Tyrion::Repo.singleton_class.remove_method(m)
    end
  end

  # Criterion 1 — happy path
  def test_spike_start_happy_path
    input  = StringIO.new("Yes, if two workers read\nReproducing test case showing duplicates\n")
    output = StringIO.new

    Tyrion::Commands.cmd_spike_start(
      ['Can concurrent writes cause scan duplication?'],
      @store,
      input: input,
      output: output
    )

    out = output.string
    assert_match(/\[active_spike\] disc-\d+/, out)

    disc_id = out.match(/\[active_spike\] (disc-\d+)/)[1]
    disc = @store.find_discovery(disc_id)
    refute_nil disc, "find_discovery(#{disc_id}) should not be nil"

    assert_equal 'active_spike',                               disc['status'],        'status mismatch'
    assert_equal 'Can concurrent writes cause scan duplication?', disc['question'],   'question mismatch'
    assert_equal 'Yes, if two workers read',                   disc['hypothesis'],    'hypothesis mismatch'
    assert_equal 'Reproducing test case showing duplicates',   disc['exit_criteria'], 'exit_criteria mismatch'

    git_ctx = JSON.parse(disc['git_context'])
    assert_equal 'feature/scan-worker',                                    git_ctx['branch'],        'branch mismatch'
    assert_equal 3,                                                        git_ctx['dirty_files'],   'dirty_files mismatch'
    assert_equal 'cafebabe',                                               git_ctx['last_commit'],   'last_commit mismatch'
    assert_equal ['lib/tyrion/store.rb', 'lib/tyrion/commands.rb'],        git_ctx['touched_files'], 'touched_files mismatch'
  end

  # Criterion 2 — one active spike enforced
  def test_spike_start_enforces_one_active_spike
    # Create an existing active_spike discovery
    existing = @store.create_discovery(
      project_id: @project['id'],
      status:     'active_spike',
      question:   'existing question about concurrency'
    )

    _, err = capture_io do
      assert_raises(SystemExit) do
        Tyrion::Commands.cmd_spike_start(['another question'], @store)
      end
    end

    assert_match(/#{existing['id']}/, err)
    assert_match(/existing question about concurrency/, err)

    # No new row created — still only 1 active_spike
    spikes = @store.list_discoveries(project_id: @project['id'], status: 'active_spike')
    assert_equal 1, spikes.length, 'should not have created a second active_spike'
  end

  # Criterion 3 — blank inputs store nil
  def test_spike_start_blank_inputs_store_nil
    input  = StringIO.new("\n\n")
    output = StringIO.new

    Tyrion::Commands.cmd_spike_start(
      ['question'],
      @store,
      input: input,
      output: output
    )

    out = output.string
    assert_match(/\[active_spike\] disc-\d+/, out)

    disc_id = out.match(/\[active_spike\] (disc-\d+)/)[1]
    disc = @store.find_discovery(disc_id)
    refute_nil disc

    assert_equal 'active_spike', disc['status'],       'status mismatch'
    assert_equal 'question',     disc['question'],     'question mismatch'
    assert_nil disc['hypothesis'],    'hypothesis should be nil'
    assert_nil disc['exit_criteria'], 'exit_criteria should be nil'
  end
end
