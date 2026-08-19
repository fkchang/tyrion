# frozen_string_literal: true

require 'spec_helper'

# Specs for epic-eligibility-routing: every path that suggests or starts work
# routes through Store#unmet_prereqs. Coverage here is the "warn, never
# hard-refuse" behavior on tyrion start / claim-next / epic activate, the
# waiting line on tyrion prime's Tier 1, and the unlock announcement shared by
# all three seal call sites. Store-level eligibility math itself (unmet_prereqs,
# ready_epics, seal_epic's container invariant) is covered in store_spec.rb.

RSpec.describe 'epic eligibility routing' do
  let(:ctx)     { tyrion_worktree(epic_slug: 'dependent') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { ctx.epic } # slug: 'dependent'

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
    allow(Tyrion::Repo).to receive(:clear_active_story)
    allow(Tyrion::Repo).to receive(:write_active_story)
  end

  # Makes `epic` ("dependent") wait on a fresh unsealed prerequisite epic
  # named "prereq".
  def make_epic_waiting!
    store.create_epic(project_id: project['id'], slug: 'prereq', name: 'prereq')
    store.add_epic_dependency(epic['id'], 'prereq')
  end

  # ── tyrion start ───────────────────────────────────────────────────────
  describe 'tyrion start on a story in a waiting epic' do
    it 'warns naming the unmet prerequisite and the escape hatch, but still starts the story' do
      make_epic_waiting!
      story = store.create_story(epic_id: epic['id'], slug: 'a', title: 'a')

      out, = capture_io { Tyrion::Commands.cmd_start(['a'], store) }
      expect(out).to match(/waiting on: prereq \(active\)/)
      expect(out).to match(/tyrion epic depends rm dependent <dep-slug>/)
      expect(out).to match(/Started: a/)
      expect(store.find_story(epic['id'], 'a')['status']).to eq('in_progress')
    end

    it 'prints no warning when the epic has no unmet prerequisites' do
      story = store.create_story(epic_id: epic['id'], slug: 'a', title: 'a')
      out, = capture_io { Tyrion::Commands.cmd_start(['a'], store) }
      expect(out).not_to match(/waiting on/)
    end
  end

  # ── tyrion claim-next ──────────────────────────────────────────────────
  describe 'tyrion claim-next on a waiting epic' do
    it 'warns but still claims a pending story' do
      make_epic_waiting!
      store.create_story(epic_id: epic['id'], slug: 'a', title: 'a')

      out, = capture_io { Tyrion::Commands.cmd_claim_next([], store) }
      expect(out).to match(/waiting on: prereq/)
      expect(out).to match(/Claimed: a/)
    end
  end

  # ── tyrion epic activate ───────────────────────────────────────────────
  describe 'tyrion epic activate on a waiting epic' do
    before { stub_repo(active_epic: nil) }

    it 'warns but still activates the epic' do
      make_epic_waiting!
      out, = capture_io { Tyrion::Commands.cmd_epic_activate(['dependent'], store) }
      expect(out).to match(/waiting on: prereq/)
      expect(out).to match(/Active epic set to:.*\[dependent\]/)
    end

    it 'prints no warning for an eligible epic' do
      out, = capture_io { Tyrion::Commands.cmd_epic_activate(['dependent'], store) }
      expect(out).not_to match(/waiting on/)
    end
  end

  # ── tyrion prime Tier 1 ────────────────────────────────────────────────
  describe "tyrion prime's Tier 1 briefing on a waiting epic" do
    before { ENV['TYRION_DB_PATH'] = File.join(ctx.tmpdir, 'test.db') }
    after  { ENV.delete('TYRION_DB_PATH') }

    it 'omits next: tyrion claim-next and shows what it is waiting on instead' do
      make_epic_waiting!
      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).not_to match(/next: tyrion claim-next/)
      expect(out).to match(/epic waiting on: prereq \(active\)/)
    end

    it 'prints next: tyrion claim-next when the epic is eligible' do
      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/next: tyrion claim-next/)
      expect(out).not_to match(/waiting on/)
    end
  end

  # ── seal unlock announcement ───────────────────────────────────────────
  describe 'sealing prints what it unlocked' do
    it 'cmd_epic_complete reports a newly-eligible dependent' do
      make_epic_waiting!
      # Seal 'dependent' itself first with no stories -> use --force, then
      # verify sealing the *prerequisite* unlocks 'dependent'.
      prereq = store.find_epic(project['id'], 'prereq')
      s = store.create_story(epic_id: prereq['id'], slug: 'ps', title: 'ps')
      store.complete_story(s['id'], 'done', force: true)

      out, = capture_io { Tyrion::Commands.cmd_epic_complete(['prereq'], store) }
      expect(out).to match(/Epic prereq sealed as done\./)
      expect(out).to match(/Unlocked: dependent/)
    end

    it 'maybe_prompt_epic_seal reports a newly-eligible dependent' do
      make_epic_waiting!
      prereq = store.find_epic(project['id'], 'prereq')
      s = store.create_story(epic_id: prereq['id'], slug: 'ps', title: 'ps')
      store.start_story(s['id'])
      store.complete_story(s['id'], 'done', force: true)

      out = StringIO.new
      Tyrion::Commands.maybe_prompt_epic_seal(store, store.find_epic_by_id(prereq['id']),
        input: StringIO.new("y\n"), output: out)
      expect(out.string).to match(/sealed as done/)
      expect(out.string).to match(/Unlocked: dependent/)
    end

    it 'prints nothing extra when nothing new became eligible' do
      story = store.create_story(epic_id: epic['id'], slug: 'a', title: 'a')
      store.complete_story(story['id'], 'done', force: true)

      out, = capture_io { Tyrion::Commands.cmd_epic_complete(['dependent'], store) }
      expect(out).not_to match(/Unlocked:/)
    end
  end
end
