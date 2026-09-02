# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'

RSpec.describe 'tyrion epic-context show' do
  let(:ctx)   { tyrion_worktree(project_slug: 'ecproj', epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:root)  { ctx.tmpdir }

  let(:org_body) { "#+TITLE: my-epic wiki\n\n* Verified facts\n- a fact\n\n* Learnings\n** a learning :s1_2:\n" }
  let(:org_path) { File.join(root, 'features', 'my-epic.context.org') }
  let(:md_path)  { File.join(root, 'features', 'my-epic.context.md') }

  before do
    FileUtils.mkdir_p(File.join(root, 'features'))
    # main_root resolves to the same tmpdir the worktree helper set up, so the
    # command's absolute-path resolution is exercised without a real git repo.
    stub_repo(main_root: root)
  end

  def show(*args)
    capture_io { Tyrion::Commands.cmd_epic_context(['show', *args], store) }
  end

  # `die` paths are asserted with RSpec's output matcher, which only wraps one
  # stream — capture_io would swallow the stderr the matcher is looking for.
  # This keeps stdout (the path line printed before the die) out of the test
  # log without touching stderr.
  def show_quietly(*args)
    orig = $stdout
    $stdout = StringIO.new
    Tyrion::Commands.cmd_epic_context(['show', *args], store)
  ensure
    $stdout = orig
  end

  describe 'with no arguments' do
    before { File.write(org_path, org_body) }

    it 'prints the absolute context path on the first line' do
      out, = show
      expect(out.lines.first.strip).to eq org_path
    end

    it 'prints the whole file after the path line' do
      out, = show
      expect(out).to include org_body
    end

    it 'never shells out to orgkit when no story slice was requested' do
      expect(Tyrion::Orgkit).not_to receive(:run)
      show
    end
  end

  describe '--story' do
    before { File.write(org_path, org_body) }

    it 'shells to orgkit sections with the story slug mapped hyphen to underscore' do
      expect(Tyrion::Orgkit).to receive(:run)
        .with('sections', org_path, '--tag', 's1_2', '--include-untagged')
        .and_return(['** a learning :s1_2:', '', instance_double(Process::Status, success?: true)])

      show('--story', 's1-2')
    end

    it 'prints orgkit output verbatim after the path line' do
      allow(Tyrion::Orgkit).to receive(:run)
        .and_return(["** a learning :s1_2:\n", '', instance_double(Process::Status, success?: true)])

      out, = show('--story', 's1-2')
      expect(out.lines.first.strip).to eq org_path
      expect(out).to include '** a learning :s1_2:'
    end

    it 'does not print the whole file when a slice was requested' do
      allow(Tyrion::Orgkit).to receive(:run)
        .and_return(["** a learning :s1_2:\n", '', instance_double(Process::Status, success?: true)])

      out, = show('--story', 's1-2')
      expect(out).not_to include 'Verified facts'
    end

    it 'dies with an install hint rather than an Errno backtrace when orgkit is missing' do
      allow(Tyrion::Orgkit).to receive(:run).and_raise(Errno::ENOENT)

      expect { show_quietly('--story', 's1-2') }.to raise_error(SystemExit)
        .and output(/orgkit is not installed or not on PATH/).to_stderr
    end

    it 'surfaces orgkit stderr verbatim and exits 1 on a non-zero exit' do
      allow(Tyrion::Orgkit).to receive(:run)
        .and_return(['', "orgkit: no such file\n", instance_double(Process::Status, success?: false)])

      expect { show_quietly('--story', 's1-2') }.to raise_error(SystemExit)
        .and output(/orgkit: no such file/).to_stderr
    end
  end

  describe '--epic' do
    it 'selects a different epic than the active one' do
      store.create_epic(project_id: ctx.project['id'], slug: 'other-epic', name: 'Other')
      other = File.join(root, 'features', 'other-epic.context.org')
      File.write(other, "* Other wiki\n")

      out, = show('--epic', 'other-epic')
      expect(out.lines.first.strip).to eq other
      expect(out).to include 'Other wiki'
    end

    it 'exits 1 with a clear message for an unknown epic slug' do
      expect { show_quietly('--epic', 'nope') }.to raise_error(SystemExit)
        .and output(/Epic not found: nope/).to_stderr
    end
  end

  it 'exits 1 with a clear message when the epic has no context file' do
    expect { show_quietly }.to raise_error(SystemExit)
      .and output(/No context file for epic 'my-epic'/).to_stderr
  end

  describe 'a .context.md epic' do
    before { File.write(md_path, "# my-epic wiki\n\nlegacy markdown\n") }

    it 'prints the whole file' do
      out, = show
      expect(out).to include 'legacy markdown'
    end

    it 'prints a one-line note instead of failing when --story is requested' do
      out, err = show('--story', 's1-2')
      expect(err).to eq ''
      expect(out).to match(/story slicing needs an \.org context file/)
      expect(out).to include 'legacy markdown'
    end

    it 'never shells out to orgkit for a markdown wiki' do
      expect(Tyrion::Orgkit).not_to receive(:run)
      show('--story', 's1-2')
    end
  end

  describe 'flag hygiene' do
    before { File.write(org_path, org_body) }

    it 'rejects an unknown flag rather than folding it into the slice' do
      expect { show_quietly('--nope', 'x') }.to raise_error(SystemExit)
        .and output(/Unknown flag --nope/).to_stderr
    end

    it 'prints the group usage for --help' do
      out, = capture_io { Tyrion::Commands.cmd_epic_context(['--help'], store) }
      expect(out).to match(/Usage: tyrion epic-context/)
    end
  end
end

RSpec.describe 'Tyrion::Commands.org_tag_for' do
  it 'maps hyphens to underscores because org tags cannot contain a hyphen' do
    expect(Tyrion::Commands.org_tag_for('s1-2')).to eq 's1_2'
  end

  it 'leaves an already-valid tag untouched' do
    expect(Tyrion::Commands.org_tag_for('s1_2')).to eq 's1_2'
  end
end

# The real binary, not the seam. Skipped until orgkit's `sections
# --include-untagged` (own-body semantics, built by the orgkit lane) is
# installed, so this spec never turns red for work that lives in another repo.
RSpec.describe 'tyrion epic-context show against the real orgkit binary' do
  # Word-boundary guard: the long-standing --include-untagged-top-level flag
  # must NOT satisfy a check for --include-untagged.
  INCLUDE_UNTAGGED = /--include-untagged(?![-\w])/.freeze

  let(:ctx)   { tyrion_worktree(project_slug: 'ecproj', epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:root)  { ctx.tmpdir }

  before do
    skip 'orgkit sections --include-untagged is not installed' unless orgkit_supports?('sections', INCLUDE_UNTAGGED)
    FileUtils.mkdir_p(File.join(root, 'features'))
    stub_repo(main_root: root)
    File.write(
      File.join(root, 'features', 'my-epic.context.org'),
      "* Verified facts\n- an untagged fact\n\n* Learnings\n** a tagged learning :s1_2:\n"
    )
  end

  it 'slices the real file down to the story tag plus untagged context' do
    out, err = capture_io do
      Tyrion::Commands.cmd_epic_context(['show', '--story', 's1-2'], store)
    end

    expect(err).to eq ''
    expect(out).to include 'a tagged learning'
  end
end
