# frozen_string_literal: true

require 'spec_helper'

# Specs for lane liveness surfacing (tyrion status STALE lane), tyrion unclaim,
# tyrion whoami, and the tyrion start --steal hijack guard. Repo.lane_liveness
# is stubbed so CI never needs a real `ps` ancestor.
RSpec.describe 'lane liveness + unclaim' do
  def reset_lane_token_memo
    Tyrion::Commands.instance_variable_set(:@_lane_token, :unset)
  end

  # Control the calling lane via TYRION_LANE (tier-1, returned verbatim).
  around do |ex|
    reset_lane_token_memo
    saved = %w[TYRION_LANE CODEX_THREAD_ID CMUX_CLAUDE_PID TYRION_AGENT].each_with_object({}) do |k, h|
      h[k] = ENV.delete(k)
    end
    ex.run
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    reset_lane_token_memo
  end

  let(:ctx)   { tyrion_worktree(epic_slug: 'parallel', epic_name: 'Parallel') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  def make_story(slug, claimed_by:, status: 'in_progress')
    s = store.create_story(epic_id: epic['id'], slug: slug, title: slug)
    store.start_story(s['id'], claimed_by: claimed_by) if status == 'in_progress'
    store.find_story(epic['id'], slug)
  end

  let(:dead_token) { 'claude:99999:deadbeefdeadbeef' }
  let(:my_token)   { 'lane-mine' }

  before { ENV['TYRION_LANE'] = my_token }

  describe 'cmd_unclaim' do
    it 'resets a dead lane\'s story to pending and NULLs claimed_by/claimed_at' do
      make_story('s1', claimed_by: dead_token)
      allow(Tyrion::Repo).to receive(:lane_liveness).with(dead_token).and_return(:dead)

      expect { Tyrion::Commands.cmd_unclaim(['s1'], store) }.to output(/Unclaimed:.*s1/).to_stdout

      s = store.find_story(epic['id'], 's1')
      expect(s['status']).to eq('pending')
      expect(s['claimed_by']).to be_nil
      expect(s['claimed_at']).to be_nil
    end

    it 'records a recovery note naming the prior owner' do
      make_story('s1', claimed_by: dead_token)
      allow(Tyrion::Repo).to receive(:lane_liveness).with(dead_token).and_return(:dead)

      capture_io { Tyrion::Commands.cmd_unclaim(['s1'], store) }

      body = store.notes_for_story(store.find_story(epic['id'], 's1')['id']).map { |n| n['body'] }.join("\n")
      expect(body).to include(dead_token)
    end

    it 'refuses to unclaim a LIVE other lane without --steal' do
      live = 'claude:222:0123456789abcdef'
      make_story('s1', claimed_by: live)
      allow(Tyrion::Repo).to receive(:lane_liveness).with(live).and_return(:live)

      expect { Tyrion::Commands.cmd_unclaim(['s1'], store) }
        .to raise_error(SystemExit).and output(/--steal/).to_stderr

      expect(store.find_story(epic['id'], 's1')['status']).to eq('in_progress')
    end

    it 'refuses to unclaim an UNKNOWN-liveness other lane without --steal' do
      other = 'codex:thread_xyz'
      make_story('s1', claimed_by: other)
      allow(Tyrion::Repo).to receive(:lane_liveness).with(other).and_return(:unknown)

      expect { Tyrion::Commands.cmd_unclaim(['s1'], store) }
        .to raise_error(SystemExit).and output(/--steal/).to_stderr
    end

    it '--steal forces release of a live other lane' do
      live = 'claude:222:0123456789abcdef'
      make_story('s1', claimed_by: live)
      allow(Tyrion::Repo).to receive(:lane_liveness).with(live).and_return(:live)

      capture_io { Tyrion::Commands.cmd_unclaim(['s1', '--steal'], store) }
      expect(store.find_story(epic['id'], 's1')['status']).to eq('pending')
    end

    it 'releases my own claim without --steal regardless of liveness' do
      make_story('s1', claimed_by: my_token)
      allow(Tyrion::Repo).to receive(:lane_liveness).with(my_token).and_return(:unknown)

      capture_io { Tyrion::Commands.cmd_unclaim(['s1'], store) }
      expect(store.find_story(epic['id'], 's1')['status']).to eq('pending')
    end

    it 'dies when the story does not exist' do
      expect { Tyrion::Commands.cmd_unclaim(['nope'], store) }
        .to raise_error(SystemExit).and output(/not found/).to_stderr
    end

    it 'dies with usage when no slug given' do
      expect { Tyrion::Commands.cmd_unclaim([], store) }
        .to raise_error(SystemExit).and output(/Usage/).to_stderr
    end
  end

  describe 'cmd_status STALE lane' do
    it 'renders a dead in_progress lane in a STALE section with an unclaim hint' do
      make_story('deadstory', claimed_by: dead_token)
      allow(Tyrion::Repo).to receive(:lane_liveness).and_return(:dead)

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to match(/STALE/)
      expect(out).to match(/tyrion unclaim deadstory/)
    end

    it 'does not render a STALE section for a live lane' do
      make_story('livestory', claimed_by: 'claude:222:0123456789abcdef')
      allow(Tyrion::Repo).to receive(:lane_liveness).and_return(:live)

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).not_to match(/STALE/)
    end

    it 'does not render a STALE section for an unknown-liveness lane' do
      make_story('unk', claimed_by: 'codex:thread_x')
      allow(Tyrion::Repo).to receive(:lane_liveness).and_return(:unknown)

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).not_to match(/STALE/)
    end
  end

  describe 'cmd_whoami' do
    it 'prints the resolved lane token and this lane\'s in_progress story' do
      make_story('mine', claimed_by: my_token)
      allow(Tyrion::Repo).to receive(:lane_liveness).with(my_token).and_return(:unknown)

      out, = capture_io { Tyrion::Commands.cmd_whoami([], store) }
      expect(out).to include(my_token)
      expect(out).to match(/mine/)
    end

    it 'reports no story when this lane holds none' do
      allow(Tyrion::Repo).to receive(:lane_liveness).and_return(:unknown)
      out, = capture_io { Tyrion::Commands.cmd_whoami([], store) }
      expect(out).to include(my_token)
      expect(out).to match(/none/i)
    end
  end

  describe 'cmd_start --steal hijack guard' do
    it 'refuses to start an in_progress story owned by another lane without --steal' do
      make_story('taken', claimed_by: dead_token)
      allow(Tyrion::Repo).to receive(:lane_liveness).with(dead_token).and_return(:dead)

      expect { Tyrion::Commands.cmd_start(['taken'], store) }
        .to raise_error(SystemExit).and output(/--steal|unclaim/).to_stderr
    end

    it 'starts a pending story owned by nobody without needing --steal' do
      s = store.create_story(epic_id: epic['id'], slug: 'fresh', title: 'fresh')
      expect { Tyrion::Commands.cmd_start(['fresh'], store) }.to output(/Started/).to_stdout
      expect(store.find_story(epic['id'], 'fresh')['status']).to eq('in_progress')
    end

    it 'adopts an assigned: pre-claim placeholder without needing --steal' do
      s = store.create_story(epic_id: epic['id'], slug: 'reserved', title: 'reserved')
      store.assign_story(s['id'], my_token) # pending, claimed_by="assigned:<label>"
      expect { Tyrion::Commands.cmd_start(['reserved'], store) }.to output(/Started/).to_stdout
    end

    it '--steal forces takeover of a dead lane\'s in_progress story' do
      make_story('taken', claimed_by: dead_token)
      allow(Tyrion::Repo).to receive(:lane_liveness).with(dead_token).and_return(:dead)

      expect { Tyrion::Commands.cmd_start(['taken', '--steal'], store) }.to output(/Started/).to_stdout
      s = store.find_story(epic['id'], 'taken')
      expect(s['status']).to eq('in_progress')
      expect(s['claimed_by']).to eq(my_token)
    end
  end
end
