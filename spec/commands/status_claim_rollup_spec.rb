# frozen_string_literal: true

require 'spec_helper'

# Story: status-claim-rollup — the `tyrion status` counts line must be honest
# about work in flight and pre-claimed. The retro blind spot: "6 pending" while
# work is secretly mid-flight reads as idle, and a pre-claimed story looks
# unowned.
RSpec.describe 'tyrion status — counts line rollup' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  before do
    # Keep the LANES section deterministic — no real `ps` in specs.
    allow(Tyrion::Repo).to receive(:lane_liveness).and_return(:unknown)
  end

  def pending(slug, seq, claimed_by: nil)
    s = store.create_story(epic_id: epic['id'], slug: slug, title: slug, sequence: seq)
    store.assign_story(s['id'], claimed_by.sub(/\Aassigned:/, '')) if claimed_by
    s
  end

  context 'with no in_progress stories' do
    before { pending('p1', 1) }

    it 'shows the in_progress count even when it is zero' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to match(/0 in_progress/)
    end
  end

  context 'with a pending story pre-claimed via assigned:<label>' do
    before do
      pending('p1', 1)
      pending('p2', 2, claimed_by: 'assigned:lane-9')
    end

    it 'shows a pre-claimed count when any pending story has claimed_by assigned:' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to match(/1 pre-claimed/)
    end
  end

  context 'with no pre-claimed stories' do
    before { pending('p1', 1) }

    it 'omits the pre-claimed segment' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).not_to match(/pre-claimed/)
    end
  end
end
