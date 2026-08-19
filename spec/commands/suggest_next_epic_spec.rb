# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'suggest next epic on a drained epic' do
  let(:ctx)     { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { ctx.epic }

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
    allow(Tyrion::Repo).to receive(:clear_active_story)
  end

  def make_epic(slug, pending: 1, status: 'active')
    e = store.create_epic(project_id: project['id'], slug: slug, name: slug)
    store.update_epic(e['id'], 'status' => status) unless status == 'active'
    pending.times { |i| store.create_story(epic_id: e['id'], slug: "#{slug}-s#{i}", title: 's') }
    store.find_epic_by_id(e['id'])
  end

  def done_story(slug)
    s = store.create_story(epic_id: epic['id'], slug: slug, title: slug)
    store.start_story(s['id'])
    store.find_story(epic['id'], slug)
  end

  # ── Store#next_pending_epic (criterion 8, 9) ──────────────────────────────
  describe 'Store#next_pending_epic' do
    it 'returns the earliest-created epic with a pending story' do
      make_epic('alpha')
      make_epic('beta')
      nxt = store.next_pending_epic(project['id'])
      expect(nxt['slug']).to eq('alpha')
    end

    it 'excludes the given epic id' do
      first = make_epic('alpha')
      make_epic('beta')
      nxt = store.next_pending_epic(project['id'], exclude_epic_id: first['id'])
      expect(nxt['slug']).to eq('beta')
    end

    it 'skips epics with no pending stories' do
      make_epic('alpha', pending: 0)
      make_epic('beta')
      expect(store.next_pending_epic(project['id'])['slug']).to eq('beta')
    end

    it 'skips done and abandoned epics' do
      make_epic('alpha', status: 'done')
      make_epic('beta', status: 'abandoned')
      make_epic('gamma')
      expect(store.next_pending_epic(project['id'])['slug']).to eq('gamma')
    end

    it 'skips archived epics' do
      arch = make_epic('alpha')
      store.archive_epic(arch['id'])
      make_epic('beta')
      expect(store.next_pending_epic(project['id'])['slug']).to eq('beta')
    end

    it 'returns nil when no epic has a pending story' do
      make_epic('alpha', pending: 0)
      expect(store.next_pending_epic(project['id'])).to be_nil
    end

    it 'skips a waiting epic (unmet prerequisite) even though it has pending work' do
      alpha = make_epic('alpha')
      beta  = make_epic('beta')
      store.add_epic_dependency(alpha['id'], 'beta')
      expect(store.next_pending_epic(project['id'])['slug']).to eq('beta')
    end
  end

  # ── cmd_done (criteria 1-3) ───────────────────────────────────────────────
  describe 'cmd_done on the last story' do
    it 'suggests the next epic when the epic drains' do
      make_epic('beta')
      last = done_story('last')
      out = StringIO.new
      Tyrion::Commands.cmd_done(['last', 'wrapped up'], store,
        input: StringIO.new("n\n"), output: out)
      expect(out.string).to match(/Epic 'my-epic' complete\. Next: tyrion epic activate beta/)
    end

    it 'prints "All epics complete" when nothing else has pending stories' do
      last = done_story('last')
      out = StringIO.new
      Tyrion::Commands.cmd_done(['last', 'wrapped up'], store,
        input: StringIO.new("n\n"), output: out)
      expect(out.string).to match(/All epics complete/)
    end

    it 'does not suggest while pending stories remain in the epic' do
      make_epic('beta')
      store.create_story(epic_id: epic['id'], slug: 'later', title: 'later')
      last = done_story('last')
      out = StringIO.new
      Tyrion::Commands.cmd_done(['last', 'wrapped up'], store,
        input: StringIO.new("n\n"), output: out)
      expect(out.string).not_to match(/complete\. Next:/)
      expect(out.string).not_to match(/All epics complete/)
    end
  end

  # ── cmd_status (criteria 4-5) ─────────────────────────────────────────────
  describe 'cmd_status on a drained epic' do
    it 'includes the next-epic suggestion below the story list' do
      make_epic('beta')
      s = done_story('last')
      store.complete_story(s['id'], 'done', force: true)
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to match(/Epic 'my-epic' complete\. Next: tyrion epic activate beta/)
    end

    it 'omits the suggestion when stories remain' do
      store.create_story(epic_id: epic['id'], slug: 'later', title: 'later')
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).not_to match(/Next: tyrion epic activate/)
    end
  end

  # ── cmd_claim_next (criteria 6-7) ─────────────────────────────────────────
  describe 'cmd_claim_next on a drained epic' do
    it 'prints the suggestion and exits cleanly instead of erroring' do
      make_epic('beta')
      s = done_story('last')
      store.complete_story(s['id'], 'done', force: true)
      out, = capture_io do
        expect { Tyrion::Commands.cmd_claim_next([], store) }.not_to raise_error
      end
      expect(out).to match(/Epic 'my-epic' complete\. Next: tyrion epic activate beta/)
    end

    it 'still errors when the epic has claimable pending work' do
      store.create_story(epic_id: epic['id'], slug: 'later', title: 'later')
      allow(Tyrion::Repo).to receive(:write_active_story)
      # nothing drained → should not print the suggestion
      out, = capture_io { Tyrion::Commands.cmd_claim_next([], store) }
      expect(out).not_to match(/complete\. Next:/)
    end
  end

  # ── print_next_epic_suggestion reports the whole ready set ──────────────
  describe 'print_next_epic_suggestion with more than one ready epic' do
    it 'lists every ready epic rather than picking one arbitrarily' do
      make_epic('beta')
      make_epic('gamma')
      last = done_story('last')
      out = StringIO.new
      Tyrion::Commands.print_next_epic_suggestion(store, epic, output: out)
      expect(out.string).to match(/Ready: beta, gamma/)
    end

    it 'never includes a waiting epic in the ready set' do
      beta  = make_epic('beta')
      gamma = make_epic('gamma')
      store.add_epic_dependency(gamma['id'], 'beta')
      last = done_story('last')
      out = StringIO.new
      Tyrion::Commands.print_next_epic_suggestion(store, epic, output: out)
      expect(out.string).to match(/Next: tyrion epic activate beta/)
      expect(out.string).not_to match(/gamma/)
    end
  end
end
