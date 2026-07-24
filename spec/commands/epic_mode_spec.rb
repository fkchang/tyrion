# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'epic mode (dark_factory / shape)' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
  end

  # ── Migration (criterion 1) ─────────────────────────────────────────────
  describe 'mode column migration' do
    it 'is NULL by default on a freshly created epic' do
      expect(store.find_epic_by_id(epic['id'])['mode']).to be_nil
    end

    it 'is safe to run twice' do
      db_path = File.join(ctx.tmpdir, 'test.db')
      expect { Tyrion::Store.new(db_path: db_path) }.not_to raise_error
      second = Tyrion::Store.new(db_path: db_path)
      expect(second.find_epic_by_id(epic['id'])).to have_key('mode')
    end
  end

  # ── CLI: tyrion epic mode <slug> <value> (criterion 2) ───────────────────
  describe 'tyrion epic mode <slug> dark_factory' do
    it 'sets the literal value dark_factory' do
      Tyrion::Commands.cmd_epic(['mode', 'my-epic', 'dark_factory'], store)
      expect(store.find_epic_by_id(epic['id'])['mode']).to eq 'dark_factory'
    end

    it 'prints a confirmation' do
      expect { Tyrion::Commands.cmd_epic(['mode', 'my-epic', 'dark_factory'], store) }
        .to output(/Epic mode set:.*my-epic.*dark_factory/).to_stdout
    end
  end

  describe 'tyrion epic mode <slug> shape' do
    it 'normalizes back to NULL' do
      store.update_epic(epic['id'], 'mode' => 'dark_factory')
      Tyrion::Commands.cmd_epic(['mode', 'my-epic', 'shape'], store)
      expect(store.find_epic_by_id(epic['id'])['mode']).to be_nil
    end
  end

  describe 'an invalid mode value' do
    it 'dies with exit 1 and a stderr message, without mutating the DB' do
      expect { Tyrion::Commands.cmd_epic(['mode', 'my-epic', 'bogus'], store) }
        .to raise_error(SystemExit).and output(/Invalid mode: bogus/).to_stderr
      expect(store.find_epic_by_id(epic['id'])['mode']).to be_nil
    end

    it 'does not overwrite an existing mode when the new value is invalid' do
      store.update_epic(epic['id'], 'mode' => 'dark_factory')
      expect { Tyrion::Commands.cmd_epic(['mode', 'my-epic', 'bogus'], store) }
        .to raise_error(SystemExit)
      expect(store.find_epic_by_id(epic['id'])['mode']).to eq 'dark_factory'
    end
  end

  describe 'unknown slug' do
    it 'dies with a not found message' do
      expect { Tyrion::Commands.cmd_epic(['mode', 'nope', 'dark_factory'], store) }
        .to raise_error(SystemExit).and output(/not found/).to_stderr
    end
  end

  describe 'missing arguments' do
    it 'dies with a usage message' do
      expect { Tyrion::Commands.cmd_epic(['mode', 'my-epic'], store) }
        .to raise_error(SystemExit).and output(/Usage: tyrion epic mode/).to_stderr
    end
  end

  # ── Surfacing: tyrion status (criterion 3) ───────────────────────────────
  describe 'tyrion status' do
    it 'shows a dark_factory badge when the epic mode is dark_factory' do
      store.update_epic(epic['id'], 'mode' => 'dark_factory')
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to match(/Epic:.*my-epic.*🏭 dark_factory/)
    end

    it 'shows nothing extra when the epic mode is shape/NULL' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).not_to include('dark_factory')
      expect(out).not_to include('🏭')
    end
  end

  # ── Surfacing: tyrion epic list (criterion 3) ────────────────────────────
  describe 'tyrion epic list' do
    it 'shows a dark_factory badge for a dark_factory epic' do
      store.update_epic(epic['id'], 'mode' => 'dark_factory')
      out, = capture_io { Tyrion::Commands.cmd_epic(['list'], store) }
      expect(out).to match(/my-epic.*🏭 dark_factory/)
    end

    it 'shows nothing extra for a shape/NULL epic' do
      out, = capture_io { Tyrion::Commands.cmd_epic(['list'], store) }
      expect(out).not_to include('dark_factory')
      expect(out).not_to include('🏭')
    end
  end

  # ── Preservation (criterion 4) ────────────────────────────────────────────
  describe 'mode survives sealing, reopening, and re-import' do
    it 'is untouched by seal_epic' do
      store.update_epic(epic['id'], 'mode' => 'dark_factory')
      story = store.create_story(epic_id: epic['id'], slug: 'only-story', title: 'Only story', sequence: 1)
      store.update_story(story['id'], 'status' => 'done')

      store.seal_epic(epic['id'])
      reloaded = store.find_epic_by_id(epic['id'])
      expect(reloaded['status']).to eq 'done'
      expect(reloaded['mode']).to eq 'dark_factory'
    end

    it 'is untouched by reopen_epic_if_done! (auto-reopen honesty flip)' do
      store.update_epic(epic['id'], 'mode' => 'dark_factory')
      story = store.create_story(epic_id: epic['id'], slug: 'only-story', title: 'Only story', sequence: 1)
      store.update_story(story['id'], 'status' => 'done')
      store.seal_epic(epic['id'])
      expect(store.find_epic_by_id(epic['id'])['status']).to eq 'done'

      # start_story on a new pending story triggers reopen_epic_if_done! internally.
      story2 = store.create_story(epic_id: epic['id'], slug: 'second-story', title: 'Second story', sequence: 2)
      store.start_story(story2['id'], claimed_by: 'claude:test')

      reloaded = store.find_epic_by_id(epic['id'])
      expect(reloaded['status']).to eq 'active'
      expect(reloaded['mode']).to eq 'dark_factory'
    end

    it 'is untouched by tyrion epic complete (CLI seal)' do
      store.update_epic(epic['id'], 'mode' => 'dark_factory')
      story = store.create_story(epic_id: epic['id'], slug: 'only-story', title: 'Only story', sequence: 1)
      store.update_story(story['id'], 'status' => 'done')

      capture_io { Tyrion::Commands.cmd_epic(['complete', 'my-epic'], store) }
      reloaded = store.find_epic_by_id(epic['id'])
      expect(reloaded['status']).to eq 'done'
      expect(reloaded['mode']).to eq 'dark_factory'
    end

    it 'is untouched by re-importing the epic via upsert_epic' do
      store.update_epic(epic['id'], 'mode' => 'dark_factory')

      store.upsert_epic(
        project_id: ctx.project['id'], slug: 'my-epic', name: epic['name'],
        intent: 'updated intent'
      )

      reloaded = store.find_epic_by_id(epic['id'])
      expect(reloaded['intent']).to eq 'updated intent'
      expect(reloaded['mode']).to eq 'dark_factory'
    end
  end
end
