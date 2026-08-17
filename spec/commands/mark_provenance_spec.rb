# frozen_string_literal: true

require 'spec_helper'

# Specs for discoveries.source_story_id — the "where was this noticed" column
# that promotion never overwrites, plus the running per-story mark count on the
# `tyrion mark` confirmation line.
RSpec.describe 'mark provenance' do
  let(:token) { 'claude:1:stamp' }
  let(:ctx)   { tyrion_worktree(epic_slug: 'discovery-autonomy') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  before { allow(Tyrion::Commands).to receive(:current_lane_token).and_return(token) }

  def mark(args = ['noticed a thing'])
    out, = capture_io { Tyrion::Commands.cmd_mark(args, store) }
    [store.find_discovery(out[/\[mark\] (disc-\d+)/, 1]), out]
  end

  def in_progress_story(slug: 'story-a', claimed_by: nil)
    story = store.create_story(epic_id: epic['id'], slug: slug, title: slug)
    store.start_story(story['id'], claimed_by: claimed_by)
    store.find_story(epic['id'], slug)
  end

  # ── criteria 1-4: the column ────────────────────────────────────────────

  describe 'the source_story_id column' do
    it 'exists on discoveries' do
      cols = store.send(:with_db) { |db| db.execute('PRAGMA table_info(discoveries)') }.map { |c| c['name'] }
      expect(cols).to include('source_story_id')
    end

    it 'adds nothing on a second setup_db — the migration is idempotent' do
      expect { store.send(:setup_db) }.not_to raise_error
      cols = store.send(:with_db) { |db| db.execute('PRAGMA table_info(discoveries)') }
             .map { |c| c['name'] }.tally
      expect(cols['source_story_id']).to eq 1
    end

    it 'is left NULL on rows filed before the column existed' do
      store.send(:with_db) do |db|
        db.execute(
          "INSERT INTO discoveries (id, project_id, status, question, created_at, updated_at) " \
          "VALUES ('disc-900', ?, 'mark', 'legacy row', '2020-01-01T00:00:00Z', '2020-01-01T00:00:00Z')",
          [ctx.project['id']]
        )
      end

      expect(store.find_discovery('disc-900')['source_story_id']).to be_nil
    end

    it 'survives promotion, which only rewrites story_id' do
      story = in_progress_story(claimed_by: token)
      disc, = mark
      store.send(:with_db) { |db| db.execute("UPDATE discoveries SET status='findings_ready' WHERE id=?", [disc['id']]) }

      promoted = store.promote_discovery_to_story(disc['id'], epic_id: epic['id'],
                                                  slug: 'from-mark', title: 'From Mark', intent: nil)
      after = store.find_discovery(disc['id'])

      expect(after['source_story_id']).to eq story['id']
      expect(after['story_id']).to eq promoted['id']
      expect(after['story_id']).not_to eq after['source_story_id']
    end

    it 'survives a defer, which changes status only' do
      story = in_progress_story(claimed_by: token)
      disc, = mark
      store.defer_discovery(disc['id'], reason: 'not now')

      expect(store.find_discovery(disc['id'])['source_story_id']).to eq story['id']
    end
  end

  # ── criteria 5-8: resolution via prime_story_for ────────────────────────

  describe 'tyrion mark' do
    it 'stamps the lane\'s own in_progress story and the active epic' do
      story = in_progress_story(claimed_by: token)
      disc, = mark

      expect(disc['source_story_id']).to eq story['id']
      expect(disc['epic_id']).to eq epic['id']
    end

    it 'stamps the legacy sole-unclaimed in_progress story when the lane has no token' do
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
      story = in_progress_story(claimed_by: nil)

      expect(mark.first['source_story_id']).to eq story['id']
    end

    it 'leaves source_story_id nil for another lane\'s in_progress story' do
      in_progress_story(claimed_by: 'claude:99:other')
      disc, = mark

      expect(disc['source_story_id']).to be_nil
      expect(disc['epic_id']).to eq epic['id']
    end

    it 'leaves source_story_id nil for a story that is pinned but not in_progress' do
      story = store.create_story(epic_id: epic['id'], slug: 'pinned', title: 'Pinned')
      store.update_story(story['id'], 'claimed_by' => "assigned:#{token}")
      allow(Tyrion::Repo).to receive(:active_story).and_return('pinned')

      expect(mark.first['source_story_id']).to be_nil
    end

    it 'never claims a story as a side effect of filing' do
      story = store.create_story(epic_id: epic['id'], slug: 'untouched', title: 'Untouched')
      mark

      after = store.find_story(epic['id'], 'untouched')
      expect(after['status']).to eq story['status']
      expect(after['claimed_by']).to be_nil
    end

    it 'succeeds with nil provenance when no epic is active' do
      ctx # materialise the worktree stubs before overriding one of them
      stub_repo(active_epic: nil)
      disc, out = mark

      expect(out).to match(/\[mark\] disc-\d+/)
      expect(disc['source_story_id']).to be_nil
      expect(disc['epic_id']).to be_nil
    end

    it 'succeeds with nil provenance when the epic has no story on this lane' do
      disc, out = mark

      expect(out).to match(/\[mark\] disc-\d+/)
      expect(disc['source_story_id']).to be_nil
    end
  end

  # ── criterion 10: the running count on the confirmation line ────────────

  describe 'the confirmation line' do
    before { in_progress_story(claimed_by: token) }

    it 'counts up as marks accumulate on the same story' do
      expect(mark.last).to match(/\[mark\] disc-\d+ \(1st mark filed this story\)/)
      expect(mark.last).to match(/\(2nd mark filed this story\)/)
      expect(mark.last).to match(/\(3rd mark filed this story\)/)
      expect(mark.last).to match(/\(4th mark filed this story\)/)
    end

    it 'omits the count when no story resolved' do
      stub_repo(active_epic: nil)
      expect(mark.last).to match(/\[mark\] disc-\d+\n/)
      expect(mark.last).not_to include('filed this story')
    end

    it 'counts only marks from the same story' do
      store.create_discovery(project_id: ctx.project['id'], status: 'mark', question: 'elsewhere')
      expect(mark.last).to match(/\(1st mark filed this story\)/)
    end
  end

  describe 'Commands.ordinal' do
    it 'uses th for the teens rather than st/nd/rd' do
      expect([11, 12, 13].map { |n| Tyrion::Commands.ordinal(n) }).to eq %w[11th 12th 13th]
    end

    it 'uses st/nd/rd for 21/22/23' do
      expect([21, 22, 23].map { |n| Tyrion::Commands.ordinal(n) }).to eq %w[21st 22nd 23rd]
    end
  end
end
