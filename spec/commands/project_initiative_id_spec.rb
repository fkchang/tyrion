# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'project initiative_id' do
  let(:ctx)     { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
  end

  # ── Store column (criteria 2, 3) ─────────────────────────────────────────
  describe 'projects.initiative_id column' do
    it 'is nil by default' do
      expect(store.find_project_by_slug(project['slug'])['initiative_id']).to be_nil
    end

    it 'can be set via update_project' do
      store.update_project(project['id'], 'initiative_id' => 'init-083')
      expect(store.find_project_by_slug(project['slug'])['initiative_id']).to eq 'init-083'
    end
  end

  # ── CLI set-initiative (criterion 4) ─────────────────────────────────────
  describe 'tyrion project set-initiative <id>' do
    it 'sets initiative_id on the active project' do
      Tyrion::Commands.cmd_project(['set-initiative', 'init-083'], store)
      expect(store.find_project_by_slug(project['slug'])['initiative_id']).to eq 'init-083'
    end

    it 'errors when no id is given' do
      expect { Tyrion::Commands.cmd_project(['set-initiative'], store) }
        .to raise_error(SystemExit).and output(/Usage/).to_stderr
    end

    it 'errors when there is no active project' do
      ctx # materialise worktree stubs first
      stub_repo(active_project: nil)
      expect { Tyrion::Commands.cmd_project(['set-initiative', 'init-083'], store) }
        .to raise_error(SystemExit).and output(/No active project/).to_stderr
    end
  end

  # ── CLI show (criterion 4) ────────────────────────────────────────────────
  describe 'tyrion project show' do
    it 'prints the Initiative line when initiative_id is present' do
      store.update_project(project['id'], 'initiative_id' => 'init-083')
      out, = capture_io { Tyrion::Commands.cmd_project(['show', project['slug']], store) }
      expect(out).to include('Initiative: init-083')
    end

    it 'omits the Initiative line when initiative_id is absent' do
      out, = capture_io { Tyrion::Commands.cmd_project(['show', project['slug']], store) }
      expect(out).not_to include('Initiative:')
    end
  end

  # ── Migration idempotency (criterion 3) ──────────────────────────────────
  describe 'initiative_id migration' do
    it 'is safe to run twice' do
      db_path = File.join(ctx.tmpdir, 'test.db')
      expect { Tyrion::Store.new(db_path: db_path) }.not_to raise_error
      second = Tyrion::Store.new(db_path: db_path)
      expect(second.find_project_by_slug(project['slug'])).to have_key('initiative_id')
    end
  end
end
