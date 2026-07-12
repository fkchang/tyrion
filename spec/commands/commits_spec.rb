# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion commits' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:story) do
    store.create_story(epic_id: ctx.epic['id'], slug: 'test-story', title: 'Test Story')
    s = store.find_story(ctx.epic['id'], 'test-story')
    store.start_story(s['id'])
    store.find_story(ctx.epic['id'], 'test-story')
  end

  before { story }

  def commit_notes
    store.notes_for_story(story['id'], limit: 100).select { |n| n['kind'] == 'commit' }
  end

  describe 'cmd_commits' do
    it 'records a commit note and prints the count in the success line' do
      stub_repo(commits_since: ['abc1234 feat: thing', 'def5678 fix: bug'])
      expect { Tyrion::Commands.cmd_commits(['test-story'], store) }
        .to output(/Commits recorded: 2 — test-story/).to_stdout
    end

    it 'writes one <sha> <subject> line per commit under a header' do
      stub_repo(commits_since: ['abc1234 feat: thing', 'def5678 fix: bug'])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      body = commit_notes.last['body']
      expect(body).to match(/\Acommits since .+:/)
      expect(body).to include('abc1234 feat: thing')
      expect(body).to include('def5678 fix: bug')
    end

    it 'stores metadata JSON with shas and count' do
      stub_repo(commits_since: ['abc1234 feat: thing', 'def5678 fix: bug'])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      meta = JSON.parse(commit_notes.last['metadata'])
      expect(meta).to eq('shas' => %w[abc1234 def5678], 'count' => 2)
    end

    it 'records the no-changes body and none in the success line when empty' do
      stub_repo(commits_since: [])
      expect { Tyrion::Commands.cmd_commits(['test-story'], store) }
        .to output(/Commits recorded: none — test-story/).to_stdout
      expect(commit_notes.last['body']).to eq('no commits — no changes required')
      expect(JSON.parse(commit_notes.last['metadata'])).to eq('shas' => [], 'count' => 0)
    end

    it 'appends a new note on each run (append-only history)' do
      stub_repo(commits_since: ['abc1234 feat: thing'])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      Tyrion::Commands.cmd_commits(['test-story'], store)
      expect(commit_notes.length).to eq(2)
    end

    it 'dies when the story is not found' do
      stub_repo(commits_since: [])
      expect { Tyrion::Commands.cmd_commits(['no-such'], store) }
        .to raise_error(SystemExit).and output(/Story not found: no-such/).to_stderr
    end

    it 'dies when git is unavailable (Repo.commits_since returns nil)' do
      stub_repo(commits_since: nil)
      expect { Tyrion::Commands.cmd_commits(['test-story'], store) }
        .to raise_error(SystemExit).and output(/git/i).to_stderr
    end
  end

  describe '.commit_capture_since (timestamp resolution)' do
    it 'prefers started_at, then claimed_at, then created_at' do
      expect(Tyrion::Commands.commit_capture_since(
        'started_at' => 's', 'claimed_at' => 'c', 'created_at' => 'r'
      )).to eq('s')
      expect(Tyrion::Commands.commit_capture_since(
        'started_at' => nil, 'claimed_at' => 'c', 'created_at' => 'r'
      )).to eq('c')
      expect(Tyrion::Commands.commit_capture_since(
        'started_at' => nil, 'claimed_at' => nil, 'created_at' => 'r'
      )).to eq('r')
    end

    it 'returns nil when no timestamp is present' do
      expect(Tyrion::Commands.commit_capture_since({})).to be_nil
    end
  end

  describe 'cmd_commits with no resolvable timestamp' do
    it 'dies with a clear message' do
      allow(Tyrion::Commands).to receive(:commit_capture_since).and_return(nil)
      stub_repo(commits_since: [])
      expect { Tyrion::Commands.cmd_commits(['test-story'], store) }
        .to raise_error(SystemExit).and output(/timestamp/i).to_stderr
    end
  end

  describe 'auto-capture in cmd_done' do
    it 'writes a commit note when the story is completed' do
      stub_repo(commits_since: ['abc1234 feat: thing'])
      Tyrion::Commands.cmd_done(['test-story', 'all done'], store)
      expect(commit_notes.length).to eq(1)
      expect(commit_notes.last['body']).to include('abc1234 feat: thing')
    end

    it 'still completes the story when git is unavailable (nil), skipping capture' do
      stub_repo(commits_since: nil)
      expect { Tyrion::Commands.cmd_done(['test-story', 'all done'], store) }
        .to output(/Done: test-story/).to_stdout
      expect(commit_notes).to be_empty
      expect(store.find_story(ctx.epic['id'], 'test-story')['status']).to eq('done')
    end
  end

  describe 'lane-aware exclusion of sibling commits' do
    let(:sibling) do
      store.create_story(epic_id: ctx.epic['id'], slug: 'sibling-story', title: 'Sibling')
      store.find_story(ctx.epic['id'], 'sibling-story')
    end

    before do
      sibling
      # Sibling already recorded its own commits.
      stub_repo(commits_since: ['abc1234 sibling: work', 'def5678 sibling: more'])
      Tyrion::Commands.cmd_commits(['sibling-story'], store)
    end

    it 'excludes hashes already present in another story\'s commit note' do
      # test-story's git window sees the sibling's commits plus its own new one.
      stub_repo(commits_since: ['abc1234 sibling: work', 'def5678 sibling: more', 'ghi9012 mine: new'])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      meta = JSON.parse(commit_notes.last['metadata'])
      expect(meta['shas']).to eq(%w[ghi9012])
    end

    it 'still captures commits not recorded in any other story\'s commit note' do
      stub_repo(commits_since: ['ghi9012 mine: new', 'jkl3456 mine: also'])
      expect { Tyrion::Commands.cmd_commits(['test-story'], store) }
        .to output(/Commits recorded: 2 — test-story/).to_stdout
      expect(JSON.parse(commit_notes.last['metadata'])['shas']).to eq(%w[ghi9012 jkl3456])
    end

    it 'records the no-changes body when every commit belongs to a sibling' do
      stub_repo(commits_since: ['abc1234 sibling: work', 'def5678 sibling: more'])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      expect(commit_notes.last['body']).to eq('no commits — no changes required')
      expect(JSON.parse(commit_notes.last['metadata'])).to eq('shas' => [], 'count' => 0)
    end

    it 'does not exclude a story\'s own previously-recorded commits from itself' do
      stub_repo(commits_since: ['ghi9012 mine: new'])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      # Re-running still captures ghi9012 — self-notes are not part of "other stories".
      stub_repo(commits_since: ['ghi9012 mine: new'])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      expect(JSON.parse(commit_notes.last['metadata'])['shas']).to eq(%w[ghi9012])
    end
  end

  describe 'shared-branch caveat (concurrent in_progress siblings)' do
    def started_sibling(slug)
      store.create_story(epic_id: ctx.epic['id'], slug: slug, title: slug)
      s = store.find_story(ctx.epic['id'], slug)
      # Distinct lane token so the partial-unique in_progress-per-lane index
      # permits a second live story in the same epic (the parallel-lane case).
      store.start_story(s['id'], claimed_by: "lane-#{slug}")
      s
    end

    it 'appends a caveat naming the concurrent story count when a sibling is in_progress' do
      started_sibling('sibling-a')
      stub_repo(commits_since: ['ghi9012 mine: new'])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      body = commit_notes.last['body']
      expect(body).to include('ghi9012 mine: new')
      expect(body).to match(/⚠ shared-branch capture: 1 concurrent in_progress story — some commits may belong to another lane/)
    end

    it 'pluralizes the count with two or more in_progress siblings' do
      started_sibling('sibling-a')
      started_sibling('sibling-b')
      stub_repo(commits_since: ['ghi9012 mine: new'])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      expect(commit_notes.last['body']).to match(/2 concurrent in_progress stories/)
    end

    it 'produces a caveat-free note (byte-identical to legacy) with no concurrent siblings' do
      stub_repo(commits_since: ['ghi9012 mine: new'])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      expect(commit_notes.last['body']).to eq("commits since #{story['started_at']}:\nghi9012 mine: new")
    end

    it 'does not caveat when the note has no commits even if siblings are in_progress' do
      started_sibling('sibling-a')
      stub_repo(commits_since: [])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      expect(commit_notes.last['body']).to eq('no commits — no changes required')
    end

    it 'excludes the closing story itself from the concurrent count' do
      # test-story is in_progress; with no other in_progress story the count is 0.
      expect(store.concurrent_in_progress_count(story['id'])).to eq(0)
    end
  end

  describe 'Store#commit_shas_in_other_stories' do
    it 'reads short SHAs from another story\'s commit note metadata' do
      store.add_note(sibling_id, 'commit', 'commits since t:', metadata: JSON.dump('shas' => %w[aaa1111 bbb2222], 'count' => 2))
      expect(store.commit_shas_in_other_stories(story['id'])).to contain_exactly('aaa1111', 'bbb2222')
    end

    it 'falls back to SHA tokens in the body when metadata is absent' do
      store.add_note(sibling_id, 'commit', "commits since t:\nccc3333 legacy note\nnot-a-sha line", metadata: nil)
      expect(store.commit_shas_in_other_stories(story['id'])).to contain_exactly('ccc3333')
    end

    it 'ignores the querying story\'s own commit notes' do
      store.add_note(story['id'], 'commit', 'x', metadata: JSON.dump('shas' => %w[ddd4444], 'count' => 1))
      expect(store.commit_shas_in_other_stories(story['id'])).to be_empty
    end

    def sibling_id
      @sibling_id ||= begin
        store.create_story(epic_id: ctx.epic['id'], slug: 'other-story', title: 'Other')
        store.find_story(ctx.epic['id'], 'other-story')['id']
      end
    end
  end

  describe 'GATES rendering of a multi-line commit note' do
    it 'indents continuation lines under the header' do
      stub_repo(commits_since: ['abc1234 feat: thing', 'def5678 fix: bug'])
      Tyrion::Commands.cmd_commits(['test-story'], store)
      out, = capture_io { Tyrion::Commands.cmd_show(['test-story'], store) }
      expect(out).to match(/Gates:/)
      expect(out).to match(/^ {4}abc1234 feat: thing/)
      expect(out).to match(/^ {4}def5678 fix: bug/)
    end
  end
end
