# frozen_string_literal: true

require 'spec_helper'

# `tyrion worktrees` — a cross-lane dashboard: one row per git worktree AND per
# active lane, with path, branch, active epic, in-progress story (or none),
# owner token, age, and ● live / ✗ dead. The lane owned by this process is
# marked "← current"; a working tree with 2+ active lanes shows a warning.
RSpec.describe 'tyrion worktrees' do
  let(:my_token) { 'lane-mine' }
  let(:ctx)      { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store)    { ctx.store }
  let(:epic)     { ctx.epic }

  # Two fake worktrees; wt_a is the current checkout.
  let(:wt_a) { '/tmp/wt-a' }
  let(:wt_b) { '/tmp/wt-b' }

  before do
    store # realize ctx (and its Repo stubs) before we override them below
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(my_token)
    allow(Tyrion::Repo).to receive(:lane_liveness).and_return(:unknown)
    allow(Tyrion::Repo).to receive(:worktrees).and_return([
                                                            { path: wt_a, branch: 'story/a', head: 'aaa' },
                                                            { path: wt_b, branch: 'main', head: 'bbb' }
                                                          ])
    # active-epic on the shared file of a no-lane worktree
    allow(Tyrion::Repo).to receive(:active_epic).and_return(nil)
    # lane-hash mapping is filesystem-derived; stub per worktree path.
    allow(Tyrion::Repo).to receive(:lane_hashes).and_return([])
  end

  def start_lane(slug, seq, claimed_by:)
    s = store.create_story(epic_id: epic['id'], slug: slug, title: slug, sequence: seq)
    store.start_story(s['id'], claimed_by: claimed_by)
    s
  end

  # Route a token's lane-hash dir into a given worktree path.
  def place_lane(token, in_worktree:)
    hash = Tyrion::Repo.lane_hash(token)
    existing = Tyrion::Repo.lane_hashes(in_worktree)
    allow(Tyrion::Repo).to receive(:lane_hashes).with(in_worktree).and_return((existing + [hash]).uniq)
  end

  context 'one lane per worktree' do
    before do
      start_lane('mine', 1, claimed_by: my_token)
      start_lane('theirs', 2, claimed_by: 'lane-theirs')
      place_lane(my_token, in_worktree: wt_a)
      place_lane('lane-theirs', in_worktree: wt_b)
    end

    it 'shows every worktree path and branch' do
      out, = capture_io { Tyrion::Commands.cmd_worktrees([], store) }
      expect(out).to include(wt_a)
      expect(out).to include(wt_b)
      expect(out).to include('story/a')
      expect(out).to include('main')
    end

    it 'shows each lane\'s epic, story, and owner token' do
      out, = capture_io { Tyrion::Commands.cmd_worktrees([], store) }
      expect(out).to include('my-epic / mine')
      expect(out).to include('my-epic / theirs')
      expect(out).to include('lane-theirs')
    end

    it 'marks this process\'s lane with "← current" (and only that lane)' do
      out, = capture_io { Tyrion::Commands.cmd_worktrees([], store) }
      cur = out.lines.find { |l| l.include?('← current') }
      expect(cur).not_to be_nil
      expect(cur).to include('mine')
      expect(out.lines.count { |l| l.include?('← current') }).to eq(1)
    end

    it 'renders a live/dead marker from Repo.lane_liveness' do
      allow(Tyrion::Repo).to receive(:lane_liveness).with(my_token).and_return(:live)
      allow(Tyrion::Repo).to receive(:lane_liveness).with('lane-theirs').and_return(:dead)
      out, = capture_io { Tyrion::Commands.cmd_worktrees([], store) }
      expect(out).to match(/live/)
      expect(out).to match(/dead/)
    end
  end

  context 'a working tree shared by 2+ lanes' do
    before do
      start_lane('mine', 1, claimed_by: my_token)
      start_lane('other', 2, claimed_by: 'lane-other')
      place_lane(my_token, in_worktree: wt_a)
      place_lane('lane-other', in_worktree: wt_a)
    end

    it 'shows an "N lanes share this working tree" warning' do
      out, = capture_io { Tyrion::Commands.cmd_worktrees([], store) }
      expect(out).to match(/2 lanes share this working tree/)
    end

    it 'still lists both lanes' do
      out, = capture_io { Tyrion::Commands.cmd_worktrees([], store) }
      expect(out).to include('mine')
      expect(out).to include('other')
    end
  end

  context 'a worktree with no active lane' do
    before do
      allow(Tyrion::Repo).to receive(:active_epic).with(wt_b).and_return('some-epic')
    end

    it 'shows the worktree with a "no active lane" note and its active epic' do
      out, = capture_io { Tyrion::Commands.cmd_worktrees([], store) }
      expect(out).to include(wt_b)
      expect(out).to match(/no active lane/)
      expect(out).to include('some-epic')
    end
  end

  context 'a lane with no matching git worktree (orphan)' do
    before do
      start_lane('orphan', 1, claimed_by: 'lane-orphan')
      # not placed in any worktree
    end

    it 'still lists the lane under an orphan section' do
      out, = capture_io { Tyrion::Commands.cmd_worktrees([], store) }
      expect(out).to match(/orphan/i)
      expect(out).to include('lane-orphan')
    end
  end
end

RSpec.describe 'Tyrion::Repo.worktrees parsing' do
  it 'parses git worktree list --porcelain into path/branch/head hashes' do
    porcelain = <<~OUT
      worktree /Users/x/repo
      HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      branch refs/heads/main

      worktree /Users/x/repo-feature
      HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      branch refs/heads/story/feature

      worktree /Users/x/repo-detached
      HEAD cccccccccccccccccccccccccccccccccccccccc
      detached
    OUT
    allow(Tyrion::Repo).to receive(:git_worktree_list).and_return(porcelain)

    wts = Tyrion::Repo.worktrees
    expect(wts.size).to eq(3)
    expect(wts[0]).to include(path: '/Users/x/repo', branch: 'main')
    expect(wts[1]).to include(path: '/Users/x/repo-feature', branch: 'story/feature')
    expect(wts[2][:branch]).to eq('(detached)')
  end
end
