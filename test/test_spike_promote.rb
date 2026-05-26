# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require_relative '../lib/tyrion'

class TestSpikePromote < Minitest::Test
  def setup
    @tmpdir  = Dir.mktmpdir('tyrion-spike-promote-test-')
    @db_path = File.join(@tmpdir, 'test.db')
    @store   = Tyrion::Store.new(db_path: @db_path)

    @project = @store.create_project(slug: 'myproj', name: 'My Project')
    @epic    = @store.create_epic(project_id: @project['id'], slug: 'myepic', name: 'My Epic')

    FileUtils.mkdir_p(File.join(@tmpdir, '.tyrion'))
    File.write(File.join(@tmpdir, '.tyrion', 'marker'), '')
    File.write(File.join(@tmpdir, '.tyrion', 'active-project'), "myproj\n")
    File.write(File.join(@tmpdir, '.tyrion', 'active-epic'), "myepic\n")

    Tyrion::Repo.define_singleton_method(:worktree_root)  { |*| @tmpdir }
    Tyrion::Repo.define_singleton_method(:active_project) { |*| 'myproj' }
    Tyrion::Repo.define_singleton_method(:active_epic)    { |*| 'myepic' }
    Tyrion::Repo.define_singleton_method(:git_branch)     { |*| 'feature/spike-promote' }
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

  def test_spike_promote_happy_path
    disc = @store.create_discovery(
      project_id:     @project['id'],
      status:         'findings_ready',
      question:       'Q?',
      recommendation: 'Use mutex',
      finding:        'Concurrent writes conflict'
    )
    disc_id = disc['id']

    input  = StringIO.new("Concurrent Write Safety\n")
    output = StringIO.new

    Tyrion::Commands.cmd_spike_promote([disc_id], @store, input: input, output: output)

    out = output.string

    assert_match(/\[promoted\] \S+ <- #{Regexp.escape(disc_id)}/, out)
    assert_includes out, 'tyrion criteria add'
    assert(out.include?('Concurrent writes conflict') || out.include?('Use mutex'),
           "Expected output to include finding or recommendation text, got:\n#{out}")

    updated_disc = @store.find_discovery(disc_id)
    assert_equal 'promoted_to_story', updated_disc['status']

    slug = out.match(/\[promoted\] (\S+) <-/)[1]

    story = @store.find_story(@epic['id'], slug)
    refute_nil story, "Expected to find story with slug #{slug}"

    assert_equal disc_id,               story['born_from_discovery']
    assert_equal 'Concurrent Write Safety', story['title']
    assert_includes story['intent'],    'Use mutex'
  end

  def test_spike_promote_unknown_disc_id
    _out, err = capture_io do
      assert_raises(SystemExit) { Tyrion::Commands.cmd_spike_promote(['disc-999'], @store) }
    end

    assert_includes err, 'disc-999'
    assert_match(/not found/i, err)
    assert_empty @store.stories_for_epic(@epic['id'])
  end

  def test_spike_promote_blank_title_defaults_to_question
    disc = @store.create_discovery(
      project_id:     @project['id'],
      status:         'findings_ready',
      question:       'What causes the duplication?',
      recommendation: 'Some rec'
    )
    disc_id = disc['id']

    input  = StringIO.new("\n")
    output = StringIO.new

    Tyrion::Commands.cmd_spike_promote([disc_id], @store, input: input, output: output)

    out = output.string

    assert_match(/\[promoted\] \S+ <- disc-\d+/, out)

    slug = out.match(/\[promoted\] (\S+) <-/)[1]

    story = @store.find_story(@epic['id'], slug)
    refute_nil story, "Expected to find story with slug #{slug}"

    assert_equal 'What causes the duplication?', story['title']
  end

  def test_spike_promote_error_on_non_findings_ready
    disc = @store.create_discovery(
      project_id: @project['id'],
      status:     'active_spike',
      question:   'some question'
    )
    disc_id = disc['id']

    _out, err = capture_io do
      assert_raises(SystemExit) { Tyrion::Commands.cmd_spike_promote([disc_id], @store) }
    end

    assert_match(/#{Regexp.escape(disc_id)}/, err)
    assert_match(/findings_ready/, err)

    assert_empty @store.stories_for_epic(@epic['id']), "Expected no story to be created"
  end
end
