# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

# Specs for `tyrion prime` — tiered, lane-aware briefing for
# SessionStart/PreCompact hooks. Read-only, fail-open, no flag distinguishing
# hook type (the tier matrix is entirely state-driven).
RSpec.describe 'Tyrion::Commands.cmd_prime' do
  # Point cmd_prime's internal Store.new at the same sqlite file the test's
  # `store` uses, so both connections see the same committed data.
  def point_prime_at(ctx)
    ENV['TYRION_DB_PATH'] = File.join(ctx.tmpdir, 'test.db')
  end

  after { ENV.delete('TYRION_DB_PATH') }

  # ── criterion 1 — Tier 0: no marker ───────────────────────────────────────

  describe 'criterion 1 — no .tyrion/marker' do
    it 'exits 0 with zero output and never touches the DB' do
      Dir.mktmpdir('prime-no-marker-') do |dir|
        stub_repo(worktree_root: dir)
        expect(Tyrion::Store).not_to receive(:new)

        out, err = capture_io { Tyrion::Commands.cmd_prime([]) }
        expect(out).to eq('')
        expect(err).to eq('')
      end
    end
  end

  # ── criterion 2 — Tier 1 ──────────────────────────────────────────────────

  describe 'criterion 2 — Tier 1 briefing (no in_progress story on this lane)' do
    let(:ctx)   { tyrion_worktree(epic_slug: 'auth-epic', epic_name: 'Auth Epic') }
    let(:store) { ctx.store }
    let(:epic)  { ctx.epic }

    before do
      point_prime_at(ctx)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return('claude:1:stamp')
      store.update_project(ctx.project['id'], 'about_md' => "# Ship Auth\nmore body here")
      store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')
    end

    it 'prints north star, epic done/total, claim-next pointer, resume pointer, ≤15 lines' do
      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      lines = out.lines

      expect(lines.length).to be <= 15
      expect(out).to include('Ship Auth')
      expect(out).to match(/epic: auth-epic \(0\/1\)/)
      expect(out).to match(/claim-next/)
      expect(out).to match(/full context: tyrion resume/)
      expect(out).to match(/Rules:/)
    end

    it 'counts done stories correctly in the done/total pointer' do
      s2 = store.create_story(epic_id: epic['id'], slug: 'story-b', title: 'Story B')
      store.update_story(s2['id'], 'status' => 'done')

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(%r{epic: auth-epic \(1/2\)})
    end
  end

  # ── criterion 3 — Tier 2 ──────────────────────────────────────────────────

  describe 'criterion 3 — Tier 2 briefing (lane owns an in_progress story)' do
    let(:token) { 'claude:2:stamp' }
    let(:ctx)   { tyrion_worktree(epic_slug: 'auth-epic') }
    let(:store) { ctx.store }
    let(:epic)  { ctx.epic }

    before do
      point_prime_at(ctx)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(token)
    end

    it 'prints the pocket checklist and next_action, no stale warning when fresh' do
      story = store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')
      store.add_criteria(story['id'], [
        { keyword: 'Then', semantic_kind: 'then', text: 'thing happens' }
      ])
      store.start_story(story['id'], claimed_by: token)
      store.update_story(story['id'], 'next_action' => 'do the thing')

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/epic: auth-epic/)
      expect(out).to match(/story: story-a/)
      expect(out).to match(/next: do the thing/)
      expect(out).to match(/\[\s*\] Then thing happens/)
      expect(out).not_to match(/stale/i)
    end

    it 'omits the next: line when next_action is blank (never fabricates)' do
      story = store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')
      store.start_story(story['id'], claimed_by: token)

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).not_to match(/next:/)
    end

    it 'shows a staleness warning when last_note_at is old' do
      story = store.create_story(epic_id: epic['id'], slug: 'stale-story', title: 'Stale')
      store.start_story(story['id'], claimed_by: token)
      store.update_story(story['id'], 'last_note_at' => (Time.now - (5 * 3600)).utc.iso8601(6))

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/stale/i)
    end

    it 'ends with a Rules block of 5 lines or fewer pointing at resume and /tyrion-implement' do
      story = store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')
      store.start_story(story['id'], claimed_by: token)

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      rules_idx = out.lines.index { |l| l.start_with?('Rules:') }
      expect(rules_idx).not_to be_nil
      rules_block = out.lines[rules_idx..]
      expect(rules_block.length).to be <= 5
      expect(rules_block.join).to match(/tyrion resume story-a/)
      expect(rules_block.join).to match(%r{/tyrion-implement story-a})
    end

    it 'never invents Tier 2 from a pending "assigned:<lane>" placeholder story' do
      story = store.create_story(epic_id: epic['id'], slug: 'assigned-only', title: 'Assigned')
      store.update_story(story['id'], 'claimed_by' => 'assigned:some-lane')
      # status remains 'pending' — not in_progress — so prime must fall to Tier 1

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).not_to match(/story: assigned-only/)
      expect(out).to match(/full context: tyrion resume/)
    end
  end

  # ── Tier 2 mode-contract line (dark_factory epic) ────────────────────────

  describe 'Tier 2 mode-contract line for a dark_factory epic' do
    let(:token) { 'claude:3:stamp' }
    let(:ctx)   { tyrion_worktree(epic_slug: 'auth-epic') }
    let(:store) { ctx.store }
    let(:epic)  { ctx.epic }

    before do
      point_prime_at(ctx)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(token)
      story = store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')
      store.start_story(story['id'], claimed_by: token)
    end

    it 'prints a mode: dark_factory line when the epic mode is dark_factory' do
      store.update_epic(epic['id'], 'mode' => 'dark_factory')
      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/^mode: dark_factory/)
    end

    it 'prints nothing extra when the epic mode is shape/NULL (default)' do
      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).not_to match(/^mode:/)
      expect(out).not_to include('dark_factory')
    end
  end

  # ── criterion 4 — same command, no flag, state-driven tier ───────────────

  describe 'criterion 4 — no flag distinguishes hook type' do
    let(:ctx)   { tyrion_worktree(epic_slug: 'auth-epic') }
    let(:store) { ctx.store }
    let(:epic)  { ctx.epic }

    before do
      point_prime_at(ctx)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return('claude:9:stamp')
    end

    it 'cmd_prime takes no meaningful args — the tier is derived purely from state' do
      story = store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')
      store.start_story(story['id'], claimed_by: 'claude:9:stamp')

      out1, = capture_io { Tyrion::Commands.cmd_prime([]) }
      out2, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out1).to eq(out2)
      expect(out1).to match(/story: story-a/)
    end

    it 'dispatches through Commands.run without a store precondition crashing the process' do
      out, = capture_io { Tyrion::Commands.run(['prime']) }
      expect(out).to match(/story: story-a|epic: auth-epic/)
    end
  end

  # ── criterion 5 — two lanes, two stories, no bleed ────────────────────────

  describe 'criterion 5 — two lanes each see only their own story' do
    let(:token_a) { 'claude:10:stampA' }
    let(:token_b) { 'claude:20:stampB' }
    let(:ctx)     { tyrion_worktree(epic_slug: 'auth-epic') }
    let(:store)   { ctx.store }
    let(:epic)    { ctx.epic }

    before do
      point_prime_at(ctx)
      story_a = store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')
      story_b = store.create_story(epic_id: epic['id'], slug: 'story-b', title: 'Story B')
      store.start_story(story_a['id'], claimed_by: token_a)
      store.start_story(story_b['id'], claimed_by: token_b)
    end

    it "lane A sees only story-a" do
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(token_a)
      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/story: story-a/)
      expect(out).not_to match(/story: story-b/)
    end

    it "lane B sees only story-b" do
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(token_b)
      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/story: story-b/)
      expect(out).not_to match(/story: story-a/)
    end
  end

  # ── criterion 6 — Rules block ≤5 lines on Tier 1 ─────────────────────────

  describe 'criterion 6 — Tier 1 Rules block is 5 lines or fewer' do
    let(:ctx)   { tyrion_worktree(epic_slug: 'auth-epic') }
    let(:store) { ctx.store }
    let(:epic)  { ctx.epic }

    before do
      point_prime_at(ctx)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return('claude:1:stamp')
      store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')
    end

    it 'renders a Rules block with imperative rules, ≤5 lines' do
      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      rules_idx = out.lines.index { |l| l.start_with?('Rules:') }
      expect(rules_idx).not_to be_nil
      rules_block = out.lines[rules_idx..]
      expect(rules_block.length).to be <= 5
      expect(rules_block.join).to match(/claim before code/)
      expect(rules_block.join).to match(%r{evidence via tyrion note/check})
    end
  end

  # ── discovery-filing nudge (open marks count + Rules entry, both tiers) ───

  describe 'discovery-filing nudge' do
    let(:token) { 'claude:42:stamp' }
    let(:ctx)   { tyrion_worktree(epic_slug: 'auth-epic') }
    let(:store) { ctx.store }
    let(:epic)  { ctx.epic }

    before do
      point_prime_at(ctx)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(token)
      store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')
    end

    def mark!(question)
      store.create_discovery(project_id: ctx.project['id'], status: 'mark', question: question)
    end

    def claim_story!
      story = store.find_story(epic['id'], 'story-a')
      store.start_story(story['id'], claimed_by: token)
    end

    it 'reports the open-marks count with the search command in Tier 1' do
      2.times { |i| mark!("thing #{i}") }

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/^marks: 2 open .*tyrion discovery search/)
    end

    it 'reports the open-marks count with the search command in Tier 2' do
      claim_story!
      mark!('a thing')

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/^story: story-a/)
      expect(out).to match(/^marks: 1 open .*tyrion discovery search/)
    end

    it 'counts only open marks, not resolved or in-flight discoveries' do
      mark!('still open')
      store.create_discovery(project_id: ctx.project['id'], status: 'findings_ready', question: 'done')
      store.create_discovery(project_id: ctx.project['id'], status: 'deferred', question: 'later')

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/^marks: 1 open/)
    end

    it 'omits the marks line entirely when there are no open marks' do
      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).not_to match(/^marks:/)
    end

    it 'counts only the active project, not marks filed against a sibling project' do
      mark!('ours')
      other = store.create_project(slug: 'other-proj', name: 'Other')
      2.times { |i| store.create_discovery(project_id: other['id'], status: 'mark', question: "theirs #{i}") }

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/^marks: 1 open/)
    end

    it 'adds the identical filing rule to both tiers, marks or not' do
      rule = Tyrion::Commands::PRIME_FILING_RULE

      tier1, = capture_io { Tyrion::Commands.cmd_prime([]) }
      claim_story!
      tier2, = capture_io { Tyrion::Commands.cmd_prime([]) }

      expect(rule).to match(/file what you notice \(tyrion mark --auto\); search before filing/)
      expect(tier1.lines.map(&:chomp)).to include(rule)
      expect(tier2.lines.map(&:chomp)).to include(rule)
    end

    it 'keeps both Rules blocks at 5 lines or fewer with the added rule' do
      mark!('a thing')

      tier1, = capture_io { Tyrion::Commands.cmd_prime([]) }
      claim_story!
      tier2, = capture_io { Tyrion::Commands.cmd_prime([]) }

      [tier1, tier2].each do |out|
        rules_idx = out.lines.index { |l| l.start_with?('Rules:') }
        expect(out.lines[rules_idx..].length).to be <= 5
      end
    end

    it 'suppresses the whole briefing rather than half of it when the marks count blows up' do
      allow_any_instance_of(Tyrion::Store).to receive(:count_open_marks).and_raise(RuntimeError, 'boom')

      out = err = nil
      expect { out, err = capture_io { Tyrion::Commands.cmd_prime([]) } }.not_to raise_error
      expect(err).to match(/tyrion prime: warning/)
      # The count is read before the first puts, so a failure can never leave a
      # header printed with its Rules block missing.
      expect(out).to eq('')
    end
  end

  # ── criterion 7 — read-only ───────────────────────────────────────────────

  describe 'criterion 7 — prime is provably read-only' do
    let(:token) { 'claude:7:stamp' }
    let(:ctx)   { tyrion_worktree(epic_slug: 'auth-epic') }
    let(:store) { ctx.store }
    let(:epic)  { ctx.epic }

    before do
      point_prime_at(ctx)
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(token)
    end

    it 'never calls Store#update_story, Store#claim_next_story, or Repo.write_active_story' do
      store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')

      expect_any_instance_of(Tyrion::Store).not_to receive(:update_story)
      expect_any_instance_of(Tyrion::Store).not_to receive(:claim_next_story)
      expect(Tyrion::Repo).not_to receive(:write_active_story)

      capture_io { Tyrion::Commands.cmd_prime([]) }
    end

    it 'leaves the story row and .tyrion/active-story file byte-for-byte unchanged' do
      story = store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')
      store.start_story(story['id'], claimed_by: token)

      lane_dir = Tyrion::Repo.lane_dir(token, ctx.tmpdir)
      FileUtils.mkdir_p(lane_dir)
      File.write(File.join(lane_dir, 'active-story'), "story-a\n")
      # Un-stub active-story reads/writes so the real file is consulted.
      allow(Tyrion::Repo).to receive(:active_story).and_call_original
      allow(Tyrion::Repo).to receive(:lane_dir).and_call_original
      allow(Tyrion::Repo).to receive(:worktree_root).and_return(ctx.tmpdir)

      before_row  = store.find_story(epic['id'], 'story-a')
      before_file = File.read(File.join(lane_dir, 'active-story'))

      capture_io { Tyrion::Commands.cmd_prime([]) }

      after_row  = store.find_story(epic['id'], 'story-a')
      after_file = File.read(File.join(lane_dir, 'active-story'))

      expect(after_row).to eq(before_row)
      expect(after_file).to eq(before_file)
    end
  end

  # ── criterion 8 — fail-open ───────────────────────────────────────────────

  describe 'criterion 8 — fail-open on error / corrupt / missing DB / timeout' do
    let(:ctx) { tyrion_worktree(epic_slug: 'auth-epic') }

    it 'exits 0 with a stderr warning when the DB file is corrupt' do
      Dir.mktmpdir('prime-corrupt-db-') do |dir|
        FileUtils.mkdir_p(File.join(dir, '.tyrion'))
        File.write(File.join(dir, '.tyrion', 'marker'), '')
        File.write(File.join(dir, '.tyrion', 'active-project'), "myproj\n")
        stub_repo(worktree_root: dir, active_project: 'myproj')

        garbage_db = File.join(dir, 'garbage.db')
        File.write(garbage_db, 'not a sqlite file at all')
        ENV['TYRION_DB_PATH'] = garbage_db

        out = err = nil
        expect { out, err = capture_io { Tyrion::Commands.cmd_prime([]) } }.not_to raise_error
        expect(out).to eq('')
        expect(err).to match(/tyrion prime: warning/)
      end
    end

    it 'exits 0 with no crash when the DB file does not exist yet (fresh/missing DB)' do
      Dir.mktmpdir('prime-missing-db-') do |dir|
        FileUtils.mkdir_p(File.join(dir, '.tyrion'))
        File.write(File.join(dir, '.tyrion', 'marker'), '')
        File.write(File.join(dir, '.tyrion', 'active-project'), "myproj\n")
        stub_repo(worktree_root: dir, active_project: 'myproj')

        ENV['TYRION_DB_PATH'] = File.join(dir, 'does-not-exist-yet.db')

        expect { capture_io { Tyrion::Commands.cmd_prime([]) } }.not_to raise_error
      end
    end

    it 'exits 0 with a stderr warning on timeout' do
      point_prime_at(ctx)
      allow(Tyrion::Store).to receive(:new).and_raise(Timeout::Error, 'execution expired')

      out, err = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to eq('')
      expect(err).to match(/tyrion prime: warning/)
    end

    it 'exits 0 with a stderr warning on any other internal StandardError' do
      point_prime_at(ctx)
      allow(Tyrion::Store).to receive(:new).and_raise(RuntimeError, 'boom')

      out, err = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to eq('')
      expect(err).to match(/tyrion prime: warning/)
    end
  end

  # ── empty-state (not one of the 8 criteria, but must not error) ───────────

  describe 'no active project / no active epic — silent no-op' do
    it 'is silent when the marker exists but no active project is configured' do
      Dir.mktmpdir('prime-no-project-') do |dir|
        FileUtils.mkdir_p(File.join(dir, '.tyrion'))
        File.write(File.join(dir, '.tyrion', 'marker'), '')
        stub_repo(worktree_root: dir, active_project: nil)

        out, err = capture_io { Tyrion::Commands.cmd_prime([]) }
        expect(out).to eq('')
        expect(err).to eq('')
      end
    end

    it 'is silent when there is an active project but no active epic' do
      ctx = tyrion_worktree(project_slug: 'myproj')
      point_prime_at(ctx)
      stub_repo(worktree_root: ctx.tmpdir, active_project: 'myproj', active_epic: nil)

      out, err = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to eq('')
      expect(err).to eq('')
    end
  end
end
