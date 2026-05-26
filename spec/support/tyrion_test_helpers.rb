# frozen_string_literal: true

require 'stringio'

module TyrionTestHelpers
  TyrionContext = Struct.new(:tmpdir, :store, :project, :epic, keyword_init: true)

  REPO_DEFAULTS = {
    git_branch:    'main',
    dirty_count:   0,
    last_commit:   'deadbeef',
    touched_files: []
  }.freeze

  # Creates an isolated worktree: tmpdir + fresh Store + project (+ optional epic),
  # writes .tyrion/ marker files, stubs Tyrion::Repo via rspec-mocks (auto-restores).
  # Registers tmpdir for cleanup in after(:each).
  def tyrion_worktree(project_slug: 'myproj', project_name: 'My Project',
                      epic_slug: nil, epic_name: nil, **repo_overrides)
    tmpdir = Dir.mktmpdir('tyrion-spec-')
    (@_tyrion_tmpdirs ||= []) << tmpdir

    store   = Tyrion::Store.new(db_path: File.join(tmpdir, 'test.db'))
    project = store.create_project(slug: project_slug, name: project_name)
    epic    = epic_slug && store.create_epic(
      project_id: project['id'], slug: epic_slug, name: epic_name || epic_slug
    )

    FileUtils.mkdir_p(File.join(tmpdir, '.tyrion'))
    File.write(File.join(tmpdir, '.tyrion', 'marker'), '')
    File.write(File.join(tmpdir, '.tyrion', 'active-project'), "#{project_slug}\n")
    File.write(File.join(tmpdir, '.tyrion', 'active-epic'), "#{epic_slug}\n") if epic_slug

    stub_repo(
      worktree_root:  tmpdir,
      active_project: project_slug,
      active_epic:    epic_slug,
      **REPO_DEFAULTS,
      **repo_overrides
    )

    TyrionContext.new(tmpdir: tmpdir, store: store, project: project, epic: epic)
  end

  # Stub Tyrion::Repo module methods via rspec-mocks. Auto-restores at end of example.
  def stub_repo(**overrides)
    overrides.each { |m, v| allow(Tyrion::Repo).to receive(m).and_return(v) }
  end

  # Capture stdout + stderr from a block. Saves current $stdout/$stderr (not constants)
  # so it composes with nested capture_io calls. Returns [stdout_str, stderr_str].
  def capture_io
    orig_out, orig_err = $stdout, $stderr
    out, err = StringIO.new, StringIO.new
    $stdout, $stderr = out, err
    yield
    [out.string, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end
end

RSpec.configure do |config|
  config.include TyrionTestHelpers

  # rspec-mocks restores Repo stubs automatically; we only need to clean up tmpdirs.
  config.after(:each) do
    Array(@_tyrion_tmpdirs).each { |d| FileUtils.rm_rf(d) }
    @_tyrion_tmpdirs = nil
  end
end
