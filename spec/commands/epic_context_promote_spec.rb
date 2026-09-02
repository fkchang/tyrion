# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'tmpdir'

RSpec.describe 'tyrion epic-context promote' do
  let(:ctx)   { tyrion_worktree(project_slug: 'prproj', epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:root)  { ctx.tmpdir }

  let(:src_path)  { File.join(root, 'features', 'my-epic.context.org') }
  let(:dest_path) { File.join(root, 'features', 'parent-epic.context.org') }
  let(:md_path)   { File.join(root, 'features', 'my-epic.context.md') }

  let(:ok)     { instance_double(Process::Status, success?: true) }
  let(:failed) { instance_double(Process::Status, success?: false) }

  before do
    FileUtils.mkdir_p(File.join(root, 'features'))
    stub_repo(main_root: root)
    File.write(src_path, "#+TITLE: my-epic\n\n* Learnings\n** a portable truth :s1_2:\n")
  end

  def promote(*args)
    capture_io { Tyrion::Commands.cmd_epic_context(['promote', *args], store) }
  end

  def promote_quietly(*args)
    orig = $stdout
    $stdout = StringIO.new
    Tyrion::Commands.cmd_epic_context(['promote', *args], store)
  ensure
    $stdout = orig
  end

  def epic_row(slug)
    store.find_epic(ctx.project['id'], slug)
  end

  describe 'the orgkit refile invocation' do
    before { File.write(dest_path, "* Learnings\n") }

    it 'refiles into <dest>::<under> with provenance stamped and inherited tags materialized' do
      expect(Tyrion::Orgkit).to receive(:run).with(
        'refile', src_path, 'a portable truth', "#{dest_path}::Learnings",
        '--materialize-inherited-tags', '--stamp', 'promoted_from=my-epic'
      ).and_return(['', '', ok])

      promote('a portable truth', '--to', 'parent-epic')
    end

    it 'honors an explicit --under' do
      expect(Tyrion::Orgkit).to receive(:run).with(
        'refile', src_path, 'a portable truth', "#{dest_path}::Verified facts",
        '--materialize-inherited-tags', '--stamp', 'promoted_from=my-epic'
      ).and_return(['', '', ok])

      promote('a portable truth', '--to', 'parent-epic', '--under', 'Verified facts')
    end

    it "prints orgkit's stdout and then names both files" do
      allow(Tyrion::Orgkit).to receive(:run).and_return(["moved\n", '', ok])

      out, = promote('a portable truth', '--to', 'parent-epic')
      expect(out).to include 'moved'
      expect(out).to include dest_path
    end

    it 'dies with usage when no heading is given' do
      expect { promote_quietly('--to', 'parent-epic') }.to raise_error(SystemExit)
        .and output(/Usage: tyrion epic-context promote/).to_stderr
    end

    it 'dies with usage when --to is missing' do
      expect { promote_quietly('a portable truth') }.to raise_error(SystemExit)
        .and output(/Usage: tyrion epic-context promote/).to_stderr
    end
  end

  describe '--to resolution' do
    it 'treats a bare slug as features/<slug>.context.org under the main root' do
      File.write(dest_path, "* Learnings\n")
      expect(Tyrion::Orgkit).to receive(:run)
        .with('refile', src_path, 'h', "#{dest_path}::Learnings", any_args)
        .and_return(['', '', ok])

      promote('h', '--to', 'parent-epic')
    end

    it 'treats a value containing a slash as a path, relative to the main checkout' do
      other = File.join(root, 'docs', 'system.org')
      FileUtils.mkdir_p(File.dirname(other))
      File.write(other, "* Learnings\n")
      expect(Tyrion::Orgkit).to receive(:run)
        .with('refile', src_path, 'h', "#{other}::Learnings", any_args)
        .and_return(['', '', ok])

      promote('h', '--to', 'docs/system.org')
    end

    it 'accepts an absolute path unchanged' do
      other = File.join(root, 'docs', 'system.org')
      FileUtils.mkdir_p(File.dirname(other))
      File.write(other, "* Learnings\n")
      expect(Tyrion::Orgkit).to receive(:run)
        .with('refile', src_path, 'h', "#{other}::Learnings", any_args)
        .and_return(['', '', ok])

      promote('h', '--to', other)
    end

    it 'treats a bare .org filename as a path, not a slug' do
      other = File.join(root, 'system.org')
      File.write(other, "* Learnings\n")
      expect(Tyrion::Orgkit).to receive(:run)
        .with('refile', src_path, 'h', "#{other}::Learnings", any_args)
        .and_return(['', '', ok])

      promote('h', '--to', 'system.org')
    end

    it 'exits 1 naming the resolved path when the destination does not exist' do
      expect(Tyrion::Orgkit).not_to receive(:run)
      expect { promote_quietly('h', '--to', 'parent-epic') }.to raise_error(SystemExit)
        .and output(/Destination not found: .*parent-epic\.context\.org/).to_stderr
    end

    it "refuses with the conversion message when a bare slug's wiki is still markdown" do
      File.write(File.join(root, 'features', 'parent-epic.context.md'), "# parent\n")
      expect(Tyrion::Orgkit).not_to receive(:run)

      expect { promote_quietly('h', '--to', 'parent-epic') }.to raise_error(SystemExit)
        .and output(/orgkit writes only org/).to_stderr
    end

    it 'prefers a bare slug\'s .org wiki over its .md sibling' do
      File.write(dest_path, "* Learnings\n")
      File.write(File.join(root, 'features', 'parent-epic.context.md'), "# parent\n")
      expect(Tyrion::Orgkit).to receive(:run)
        .with('refile', src_path, 'h', "#{dest_path}::Learnings", any_args)
        .and_return(['', '', ok])

      promote('h', '--to', 'parent-epic')
    end

    it 'exits 1 when the destination exists but is not .org' do
      other = File.join(root, 'notes.md')
      File.write(other, "# notes\n")
      expect(Tyrion::Orgkit).not_to receive(:run)

      expect { promote_quietly('h', '--to', 'notes.md') }.to raise_error(SystemExit)
        .and output(/orgkit writes only org/).to_stderr
    end
  end

  describe 'snapshot refresh' do
    before { File.write(dest_path, "* Learnings\n") }

    it 'refreshes the source epic snapshot from disk' do
      moved_src = "#+TITLE: my-epic\n\n* Learnings\n"
      allow(Tyrion::Orgkit).to receive(:run) do
        File.write(src_path, moved_src)
        ['', '', ok]
      end

      promote('a portable truth', '--to', 'parent-epic')
      expect(epic_row('my-epic')['context_md']).to eq moved_src
    end

    it "refreshes the destination epic's snapshot too when it is a tracked epic" do
      store.create_epic(project_id: ctx.project['id'], slug: 'parent-epic', name: 'Parent')
      moved_dest = "* Learnings\n** a portable truth :s1_2:\n"
      allow(Tyrion::Orgkit).to receive(:run) do
        File.write(dest_path, moved_dest)
        ['', '', ok]
      end

      promote('a portable truth', '--to', 'parent-epic')

      expect(epic_row('parent-epic')['context_md']).to eq moved_dest
      expect(epic_row('parent-epic')['context_source_hash']).to eq Digest::SHA256.hexdigest(moved_dest)
    end

    it 'still refreshes the source when the destination is not a tracked epic' do
      other = File.join(root, 'docs', 'system.org')
      FileUtils.mkdir_p(File.dirname(other))
      File.write(other, "* Learnings\n")
      moved_src = "#+TITLE: my-epic\n\n* Learnings\n"
      allow(Tyrion::Orgkit).to receive(:run) do
        File.write(src_path, moved_src)
        ['', '', ok]
      end

      expect { promote('a portable truth', '--to', 'docs/system.org') }.not_to raise_error
      expect(epic_row('my-epic')['context_md']).to eq moved_src
    end
  end

  describe 'failure paths never touch the DB' do
    before { File.write(dest_path, "* Learnings\n") }

    it "propagates an orgkit refusal's message, exits 1, and leaves both snapshots untouched" do
      store.create_epic(project_id: ctx.project['id'], slug: 'parent-epic', name: 'Parent')
      allow(Tyrion::Orgkit).to receive(:run)
        .and_return(['', "orgkit: ambiguous target 'a portable truth'\n", failed])

      expect { promote_quietly('a portable truth', '--to', 'parent-epic') }.to raise_error(SystemExit)
        .and output(/ambiguous target/).to_stderr

      expect(epic_row('my-epic')['context_md']).to be_nil
      expect(epic_row('parent-epic')['context_md']).to be_nil
    end

    it 'refuses when the SOURCE wiki is markdown' do
      FileUtils.rm_f(src_path)
      File.write(md_path, "# legacy\n")
      expect(Tyrion::Orgkit).not_to receive(:run)

      expect { promote_quietly('h', '--to', 'parent-epic') }.to raise_error(SystemExit)
        .and output(/orgkit writes only org/).to_stderr
    end

    it 'dies with an install hint when the orgkit binary is missing' do
      allow(Tyrion::Orgkit).to receive(:run).and_raise(Errno::ENOENT)

      expect { promote_quietly('h', '--to', 'parent-epic') }.to raise_error(SystemExit)
        .and output(/orgkit is not installed or not on PATH/).to_stderr
      expect(epic_row('my-epic')['context_md']).to be_nil
    end
  end
end

# The real binary. Skipped when orgkit is absent OR when its documented
# cross-file `FILE::target` grammar does not resolve — orgkit 0.1.0 documents
# it on both `refile` and `set-prop` but answers `no headline matching
# "<file>::<heading>"` (exit 3) for either, while a same-file refile works, so
# the defect is in the FILE:: parser and lives in the orgkit repo, not here.
# The argv this command builds is pinned by the stubbed specs above; this one
# starts running by itself the moment a fixed orgkit is installed.
RSpec.describe 'tyrion epic-context promote against the real orgkit binary' do
  # Probe the grammar rather than a version number: the question is whether
  # THIS installed build resolves a cross-file target, not what it calls itself.
  def orgkit_resolves_cross_file_targets?
    Dir.mktmpdir('orgkit-crossfile-probe-') do |dir|
      src  = File.join(dir, 'src.org')
      dest = File.join(dir, 'dest.org')
      File.write(src, "* Learnings\n** a headline\n")
      File.write(dest, "* Learnings\n")
      _out, _err, status = Tyrion::Orgkit.run('refile', src, 'a headline', "#{dest}::Learnings", '--dry-run')
      status.success?
    end
  rescue Errno::ENOENT
    false
  end

  let(:ctx)   { tyrion_worktree(project_slug: 'prproj', epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:root)  { ctx.tmpdir }
  let(:src_path)  { File.join(root, 'features', 'my-epic.context.org') }
  let(:dest_path) { File.join(root, 'features', 'parent-epic.context.org') }

  before do
    skip 'orgkit refile is not installed' unless orgkit_supports?('refile')
    skip 'orgkit does not resolve cross-file FILE::target destinations' unless orgkit_resolves_cross_file_targets?
    FileUtils.mkdir_p(File.join(root, 'features'))
    stub_repo(main_root: root)
    File.write(src_path, "#+TITLE: my-epic\n\n* Learnings\n** a portable truth :s1_2:\n")
    File.write(dest_path, "#+TITLE: parent\n\n* Learnings\n")
    store.create_epic(project_id: ctx.project['id'], slug: 'parent-epic', name: 'Parent')
  end

  it 'moves the headline into the destination, stamps provenance, and refreshes both snapshots' do
    capture_io do
      Tyrion::Commands.cmd_epic_context(
        ['promote', 'a portable truth', '--to', 'parent-epic'], store
      )
    end

    expect(File.read(dest_path)).to include 'a portable truth'
    expect(File.read(dest_path)).to include 'promoted_from'
    expect(File.read(src_path)).not_to include 'a portable truth'

    expect(store.find_epic(ctx.project['id'], 'my-epic')['context_md']).to eq File.read(src_path)
    expect(store.find_epic(ctx.project['id'], 'parent-epic')['context_md']).to eq File.read(dest_path)
  end
end
