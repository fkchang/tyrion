# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'tmpdir'

RSpec.describe 'tyrion epic-context append' do
  let(:ctx)   { tyrion_worktree(project_slug: 'approj', epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:root)  { ctx.tmpdir }

  let(:org_body) { "#+TITLE: my-epic wiki\n\n* Verified facts\n- a fact\n\n* Learnings\n" }
  let(:org_path) { File.join(root, 'features', 'my-epic.context.org') }
  let(:md_path)  { File.join(root, 'features', 'my-epic.context.md') }

  let(:ok)   { instance_double(Process::Status, success?: true) }
  let(:failed) { instance_double(Process::Status, success?: false) }

  before do
    FileUtils.mkdir_p(File.join(root, 'features'))
    stub_repo(main_root: root)
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return('lane-a')
  end

  def append(*args)
    capture_io { Tyrion::Commands.cmd_epic_context(['append', *args], store) }
  end

  def append_quietly(*args)
    orig = $stdout
    $stdout = StringIO.new
    Tyrion::Commands.cmd_epic_context(['append', *args], store)
  ensure
    $stdout = orig
  end

  # An in_progress story claimed by THIS lane — what prime_story_for finds.
  def claim_story(slug: 's1-2', token: 'lane-a')
    story = store.create_story(epic_id: ctx.epic['id'], slug: slug, title: slug)
    store.start_story(story['id'], claimed_by: token)
    store.find_story(ctx.epic['id'], slug)
  end

  def epic_row
    store.find_epic(ctx.project['id'], 'my-epic')
  end

  describe 'the orgkit capture invocation' do
    before { File.write(org_path, org_body) }

    it 'shells to orgkit capture with the file, the text, --under Learnings and the mapped story tag' do
      expect(Tyrion::Orgkit).to receive(:run)
        .with('capture', org_path, 'a learned thing', '--under', 'Learnings', '--tags', 's1_2')
        .and_return(['', '', ok])

      append('--story', 's1-2', 'a learned thing')
    end

    it 'appends --tags extras after the story tag' do
      expect(Tyrion::Orgkit).to receive(:run)
        .with('capture', org_path, 'text', '--under', 'Learnings', '--tags', 's1_2,a,b')
        .and_return(['', '', ok])

      append('--story', 's1-2', '--tags', 'a,b', 'text')
    end

    it 'omits --tags entirely when there is no story and no extras' do
      expect(Tyrion::Orgkit).to receive(:run)
        .with('capture', org_path, 'text', '--under', 'Learnings')
        .and_return(['', '', ok])

      append('text')
    end

    it 'prints orgkit stdout verbatim and then names the file it wrote' do
      allow(Tyrion::Orgkit).to receive(:run).and_return(["captured\n", '', ok])

      out, = append('--story', 's1-2', 'text')
      expect(out).to include 'captured'
      expect(out).to include org_path
    end

    it 'dies with usage when no text is given' do
      expect { append_quietly('--story', 's1-2') }.to raise_error(SystemExit)
        .and output(/Usage: tyrion epic-context append/).to_stderr
    end
  end

  describe 'the default --story lookup' do
    before { File.write(org_path, org_body) }

    it "defaults to this lane's own in_progress story" do
      claim_story(slug: 's1-2')
      expect(Tyrion::Orgkit).to receive(:run)
        .with('capture', org_path, 'text', '--under', 'Learnings', '--tags', 's1_2')
        .and_return(['', '', ok])

      append('text')
    end

    it 'never calls resolve_my_story, which can claim and adopt' do
      claim_story(slug: 's1-2')
      allow(Tyrion::Orgkit).to receive(:run).and_return(['', '', ok])
      expect(Tyrion::Commands).not_to receive(:resolve_my_story)

      append('text')
    end

    it "ignores another lane's in_progress story" do
      claim_story(slug: 's9-9', token: 'lane-b')
      expect(Tyrion::Orgkit).to receive(:run)
        .with('capture', org_path, 'text', '--under', 'Learnings')
        .and_return(['', '', ok])

      append('text')
    end

    it 'writes with only the extra tags when no story resolves' do
      expect(Tyrion::Orgkit).to receive(:run)
        .with('capture', org_path, 'text', '--under', 'Learnings', '--tags', 'a,b')
        .and_return(['', '', ok])

      append('--tags', 'a,b', 'text')
    end

    it 'an explicit --story wins over the lane lookup' do
      claim_story(slug: 's1-2')
      expect(Tyrion::Orgkit).to receive(:run)
        .with('capture', org_path, 'text', '--under', 'Learnings', '--tags', 'other_story')
        .and_return(['', '', ok])

      append('--story', 'other-story', 'text')
    end
  end

  describe 'the ledger snapshot refresh' do
    before { File.write(org_path, org_body) }

    it 'refreshes context_md and context_source_hash from the file on disk after a successful capture' do
      new_body = "#{org_body}** a learning :s1_2:\n"
      allow(Tyrion::Orgkit).to receive(:run) do
        File.write(org_path, new_body)
        ['', '', ok]
      end

      append('--story', 's1-2', 'a learning')

      expect(epic_row['context_md']).to eq new_body
      expect(epic_row['context_source_hash']).to eq Digest::SHA256.hexdigest(new_body)
    end

    it 'keeps tyrion import idempotent — the refreshed snapshot is not seen as a change' do
      feature = File.join(root, 'features', 'my-epic.feature')
      File.write(feature, "Feature: My Epic\n\n  Scenario: s1-2\n    Given a thing\n    Then an outcome\n")
      capture_io { Tyrion::Importer.run([feature], store) }

      new_body = "#{org_body}** a learning :s1_2:\n"
      allow(Tyrion::Orgkit).to receive(:run) do
        File.write(org_path, new_body)
        ['', '', ok]
      end
      append('--story', 's1-2', 'a learning')

      out, = capture_io { Tyrion::Importer.run([feature], store) }
      expect(out).to match(/already up to date/)
    end

    it 'makes tyrion epic show print the appended content' do
      new_body = "#{org_body}** a learning :s1_2:\n"
      allow(Tyrion::Orgkit).to receive(:run) do
        File.write(org_path, new_body)
        ['', '', ok]
      end
      append('--story', 's1-2', 'a learning')

      out, = capture_io { Tyrion::Commands.cmd_epic(['show', 'my-epic'], store) }
      expect(out).to include 'a learning :s1_2:'
    end
  end

  describe 'failure paths never touch the DB' do
    it 'refuses a .context.md wiki and names orgkit import as the conversion' do
      File.write(md_path, "# legacy\n")
      expect(Tyrion::Orgkit).not_to receive(:run)

      expect { append_quietly('text') }.to raise_error(SystemExit)
        .and output(/orgkit import/).to_stderr
      expect(epic_row['context_md']).to be_nil
    end

    it 'dies when the epic has no context file at all' do
      expect { append_quietly('text') }.to raise_error(SystemExit)
        .and output(/No context file for epic 'my-epic'/).to_stderr
    end

    it "propagates orgkit's stderr verbatim, exits 1, and leaves the snapshot untouched" do
      File.write(org_path, org_body)
      allow(Tyrion::Orgkit).to receive(:run).and_return(['', "orgkit: ambiguous target\n", failed])

      expect { append_quietly('--story', 's1-2', 'text') }.to raise_error(SystemExit)
        .and output(/orgkit: ambiguous target/).to_stderr
      expect(epic_row['context_md']).to be_nil
      expect(epic_row['context_source_hash']).to be_nil
    end

    it 'dies with an install hint when the orgkit binary is missing' do
      File.write(org_path, org_body)
      allow(Tyrion::Orgkit).to receive(:run).and_raise(Errno::ENOENT)

      expect { append_quietly('text') }.to raise_error(SystemExit)
        .and output(/orgkit is not installed or not on PATH/).to_stderr
      expect(epic_row['context_md']).to be_nil
    end
  end
end

RSpec.describe 'Tyrion::Store#refresh_epic_context' do
  let(:ctx)   { tyrion_worktree(project_slug: 'refproj', epic_slug: 'my-epic') }
  let(:store) { ctx.store }

  it 'writes the content and its own SHA256 so the two can never disagree' do
    row = store.refresh_epic_context(ctx.epic['id'], "* Learnings\n")

    expect(row['context_md']).to eq "* Learnings\n"
    expect(row['context_source_hash']).to eq Digest::SHA256.hexdigest("* Learnings\n")
  end

  it 'overwrites a prior snapshot rather than appending to it' do
    store.refresh_epic_context(ctx.epic['id'], 'first')
    row = store.refresh_epic_context(ctx.epic['id'], 'second')

    expect(row['context_md']).to eq 'second'
  end
end

# Real worktree, real orgkit binary. The whole point of the story: a builder
# standing in a linked worktree (which branches from origin/main and does not
# contain the wiki) must append to the MAIN checkout's file.
RSpec.describe 'tyrion epic-context append from inside a linked git worktree' do
  let(:tmpdir)    { Dir.mktmpdir('tyrion-append-wt-') }
  let(:main_root) { File.realpath(File.join(tmpdir, 'main')) }
  let(:wt)        { File.join(tmpdir, 'wt') }
  let(:org_path)  { File.join(main_root, 'features', 'my-epic.context.org') }

  after { FileUtils.rm_rf(tmpdir) }

  def git(dir, *args)
    system('git', '-C', dir, *args, out: File::NULL, err: File::NULL)
  end

  let(:store)   { Tyrion::Store.new(db_path: File.join(tmpdir, 'test.db')) }
  let(:project) { store.create_project(slug: 'wtproj', name: 'WT Project') }
  let(:epic)    { store.create_epic(project_id: project['id'], slug: 'my-epic', name: 'My Epic') }

  before do
    skip 'orgkit capture is not installed' unless orgkit_supports?('capture')

    FileUtils.mkdir_p(File.join(tmpdir, 'main', 'features'))
    git(main_root, 'init', '-q')
    git(main_root, 'config', 'user.email', 'test@example.com')
    git(main_root, 'config', 'user.name', 'Test')
    File.write(org_path, "#+TITLE: my-epic\n\n* Learnings\n")
    git(main_root, 'add', '-A')
    git(main_root, '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'seed')
    git(main_root, 'worktree', 'add', '-q', wt, '-b', 'lane-1')
    # The worktree branches from the same commit, so remove the wiki there to
    # model the real case: an agent worktree that does not carry the file.
    FileUtils.rm_rf(File.join(wt, 'features'))

    epic
    allow(Tyrion::Repo).to receive(:worktree_root).and_return(File.realpath(wt))
    allow(Tyrion::Repo).to receive(:active_project).and_return('wtproj')
    allow(Tyrion::Repo).to receive(:active_epic).and_return('my-epic')
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return('lane-a')
  end

  it "appends to the main checkout's file and leaves the worktree without a copy" do
    capture_io do
      Dir.chdir(wt) { Tyrion::Commands.cmd_epic_context(['append', 'a worktree learning'], store) }
    end

    expect(File.read(org_path)).to include 'a worktree learning'
    expect(File.exist?(File.join(wt, 'features', 'my-epic.context.org'))).to be false
  end

  it 'refreshes the ledger snapshot from the main checkout file' do
    capture_io do
      Dir.chdir(wt) { Tyrion::Commands.cmd_epic_context(['append', 'a worktree learning'], store) }
    end

    row = store.find_epic(project['id'], 'my-epic')
    expect(row['context_md']).to eq File.read(org_path)
    expect(row['context_source_hash']).to eq Digest::SHA256.file(org_path).hexdigest
  end
end
