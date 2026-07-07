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
