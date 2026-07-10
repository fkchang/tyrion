# frozen_string_literal: true

require 'spec_helper'

# Closing a story must preserve the closing lane's provenance in a completed_by
# column, while still clearing the transient claim lock (claimed_by/claimed_at).
# Without this, done stories are forensically indistinguishable from never-claimed
# ones — the failure documented in docs/retro-2026-07-09-llm-delegation.md.
RSpec.describe 'provenance preserved at close' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
    allow(Tyrion::Repo).to receive(:clear_active_story)
  end

  # A story claimed by a specific lane, then closed — the exact lifecycle the
  # criteria describe. No criteria attached, so close is unconditional.
  def claimed_then_done(slug, lane:)
    store.create_story(epic_id: epic['id'], slug: slug, title: slug)
    row = store.find_story(epic['id'], slug)
    store.start_story(row['id'], claimed_by: lane)
    store.complete_story(row['id'], 'done via lane')
    store.find_story(epic['id'], slug)
  end

  describe 'criterion 1 — completed_by records the closing lane token' do
    it 'copies the claiming lane into completed_by at close' do
      story = claimed_then_done('shipped', lane: 'lane-42')
      expect(story['completed_by']).to eq('lane-42')
    end

    it 'adds the column idempotently (a second Store on the same DB does not error)' do
      db_path = File.join(ctx.tmpdir, 'test.db')
      expect { Tyrion::Store.new(db_path: db_path) }.not_to raise_error
      # The column still holds prior provenance after re-running migrations.
      claimed_then_done('again', lane: 'lane-7')
      reopened = Tyrion::Store.new(db_path: db_path)
      expect(reopened.find_story(epic['id'], 'again')['completed_by']).to eq('lane-7')
    end
  end

  describe 'criterion 2 — tyrion show renders the completing lane for a done story' do
    it 'prints the completing lane token' do
      claimed_then_done('rendered', lane: 'lane-99')
      out, = capture_io { Tyrion::Commands.cmd_show(['rendered'], store) }
      expect(out).to match(/Completed by: lane-99/)
    end

    it 'does not print a completing lane for an unclaimed done story' do
      store.create_story(epic_id: epic['id'], slug: 'orphan', title: 'orphan')
      id = store.find_story(epic['id'], 'orphan')['id']
      store.complete_story(id, 'closed without ever being claimed')
      out, = capture_io { Tyrion::Commands.cmd_show(['orphan'], store) }
      expect(out).not_to match(/Completed by:/)
    end
  end

  describe 'criterion 3 — claim lock still clears at close' do
    it 'nulls claimed_by and claimed_at, preserving transient-lock semantics' do
      story = claimed_then_done('unlocked', lane: 'lane-5')
      expect(story['claimed_by']).to be_nil
      expect(story['claimed_at']).to be_nil
    end
  end
end
