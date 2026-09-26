# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe Tyrion::SessionResolver do
  before do
    @claude_root = Dir.mktmpdir('session-resolver-spec-')
    stub_const('Tyrion::SessionResolver::CLAUDE_PROJECTS_ROOT', @claude_root)
  end

  after { FileUtils.remove_entry(@claude_root) }

  def project_dir(worktree_path)
    File.join(@claude_root, worktree_path.gsub(%r{[/.]}, '-'))
  end

  def write_session(worktree_path, session_id, mtime:, content: '')
    dir = project_dir(worktree_path)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{session_id}.jsonl")
    File.write(path, content)
    File.utime(mtime, mtime, path)
    path
  end

  describe '.project_dir_for' do
    it 'replaces every / and . with -, matching real ~/.claude/projects/ naming' do
      expect(described_class.project_dir_for('/Users/fkchang/work/cultiv-ai/.claude/worktrees/x'))
        .to eq File.join(@claude_root, '-Users-fkchang-work-cultiv-ai--claude-worktrees-x')
    end
  end

  describe '.resume_command' do
    it 'prefixes a cd when a worktree path is known' do
      expect(described_class.resume_command('abc-123', '/repo')).to eq 'cd /repo && claude -r abc-123'
    end

    it 'omits the cd when there is no worktree path' do
      expect(described_class.resume_command('abc-123', nil)).to eq 'claude -r abc-123'
    end
  end

  describe '.resume_hint -- live lane (exact)' do
    it 'returns a confirmed hint parsed from lsof output naming an open transcript' do
      lsof_output = <<~LSOF
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF   NODE NAME
        claude  34720 fk    10u   REG    1,4    12345 654321 #{described_class::CLAUDE_PROJECTS_ROOT}/-Users-fk-repo/abc-session-id.jsonl
      LSOF
      allow(Tyrion::Repo).to receive(:capture_with_timeout).with(['lsof', '-p', '34720']).and_return(lsof_output)

      hint = described_class.resume_hint(pid: 34_720, live: true, worktree_path: '/Users/fk/repo',
                                          story_slug: 'irrelevant', last_activity_epoch: Time.now.to_i)
      expect(hint).to eq('session_id' => 'abc-session-id', 'confidence' => 'confirmed',
                          'command' => 'cd /Users/fk/repo && claude -r abc-session-id')
    end

    it 'falls through to the dead-lane heuristic when lsof finds no open transcript' do
      allow(Tyrion::Repo).to receive(:capture_with_timeout).and_return("COMMAND PID\nclaude 34720\n")
      now = Time.now.to_i
      write_session('/repo', 'only-match', mtime: Time.at(now), content: 'about story-x here')

      hint = described_class.resume_hint(pid: 34_720, live: true, worktree_path: '/repo',
                                          story_slug: 'story-x', last_activity_epoch: now)
      expect(hint).to eq('session_id' => 'only-match', 'confidence' => 'candidate',
                          'command' => 'cd /repo && claude -r only-match')
    end

    it 'treats a timed-out lsof the same as "not found" rather than raising' do
      allow(Tyrion::Repo).to receive(:capture_with_timeout).and_raise(Tyrion::Repo::GitTimeout)
      hint = described_class.resume_hint(pid: 1, live: true, worktree_path: nil, story_slug: 'x',
                                          last_activity_epoch: Time.now.to_i)
      expect(hint).to be_nil
    end
  end

  describe '.resume_hint -- dead lane (candidate, both signals must agree)' do
    let(:now) { Time.now.to_i }

    it 'returns nil when no transcript is even in the activity window' do
      write_session('/repo', 'too-old', mtime: Time.at(now - 100_000), content: 'story-x')
      hint = described_class.resume_hint(pid: nil, live: false, worktree_path: '/repo',
                                          story_slug: 'story-x', last_activity_epoch: now)
      expect(hint).to be_nil
    end

    it 'returns nil when a transcript is in the time window but never mentions the slug' do
      write_session('/repo', 'wrong-content', mtime: Time.at(now), content: 'unrelated chatter')
      hint = described_class.resume_hint(pid: nil, live: false, worktree_path: '/repo',
                                          story_slug: 'story-x', last_activity_epoch: now)
      expect(hint).to be_nil
    end

    it 'returns a candidate when exactly one transcript matches both time and slug' do
      write_session('/repo', 'match', mtime: Time.at(now), content: 'notes about story-x here')
      write_session('/repo', 'time-only', mtime: Time.at(now), content: 'no slug mention')
      hint = described_class.resume_hint(pid: nil, live: false, worktree_path: '/repo',
                                          story_slug: 'story-x', last_activity_epoch: now)
      expect(hint).to eq('session_id' => 'match', 'confidence' => 'candidate',
                          'command' => 'cd /repo && claude -r match')
    end

    it 'returns nil (never guesses) when two transcripts both match time and slug -- ambiguous' do
      write_session('/repo', 'a', mtime: Time.at(now), content: 'story-x')
      write_session('/repo', 'b', mtime: Time.at(now), content: 'story-x')
      hint = described_class.resume_hint(pid: nil, live: false, worktree_path: '/repo',
                                          story_slug: 'story-x', last_activity_epoch: now)
      expect(hint).to be_nil
    end

    it 'excludes the exact false positive found live: a same-repo session that merely typed the slug much later, via the time window' do
      write_session('/repo', 'real-session', mtime: Time.at(now), content: 'story-x work happened here')
      write_session('/repo', 'much-later-session', mtime: Time.at(now + 2_000_000), content: 'ran: tyrion resume story-x')
      hint = described_class.resume_hint(pid: nil, live: false, worktree_path: '/repo',
                                          story_slug: 'story-x', last_activity_epoch: now)
      expect(hint['session_id']).to eq 'real-session'
    end

    it 'returns nil with no worktree_path, no last_activity_epoch, or a directory Tyrion has never seen' do
      expect(described_class.resume_hint(pid: nil, live: false, worktree_path: nil, story_slug: 'x',
                                          last_activity_epoch: now)).to be_nil
      expect(described_class.resume_hint(pid: nil, live: false, worktree_path: '/repo', story_slug: 'x',
                                          last_activity_epoch: nil)).to be_nil
      expect(described_class.resume_hint(pid: nil, live: false, worktree_path: '/never/seen', story_slug: 'x',
                                          last_activity_epoch: now)).to be_nil
    end
  end

  describe '.enrich_lanes' do
    def report_with(lanes:, last_activity_at: nil)
      { 'epics' => [{ 'epic_slug' => 'e', 'last_activity_at' => last_activity_at, 'lanes' => lanes }] }
    end

    it 'adds a resume_hint key to every lane without mutating the input report' do
      report = report_with(lanes: [{ 'token' => 'claude:1:x', 'pid' => 1, 'live' => false,
                                      'story_slug' => 's', 'worktree_path' => nil }])
      original_lane = report['epics'].first['lanes'].first

      out = described_class.enrich_lanes(report)

      expect(out['epics'].first['lanes'].first).to have_key('resume_hint')
      expect(original_lane).not_to have_key('resume_hint')
    end

    it 'never raises out of enrichment even when a lane is missing fields' do
      report = report_with(lanes: [{ 'token' => 'x' }])
      expect { described_class.enrich_lanes(report) }.not_to raise_error
    end
  end
end
