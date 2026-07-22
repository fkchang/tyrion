# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'tyrion hook claim-gate' do
  let(:ctx)     { tyrion_worktree(project_slug: 'gateproj', epic_slug: 'gate-epic') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { ctx.epic }

  def make_story(slug: 'my-story', title: 'My Story', status: 'pending', claimed_by: nil)
    story = store.create_story(epic_id: epic['id'], slug: slug, title: title)
    attrs = {}
    attrs['status'] = status if status != 'pending'
    attrs['claimed_by'] = claimed_by if claimed_by
    store.update_story(story['id'], attrs) unless attrs.empty?
    store.find_story(epic['id'], slug)
  end

  def stdin_for(command)
    StringIO.new(JSON.dump('tool_input' => { 'command' => command }))
  end

  def run_gate(command)
    old_stdin = $stdin
    $stdin = stdin_for(command)
    Tyrion::Commands.cmd_hook_claim_gate([], store)
  ensure
    $stdin = old_stdin
  end

  # ── --check ──────────────────────────────────────────────────────────────

  describe '--check' do
    it 'prints armed + version when a tyrion project resolves' do
      allow(Tyrion::Repo).to receive(:tyrion_root).and_return(ctx.tmpdir)
      out, = capture_io { Tyrion::Commands.cmd_hook_claim_gate(['--check'], store) }
      expect(out).to match(/^armed$/)
      expect(out).to match(/^version: 1$/)
    end

    it 'prints fail-open when no tyrion project resolves' do
      allow(Tyrion::Repo).to receive(:tyrion_root).and_return(nil)
      out, = capture_io { Tyrion::Commands.cmd_hook_claim_gate(['--check'], store) }
      expect(out).to match(/fail-open: no \.tyrion project found/)
    end

    it 'always exits 0 (never raises)' do
      allow(Tyrion::Repo).to receive(:tyrion_root).and_return(nil)
      expect { capture_io { Tyrion::Commands.cmd_hook_claim_gate(['--check'], store) } }.not_to raise_error
    end
  end

  # ── normal mode: allow paths ────────────────────────────────────────────

  describe 'normal mode — allow' do
    it 'allows a gated command when the lane owns an in_progress story' do
      make_story(status: 'in_progress', claimed_by: 'claude:123:abc')
      allow(Tyrion::Repo).to receive(:tyrion_root).and_return(ctx.tmpdir)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return('claude:123:abc')

      out, err = capture_io { run_gate('tyrion note my-story progress "did stuff"') }
      expect(out).to eq('')
      expect(err).to eq('')
    end

    it 'allows a non-gated command (e.g. tyrion status) with no lane at all' do
      allow(Tyrion::Repo).to receive(:tyrion_root).and_return(ctx.tmpdir)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)

      out, err = capture_io { run_gate('tyrion status') }
      expect(out).to eq('')
      expect(err).to eq('')
    end

    it 'allows malformed stdin JSON without crashing' do
      old_stdin = $stdin
      $stdin = StringIO.new('not json{{{')
      out, err = capture_io { Tyrion::Commands.cmd_hook_claim_gate([], store) }
      expect(out).to eq('')
      expect(err).to eq('')
    ensure
      $stdin = old_stdin
    end

    it 'allows a lane-less note on a story that is already done (orchestrator affordance)' do
      make_story(status: 'done')
      allow(Tyrion::Repo).to receive(:tyrion_root).and_return(ctx.tmpdir)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)

      out, err = capture_io { run_gate('tyrion note my-story progress "post-hoc note"') }
      expect(out).to eq('')
      expect(err).to eq('')
    end

    it 'allows a lane-less note on a blocked story too' do
      make_story(status: 'blocked')
      allow(Tyrion::Repo).to receive(:tyrion_root).and_return(ctx.tmpdir)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)

      out, err = capture_io { run_gate('tyrion note my-story progress "post-hoc note"') }
      expect(out).to eq('')
      expect(err).to eq('')
    end
  end

  # ── normal mode: block path ─────────────────────────────────────────────

  describe 'normal mode — block' do
    it 'blocks a gated command with no owning lane: exit 2, stderr mentions tyrion start' do
      make_story(status: 'pending')
      allow(Tyrion::Repo).to receive(:tyrion_root).and_return(ctx.tmpdir)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)

      expect { run_gate('tyrion note my-story progress "sneaky"') }
        .to raise_error(having_attributes(status: 2)).and output(/tyrion start/).to_stderr
    end

    it 'blocks tyrion done with no owning lane' do
      make_story(status: 'pending')
      allow(Tyrion::Repo).to receive(:tyrion_root).and_return(ctx.tmpdir)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)

      expect { run_gate('tyrion done my-story "summary"') }
        .to raise_error(having_attributes(status: 2))
    end

    it 'blocks tyrion check with no owning lane' do
      make_story(status: 'pending')
      allow(Tyrion::Repo).to receive(:tyrion_root).and_return(ctx.tmpdir)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)

      expect { run_gate('tyrion check my-story 1 "evidence"') }
        .to raise_error(having_attributes(status: 2))
    end
  end

  # ── outside a tyrion project ─────────────────────────────────────────────

  describe 'outside a tyrion project' do
    it 'allows (fail-open) when no .tyrion root resolves' do
      allow(Tyrion::Repo).to receive(:tyrion_root).and_return(nil)

      out, err = capture_io { run_gate('tyrion done my-story "summary"') }
      expect(out).to eq('')
      expect(err).to eq('')
    end
  end
end
