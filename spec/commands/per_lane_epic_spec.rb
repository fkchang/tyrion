# frozen_string_literal: true

require 'spec_helper'

# Specs for per-lane active epic: set_active_epic_for_lane,
# resolve_project_epic with token, and legacy nil-token fallback.

RSpec.describe 'per-lane active epic' do
  # For set_active_epic_for_lane tests we need real file I/O on Repo,
  # so we use a raw tmpdir rather than tyrion_worktree (which stubs Repo).
  let(:tmpdir) { Dir.mktmpdir('per-lane-epic-spec-') }
  after { FileUtils.rm_rf(tmpdir) }

  describe 'Commands.set_active_epic_for_lane' do
    let(:token) { 'claude:111:stampA' }

    it 'writes the per-lane active-epic file' do
      Tyrion::Commands.set_active_epic_for_lane('epic-a', token: token, root: tmpdir)
      expect(Tyrion::Repo.active_epic(tmpdir, token: token)).to eq('epic-a')
    end

    it 'is silent on stderr when epic is unchanged (re-activation)' do
      Tyrion::Commands.set_active_epic_for_lane('epic-a', token: token, root: tmpdir)
      expect do
        Tyrion::Commands.set_active_epic_for_lane('epic-a', token: token, root: tmpdir)
      end.not_to output.to_stderr
    end

    it 'prints EPIC SWITCHED warning to stderr when epic changes' do
      Tyrion::Commands.set_active_epic_for_lane('epic-a', token: token, root: tmpdir)
      expect do
        Tyrion::Commands.set_active_epic_for_lane('epic-b', token: token, root: tmpdir)
      end.to output(/⚠.*EPIC SWITCHED.*epic-a.*epic-b/).to_stderr
    end

    it 'is silent on first activation (no prior per-lane epic to switch from)' do
      expect do
        Tyrion::Commands.set_active_epic_for_lane('epic-a', token: token, root: tmpdir)
      end.not_to output.to_stderr
    end

    it 'two tokens can activate different epics without interference' do
      token_b = 'claude:222:stampB'
      Tyrion::Commands.set_active_epic_for_lane('epic-a', token: token,   root: tmpdir)
      Tyrion::Commands.set_active_epic_for_lane('epic-b', token: token_b, root: tmpdir)

      expect(Tyrion::Repo.active_epic(tmpdir, token: token)).to eq('epic-a')
      expect(Tyrion::Repo.active_epic(tmpdir, token: token_b)).to eq('epic-b')
    end
  end

  describe 'cmd_epic_activate — per-lane wiring' do
    let(:ctx)   { tyrion_worktree(epic_slug: 'epic-a', git_branch: 'main') }
    let(:store) { ctx.store }
    let(:token) { 'claude:444:stampY' }

    before { allow(Tyrion::Commands).to receive(:current_lane_token).and_return(token) }

    it 'calls set_active_epic_for_lane with the current token when token is present' do
      expect(Tyrion::Commands).to receive(:set_active_epic_for_lane)
        .with('epic-a', hash_including(token: token))
      Tyrion::Commands.cmd_epic_activate(['epic-a'], store)
    end

    it 'falls back to shared write when token is nil' do
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
      expect(Tyrion::Repo).to receive(:write_active_epic).with('epic-a')
      Tyrion::Commands.cmd_epic_activate(['epic-a'], store)
    end
  end

  describe 'resolve_project_epic token wiring' do
    let(:ctx)   { tyrion_worktree(epic_slug: 'epic-a', git_branch: 'main') }
    let(:store) { ctx.store }

    context 'when current_lane_token returns a token' do
      let(:token) { 'claude:123:stampX' }

      before { allow(Tyrion::Commands).to receive(:current_lane_token).and_return(token) }

      it 'passes the lane token to Repo.active_epic' do
        # Expect that the token is forwarded — fails before the wiring is added
        expect(Tyrion::Repo).to receive(:active_epic).with(token: token).and_return('epic-a')
        Tyrion::Commands.send(:resolve_project_epic, store)
      end
    end

    context 'when current_lane_token is nil (legacy single-session)' do
      before do
        allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
        stub_repo(active_epic: 'epic-a')
      end

      it 'calls Repo.active_epic with token: nil (legacy path unchanged)' do
        # nil token → active_epic(token: nil) → reads shared file
        expect(Tyrion::Repo).to receive(:active_epic).with(token: nil).and_return('epic-a')
        Tyrion::Commands.send(:resolve_project_epic, store)
      end
    end
  end
end
