# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require_relative '../lib/tyrion'

class TestOrientExt < Minitest::Test
  def setup
    @tmpdir  = Dir.mktmpdir('tyrion-orient-ext-test-')
    @db_path = File.join(@tmpdir, 'test.db')
    @store   = Tyrion::Store.new(db_path: @db_path)

    @project = @store.create_project(slug: 'oriproj', name: 'Orient Project')
    @epic    = @store.create_epic(project_id: @project['id'], slug: 'ori-epic', name: 'Orient Epic')

    FileUtils.mkdir_p(File.join(@tmpdir, '.tyrion'))
    File.write(File.join(@tmpdir, '.tyrion', 'marker'), '')
    File.write(File.join(@tmpdir, '.tyrion', 'active-project'), "oriproj\n")
    File.write(File.join(@tmpdir, '.tyrion', 'active-epic'), "ori-epic\n")

    tmpdir = @tmpdir
    Tyrion::Repo.define_singleton_method(:worktree_root)  { |*| tmpdir }
    Tyrion::Repo.define_singleton_method(:active_project) { |*| 'oriproj' }
    Tyrion::Repo.define_singleton_method(:active_epic)    { |*| 'ori-epic' }
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

  def test_active_spike_shows_in_discoveries
    disc = @store.create_discovery(
      project_id: @project['id'],
      status:     'active_spike',
      question:   'Can cache be shared?'
    )

    out, = capture_io { Tyrion::Commands.cmd_status([], @store) }

    assert_includes out, 'DISCOVERIES'
    assert_includes out, disc['id']
    assert_includes out, 'Can cache be shared?'
  end

  def test_findings_ready_shows_promote_hint
    disc = @store.create_discovery(
      project_id: @project['id'],
      status:     'findings_ready',
      question:   'Is Redis faster than memcached?'
    )

    out, = capture_io { Tyrion::Commands.cmd_status([], @store) }

    assert_includes out, disc['id']
    assert_includes out, "tyrion spike promote #{disc['id']}"
  end

  def test_mark_count_shows_as_exact_substring
    2.times do |i|
      @store.create_discovery(
        project_id: @project['id'],
        status:     'mark',
        question:   "Mark note #{i}"
      )
    end

    out, = capture_io { Tyrion::Commands.cmd_status([], @store) }

    assert_includes out, '2 unformalized mark'
  end

  def test_no_discoveries_means_no_discoveries_section
    out, = capture_io { Tyrion::Commands.cmd_status([], @store) }

    refute_includes out, 'DISCOVERIES'
  end

  def test_mixed_types_all_appear
    spike_disc = @store.create_discovery(
      project_id: @project['id'],
      status:     'active_spike',
      question:   'Q1?'
    )
    findings_disc = @store.create_discovery(
      project_id: @project['id'],
      status:     'findings_ready',
      question:   'Q2?'
    )
    2.times do |i|
      @store.create_discovery(
        project_id: @project['id'],
        status:     'mark',
        question:   "Mark #{i}"
      )
    end

    out, = capture_io { Tyrion::Commands.cmd_status([], @store) }

    assert_includes out, 'DISCOVERIES'
    assert_includes out, spike_disc['id']
    assert_includes out, 'Q1?'
    assert_includes out, findings_disc['id']
    assert_includes out, "tyrion spike promote #{findings_disc['id']}"
    assert_includes out, '2 unformalized mark'
  end
end
