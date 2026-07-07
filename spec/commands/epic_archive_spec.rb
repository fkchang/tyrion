# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'epic archive/unarchive commands' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
  end

  # ── Store methods (criterion 6) ──────────────────────────────────────────
  describe 'Store#archive_epic / #unarchive_epic' do
    it 'archive_epic sets archived_at to a timestamp (criterion 1)' do
      store.archive_epic(epic['id'])
      expect(store.find_epic_by_id(epic['id'])['archived_at']).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it 'unarchive_epic clears archived_at (criterion 4)' do
      store.archive_epic(epic['id'])
      store.unarchive_epic(epic['id'])
      expect(store.find_epic_by_id(epic['id'])['archived_at']).to be_nil
    end
  end

  # ── CLI archive (criteria 1, 2) ──────────────────────────────────────────
  describe 'tyrion epic archive <slug>' do
    it 'sets archived_at to the current time' do
      Tyrion::Commands.cmd_epic(['archive', 'my-epic'], store)
      expect(store.find_epic_by_id(epic['id'])['archived_at']).not_to be_nil
    end

    it 'errors on an unknown slug' do
      expect { Tyrion::Commands.cmd_epic(['archive', 'nope'], store) }
        .to raise_error(SystemExit).and output(/not found/).to_stderr
    end

    it 'drops the epic from the main epic list and shows it with an [archived] marker' do
      store.archive_epic(epic['id'])
      out, = capture_io { Tyrion::Commands.cmd_epic(['list'], store) }
      main, archived = out.split(/Archived/i, 2)
      expect(main).not_to include('my-epic')
      expect(archived).to include('my-epic')
      expect(archived).to include('[archived]')
    end
  end

  # ── CLI unarchive (criteria 4, 5) ────────────────────────────────────────
  describe 'tyrion epic unarchive <slug>' do
    it 'clears archived_at' do
      store.archive_epic(epic['id'])
      Tyrion::Commands.cmd_epic(['unarchive', 'my-epic'], store)
      expect(store.find_epic_by_id(epic['id'])['archived_at']).to be_nil
    end

    it 'returns the epic to the main list' do
      store.archive_epic(epic['id'])
      Tyrion::Commands.cmd_epic(['unarchive', 'my-epic'], store)
      out, = capture_io { Tyrion::Commands.cmd_epic(['list'], store) }
      main, = out.split(/Archived/i, 2)
      expect(main).to include('my-epic')
    end
  end

  # ── Migration idempotency (criterion 7) ──────────────────────────────────
  describe 'archived_at migration' do
    it 'is safe to run twice' do
      db_path = File.join(ctx.tmpdir, 'test.db')
      # ctx already built one Store (ran MIGRATIONS once). A second Store on the
      # same DB re-runs setup_db → MIGRATIONS and must not raise on the
      # already-present archived_at column.
      expect { Tyrion::Store.new(db_path: db_path) }.not_to raise_error
      second = Tyrion::Store.new(db_path: db_path)
      expect(second.find_epic_by_id(epic['id'])).to have_key('archived_at')
    end
  end
end
