# frozen_string_literal: true

require 'spec_helper'

# Specs for resolve_my_story: the 6-rung story resolver ladder.
# Also covers rewiring of cmd_start (stamp token), cmd_done (clear pin),
# cmd_claim_next (ladder with claim_if_none:true), cmd_resume (no-slug ladder),
# and cmd_pocket (uses ladder).
#
# Stubs Commands.current_lane_token to 'claude:111:teststamp' throughout.
# Stubs Repo.active_story via stub_repo so no real file I/O is needed.

RSpec.describe 'resolve_my_story — 6-rung story resolver' do
  let(:token) { 'claude:111:teststamp' }
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic', git_branch: 'main') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(token)
    stub_repo(active_story: nil)
  end

  # Helper: create a pending story in the epic with a unique sequence
  def create_pending(slug)
    @_seq = (@_seq || 0) + 1
    store.create_story(epic_id: epic['id'], slug: slug, title: slug, sequence: @_seq)
  end

  # Helper: create an in_progress story claimed by a specific token (or nil)
  def create_in_progress(slug, claimed_by: nil)
    s = create_pending(slug)
    store.start_story(s['id'], claimed_by: claimed_by)
    store.find_story(epic['id'], slug)
  end

  # ── Rung 1: explicit slug always wins ─────────────────────────────────────

  describe 'rung 1 — explicit slug supplied (criteria 1-3)' do
    it 'returns the named story regardless of any in_progress state' do
      create_pending('target-story')
      create_in_progress('other-story', claimed_by: token)

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: 'target-story', claim_if_none: false)

      expect(result['slug']).to eq('target-story')
    end

    it 'dies when the explicit slug does not exist' do
      expect do
        Tyrion::Commands.resolve_my_story(store, epic,
          explicit_slug: 'no-such-story', claim_if_none: false)
      end.to raise_error(SystemExit).and output(/not found|no-such-story/i).to_stderr
    end
  end

  # ── Rung 2: in_progress story with claimed_by == token ────────────────────

  describe 'rung 2 — lane-token match (criteria 4-5)' do
    it 'returns the story whose claimed_by matches the current lane token' do
      create_in_progress('mine', claimed_by: token)

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: false)

      expect(result['slug']).to eq('mine')
    end

    it 'ignores stories claimed by a different token' do
      create_in_progress('theirs', claimed_by: 'claude:999:other')

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: false)

      expect(result).to be_nil
    end

    it 'returns the same story after simulating /clear (memo reset, same token)' do
      create_in_progress('mine', claimed_by: token)

      first  = Tyrion::Commands.resolve_my_story(store, epic, explicit_slug: nil, claim_if_none: false)
      # Simulate /clear: reset the memo — the OS process survives, same token re-derived
      Tyrion::Commands.instance_variable_set(:@_lane_token, :unset)
      second = Tyrion::Commands.resolve_my_story(store, epic, explicit_slug: nil, claim_if_none: false)

      expect(first['slug']).to eq('mine')
      expect(second['slug']).to eq('mine')
    end
  end

  # ── Rung 3: pre-claim adopt (assigned:<TYRION_LANE>) ──────────────────────

  describe 'rung 3 — pre-claim adopt (criteria 6-7)' do
    around do |ex|
      saved = ENV.delete('TYRION_LANE')
      ENV['TYRION_LANE'] = 'my-lane'
      ex.run
      saved.nil? ? ENV.delete('TYRION_LANE') : ENV['TYRION_LANE'] = saved
    end

    it 'adopts a story whose claimed_by is "assigned:<TYRION_LANE>" and re-stamps the real token' do
      pending_s = create_pending('pre-assigned')
      store.update_story(pending_s['id'], 'claimed_by' => 'assigned:my-lane')

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: false)

      expect(result['slug']).to eq('pre-assigned')
      reloaded = store.find_story(epic['id'], 'pre-assigned')
      expect(reloaded['claimed_by']).to eq(token)
    end

    it 'does not adopt stories assigned to a different lane' do
      pending_s = create_pending('other-assigned')
      store.update_story(pending_s['id'], 'claimed_by' => 'assigned:different-lane')

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: false)

      expect(result).to be_nil
    end
  end

  # ── Rung 4: .tyrion/active-story pin ─────────────────────────────────────

  describe 'rung 4 — active-story file pin (criteria 8-9)' do
    it 'returns the story pinned in .tyrion/active-story (via Repo.active_story)' do
      create_pending('pinned-story')
      stub_repo(active_story: 'pinned-story')

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: false)

      expect(result['slug']).to eq('pinned-story')
    end

    it 'does not resolve when the pinned slug does not exist in the epic' do
      stub_repo(active_story: 'nonexistent-story')

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: false)

      expect(result).to be_nil
    end
  end

  # ── Rung 5: sole NULL-claimed in_progress story (legacy) ─────────────────

  describe 'rung 5 — sole unclaimed in_progress story (criteria 10-11)' do
    it 'returns the single in_progress story with NULL claimed_by' do
      create_in_progress('legacy', claimed_by: nil)

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: false)

      expect(result['slug']).to eq('legacy')
    end

    it 'does not resolve when the in_progress story is claimed by another token' do
      create_in_progress('theirs', claimed_by: 'claude:999:other')

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: false)

      expect(result).to be_nil
    end
  end

  # ── Rung 6: claim-next (claim_if_none: true) ─────────────────────────────

  describe 'rung 6 — claim-next when claim_if_none:true (criteria 12-14)' do
    it 'claims the next pending story and stamps claimed_by when no prior match' do
      create_pending('next-pending')

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: true)

      expect(result['slug']).to eq('next-pending')
      expect(result['status']).to eq('in_progress')
      expect(result['claimed_by']).to eq(token)
    end

    it 'does NOT claim a new story when rung 2 already matches (post-/clear safety)' do
      create_in_progress('mine', claimed_by: token)
      create_pending('would-be-claimed')

      # Simulate /clear scenario
      Tyrion::Commands.instance_variable_set(:@_lane_token, :unset)

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: true)

      expect(result['slug']).to eq('mine')
      # 'would-be-claimed' must remain pending — rung 2 short-circuited
      leftover = store.find_story(epic['id'], 'would-be-claimed')
      expect(leftover['status']).to eq('pending')
    end

    it 'returns nil when claim_if_none is false and no story matches' do
      create_pending('unclaimed')

      result = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: false)

      expect(result).to be_nil
    end
  end

  # ── cmd_start: stamps claimed_by ─────────────────────────────────────────

  describe 'cmd_start stamps claimed_by with the current lane token' do
    before do
      stub_repo(active_epic: 'my-epic')
      create_pending('to-start')
    end

    it 'sets claimed_by on the story to current_lane_token' do
      Tyrion::Commands.cmd_start(['to-start'], store)
      story = store.find_story(epic['id'], 'to-start')
      expect(story['claimed_by']).to eq(token)
    end
  end

  # ── cmd_done: clears the per-lane active-story pin ────────────────────────

  describe 'cmd_done clears the per-lane active-story pin' do
    before do
      stub_repo(active_epic: 'my-epic')
      @story = create_in_progress('in-flight', claimed_by: token)
      store.criteria_for_story(@story['id'])  # ensure no pending criteria
    end

    it 'calls Repo.clear_active_story with the current token' do
      expect(Tyrion::Repo).to receive(:clear_active_story).with(hash_including(token: token))
      Tyrion::Commands.cmd_done(['in-flight', 'done summary'], store)
    end
  end

  # ── cmd_claim_next: uses the ladder with claim_if_none:true ──────────────

  describe 'cmd_claim_next uses the resolver ladder' do
    before { stub_repo(active_epic: 'my-epic') }

    it 'returns the existing in_progress story (rung 2) rather than claiming another' do
      mine = create_in_progress('mine', claimed_by: token)
      create_pending('next-pending')

      out, = capture_io { Tyrion::Commands.cmd_claim_next([], store) }
      expect(out).to include('mine')

      next_story = store.find_story(epic['id'], 'next-pending')
      expect(next_story['status']).to eq('pending')
    end

    it 'claims the next pending story when no lane match exists' do
      create_pending('next-up')

      out, = capture_io { Tyrion::Commands.cmd_claim_next([], store) }
      expect(out).to include('next-up')

      story = store.find_story(epic['id'], 'next-up')
      expect(story['claimed_by']).to eq(token)
    end
  end

  # ── cmd_resume (no-slug): uses the ladder ────────────────────────────────

  describe 'cmd_resume with no slug uses the resolver ladder' do
    before { stub_repo(active_epic: 'my-epic') }

    it 'resumes the story claimed by this lane token' do
      mine = create_in_progress('mine', claimed_by: token)
      store.update_story(mine['id'], 'current_context' => 'ctx', 'next_action' => 'act')

      out, = capture_io { Tyrion::Commands.cmd_resume([], store) }
      expect(out).to include('mine')
    end
  end
end
