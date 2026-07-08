# frozen_string_literal: true

require 'spec_helper'

# Criterion 3: `tyrion status` renders a lane list (one row per in_progress
# story / active lane), showing owner token + live/dead marker, and marks the
# lane owned by THIS process's token with "← you".
RSpec.describe 'tyrion status — LANES section' do
  let(:my_token) { 'claude:111:teststamp' }
  let(:ctx)      { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store)    { ctx.store }
  let(:epic)     { ctx.epic }

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(my_token)
    # Keep liveness deterministic — no real `ps` in specs.
    allow(Tyrion::Repo).to receive(:lane_liveness).and_return(:unknown)
  end

  def start_lane(slug, seq, claimed_by:)
    s = store.create_story(epic_id: epic['id'], slug: slug, title: slug, sequence: seq)
    store.start_story(s['id'], claimed_by: claimed_by)
  end

  context 'with two active lanes in the epic' do
    before do
      start_lane('mine', 1, claimed_by: my_token)
      start_lane('theirs', 2, claimed_by: 'claude:222:otherstamp')
    end

    it 'renders a LANES header with the active count' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to match(/LANES.*2 active/)
    end

    it 'lists every active lane by slug' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to include('mine')
      expect(out).to include('theirs')
    end

    it 'shows the owner token for each lane' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to include('claude:222:otherstamp')
    end

    it 'marks this process\'s lane with "← you" and not the other lane' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      you_line = out.lines.find { |l| l.include?('← you') }
      expect(you_line).not_to be_nil
      expect(you_line).to include('mine')
      expect(out.lines.count { |l| l.include?('← you') }).to eq(1)
    end

    it 'renders a live/dead/unknown marker from Repo.lane_liveness' do
      allow(Tyrion::Repo).to receive(:lane_liveness).with(my_token).and_return(:live)
      allow(Tyrion::Repo).to receive(:lane_liveness).with('claude:222:otherstamp').and_return(:dead)
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to match(/live/)
      expect(out).to match(/dead/)
    end
  end

  context 'with an unclaimed (legacy NULL claimed_by) in_progress story' do
    before { start_lane('legacy', 1, claimed_by: nil) }

    it 'still lists it as a lane without crashing and marks it unclaimed' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to match(/LANES.*1 active/)
      expect(out).to include('legacy')
      expect(out).to match(/unclaimed/)
    end
  end

  context 'with no in_progress stories' do
    before { store.create_story(epic_id: epic['id'], slug: 'pending-one', title: 'P', sequence: 1) }

    it 'does not render a LANES section' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).not_to include('LANES')
    end
  end
end
