# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
require_relative '../web/lib/tyrion_web/data'
require_relative '../web/lib/tyrion_web/presenter'
Dir.glob(File.expand_path('../web/views/*.rb', __dir__)).sort.each { |f| require f }

# global-view-discovery-momentum: card_status precedence between story activity
# and discovery activity. This is exactly the logic that silently misrepresented
# a spike-only project (zero epics, real discoveries) as :idle -- root cause of
# "crimson-maestro shows idle" (features/spike-visibility.context.md).
RSpec.describe 'TyrionWeb::Data.load_global_view' do
  let(:ctx)     { tyrion_worktree(project_slug: 'gv-proj', project_name: 'GV Test') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }

  before do
    allow(TyrionWeb::Data).to receive(:store).and_return(store)
    # Snapshot.current is process-wide and does not key its cache on which
    # store was passed in (lane A's own spec/liveness/snapshot_spec.rb resets
    # it the same way) -- without this, a snapshot built by an earlier spec
    # file's temp DB could leak into these examples' cards.
    Tyrion::Liveness::Snapshot.reset!
  end
  after { Tyrion::Liveness::Snapshot.reset! }

  def card_for(proj)
    TyrionWeb::Data.load_global_view[:project_cards].find { |c| c[:project]['id'] == proj['id'] }
  end

  # A lane row in the shape Tyrion::Liveness::Snapshot hands over, built via
  # the real (already-tested) Liveness.lane_row so this file never re-derives
  # ladder logic lane A already owns -- see spec/liveness_spec.rb's `lane`.
  def fake_lane_row(project_id:, story_id: 'st-1', status: 'in_progress', now: Time.now, **over)
    lane = {
      'story_id' => story_id, 'slug' => story_id, 'status' => status,
      'claimed_by' => 'lane-x', 'epic_slug' => 'e1', 'project_slug' => 'p', 'project_id' => project_id,
      'started_at' => nil, 'updated_at' => nil, 'last_note_at' => nil,
      'note' => nil, 'gate' => nil, 'commit' => nil, 'criterion' => nil,
      'liveness' => :unknown, 'resolution' => nil, 'worktree' => nil
    }.merge(over)
    Tyrion::Liveness.lane_row(lane, now: now)
  end

  def stub_snapshot_rows(rows, project_activity: {})
    allow(Tyrion::Liveness::Snapshot).to receive(:current).and_return(
      Tyrion::Liveness::Snapshot::EMPTY.merge(
        'built_at' => Time.now.to_i, 'stale' => false, 'rows' => rows, 'project_activity' => project_activity
      )
    )
  end

  describe 'a project with zero epics but open discoveries' do
    it 'reads :discovery, not :idle, when a mark is filed' do
      store.create_discovery(project_id: project['id'], question: 'noticed something', status: 'mark')

      card = card_for(project)
      expect(card[:status]).to eq :discovery
    end

    it 'reads :discovery when a spike is active' do
      store.create_discovery(project_id: project['id'], question: 'investigating', status: 'active_spike')

      expect(card_for(project)[:status]).to eq :discovery
    end

    it 'reads :discovery when a finding is ready to promote' do
      store.create_discovery(project_id: project['id'], question: 'q', finding: 'f', status: 'findings_ready')

      expect(card_for(project)[:status]).to eq :discovery
    end

    it 'carries the discovery summary counts on the card for the one-line render' do
      store.create_discovery(project_id: project['id'], question: 'q1', finding: 'f1', status: 'findings_ready')
      store.create_discovery(project_id: project['id'], question: 'q2', status: 'mark')
      store.create_discovery(project_id: project['id'], question: 'q3', status: 'mark')

      disc_summary = card_for(project)[:disc_summary]
      expect(disc_summary[:ready_count]).to eq 1
      expect(disc_summary[:mark_count]).to eq 2
    end
  end

  describe 'a project with real epic/story activity' do
    let(:epic) { store.create_epic(project_id: project['id'], slug: 'e1', name: 'E1') }

    it 'still reads :active as it does today, discoveries present or not' do
      story = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.start_story(story['id'], claimed_by: 'lane-1')
      store.create_discovery(project_id: project['id'], question: 'noise', status: 'mark')

      expect(card_for(project)[:status]).to eq :active
    end

    it 'still reads :done when every story is done, discoveries present or not' do
      story = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.update_story(story['id'], status: 'done')
      store.create_discovery(project_id: project['id'], question: 'noise', status: 'active_spike')

      expect(card_for(project)[:status]).to eq :done
    end

    it 'still reads :idle for a pending-only epic with no discoveries, as it does today' do
      store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')

      expect(card_for(project)[:status]).to eq :idle
    end

    it 'still reads :idle for a pending-only epic even with open marks -- story activity outranks discovery activity' do
      store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.create_discovery(project_id: project['id'], question: 'noise', status: 'mark')

      expect(card_for(project)[:status]).to eq :idle
    end
  end

  describe 'a project with neither epic nor discovery activity' do
    it 'still reads :idle' do
      expect(card_for(project)[:status]).to eq :idle
    end
  end

  # fleet-visibility/global-view-activity-sort
  describe 'sort order' do
    it 'sorts by project_activity activity_at descending, falling back to projects.updated_at only when nil' do
      old_activity   = store.create_project(slug: 'gv-old', name: 'Old')
      recent_activity = store.create_project(slug: 'gv-recent', name: 'Recent')
      no_activity    = store.create_project(slug: 'gv-fresh-row', name: 'Fresh Row') # updated_at is "now"

      # project_activity comes off the snapshot (not a second Store call --
      # see load_global_view's comment on why), so it's stubbed there.
      stub_snapshot_rows([], project_activity: {
        old_activity['id']    => { 'activity_at' => (Time.now - 10 * 86_400).utc.iso8601, 'done' => 0, 'total' => 0 },
        recent_activity['id'] => { 'activity_at' => (Time.now - 1 * 86_400).utc.iso8601, 'done' => 0, 'total' => 0 },
        no_activity['id']     => { 'activity_at' => nil, 'done' => 0, 'total' => 0 }
      })

      relevant = %w[gv-old gv-recent gv-fresh-row]
      slugs = TyrionWeb::Data.load_global_view[:project_cards].map { |c| c[:project]['slug'] }
                             .select { |s| relevant.include?(s) }
      # no_activity falls back to its own real (just-created, i.e. newest) updated_at,
      # so it outranks both projects with an older derived activity_at.
      expect(slugs).to eq %w[gv-fresh-row gv-recent gv-old]
    end
  end

  # fleet-visibility/global-view-activity-sort
  describe 'worst-lane glyph and lane count' do
    let(:epic) { store.create_epic(project_id: project['id'], slug: 'e1', name: 'E1') }

    it 'is the worst state across every in-progress lane in the project, with the lane count when > 1' do
      story = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.start_story(story['id'], claimed_by: 'lane-1')

      live_row = fake_lane_row(project_id: project['id'], story_id: story['id'],
                                'updated_at' => Time.now.utc.iso8601)
      dead_row = fake_lane_row(project_id: project['id'], story_id: 'st-2', 'liveness' => :dead,
                                'updated_at' => Time.now.utc.iso8601)
      stub_snapshot_rows([live_row, dead_row])

      card = card_for(project)
      expect(card[:worst_lane_state]).to eq 'dead'
      expect(card[:lane_count]).to eq 2
    end

    it 'reports lane_count 1 for a single lane (the view suppresses the ×N suffix at 1)' do
      story = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.start_story(story['id'], claimed_by: 'lane-1')

      stub_snapshot_rows([fake_lane_row(project_id: project['id'], story_id: story['id'],
                                         'updated_at' => Time.now.utc.iso8601)])

      card = card_for(project)
      expect(card[:worst_lane_state]).to eq 'live'
      expect(card[:lane_count]).to eq 1
    end

    it 'excludes blocked rows from the project glyph -- only in-progress lanes count' do
      story = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.start_story(story['id'], claimed_by: 'lane-1')

      live_row    = fake_lane_row(project_id: project['id'], story_id: story['id'],
                                   'updated_at' => Time.now.utc.iso8601)
      blocked_row = fake_lane_row(project_id: project['id'], story_id: 'st-2', status: 'blocked',
                                   'blocked_on' => 'waiting on review')
      stub_snapshot_rows([live_row, blocked_row])

      card = card_for(project)
      expect(card[:worst_lane_state]).to eq 'live'
      expect(card[:lane_count]).to eq 1
    end
  end

  # fleet-visibility/global-view-activity-sort
  describe 'TyrionWeb::Data.global_poll_token' do
    def card(slug:, status: :active, worst: 'live', done: 1, total: 2, activity_at: '2026-09-01T00:00:00Z')
      { project: { 'slug' => slug }, status: status, worst_lane_state: worst, done: done, total: total, activity_at: activity_at }
    end

    it 'is stable for the same cards in the same order' do
      cards = [card(slug: 'a'), card(slug: 'b')]
      expect(TyrionWeb::Data.global_poll_token(cards)).to eq TyrionWeb::Data.global_poll_token(cards)
    end

    it 'changes when the sort order changes' do
      a = TyrionWeb::Data.global_poll_token([card(slug: 'a'), card(slug: 'b')])
      b = TyrionWeb::Data.global_poll_token([card(slug: 'b'), card(slug: 'a')])
      expect(a).not_to eq b
    end

    it 'changes when a worst_lane_state, done/total, or activity_at changes' do
      base = [card(slug: 'a')]
      expect(TyrionWeb::Data.global_poll_token(base)).not_to eq(
        TyrionWeb::Data.global_poll_token([card(slug: 'a', worst: 'dead')])
      )
      expect(TyrionWeb::Data.global_poll_token(base)).not_to eq(
        TyrionWeb::Data.global_poll_token([card(slug: 'a', done: 2)])
      )
      expect(TyrionWeb::Data.global_poll_token(base)).not_to eq(
        TyrionWeb::Data.global_poll_token([card(slug: 'a', activity_at: '2026-09-01T00:00:01Z')])
      )
    end

    it 'does not change merely because wall-clock time has passed, for the same card values' do
      cards = [card(slug: 'a')]
      first = TyrionWeb::Data.global_poll_token(cards)
      sleep 0.01
      second = TyrionWeb::Data.global_poll_token(cards)
      expect(first).to eq second
    end
  end
end

# fleet-visibility/global-view-activity-sort: Presenter helpers the card glyph
# and worst-lane ranking depend on -- pure functions, no DB needed.
RSpec.describe 'TyrionWeb::Presenter liveness helpers' do
  describe '.liveness_glyph' do
    it 'returns a glyph/css/label for every known state' do
      %w[dead unclaimed dispatched worktree_missing worktree_ambiguous blocked stalled stalled? quiet working live].each do |state|
        g = TyrionWeb::Presenter.liveness_glyph(state)
        expect(g[:glyph]).to be_a(String)
        expect(g[:css]).to be_a(String)
      end
    end

    it 'falls back to a neutral glyph for an unrecognized state rather than raising' do
      expect { TyrionWeb::Presenter.liveness_glyph('made_up') }.not_to raise_error
      expect(TyrionWeb::Presenter.liveness_glyph(nil)[:css]).to eq 'lv-unknown'
    end
  end

  describe '.worst_lane_state' do
    it 'ranks dead as worse than every other state' do
      expect(TyrionWeb::Presenter.worst_lane_state(%w[live working quiet dead])).to eq 'dead'
    end

    it 'ranks a worktree problem worse than stalled, and stalled worse than quiet' do
      expect(TyrionWeb::Presenter.worst_lane_state(%w[quiet worktree_missing])).to eq 'worktree_missing'
      expect(TyrionWeb::Presenter.worst_lane_state(%w[quiet stalled])).to eq 'stalled'
    end

    it 'ranks live as the best (least urgent) state' do
      expect(TyrionWeb::Presenter.worst_lane_state(%w[live working quiet])).to eq 'quiet'
    end

    it 'returns nil for an empty or all-nil set' do
      expect(TyrionWeb::Presenter.worst_lane_state([])).to be_nil
      expect(TyrionWeb::Presenter.worst_lane_state([nil, nil])).to be_nil
    end
  end
end

# fleet-visibility/global-view-activity-sort: the glyph must render even when
# the project's in-progress lane lives outside the active epic -- `in_progress`
# is the legacy active-epic-only pick, but lane_count/worst_lane_state are
# project-wide, and the glyph must not go missing in exactly the case it was
# built to cover.
RSpec.describe 'Views::GlobalView lane glyph' do
  def card(in_progress: nil, worst_lane_state: 'dead', lane_count: 1, status: :active)
    {
      project: { 'id' => 'p1', 'slug' => 'p1', 'name' => 'P1' },
      active_epic: nil, in_progress: in_progress,
      done: 0, pending: 0, blocked: 0, active: 1, total: 1,
      last_note_at: nil, status: status, disc_summary: { spike: nil, ready_count: 0, mark_count: 0 },
      worst_lane_state: worst_lane_state, lane_count: lane_count
    }
  end

  def render(cards)
    Views::GlobalView.new(project_cards: cards, project: nil, epic: nil, stories: [],
                           disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }, token: 'tok').call
  end

  it 'renders the worst-lane glyph even when in_progress is nil (lane outside the active epic)' do
    html = render([card(in_progress: nil, worst_lane_state: 'dead', lane_count: 1)])

    expect(html).to include('lv-dead')
    expect(html).to include('No story in progress')
  end

  it 'still renders the glyph alongside the actual story text when in_progress is present' do
    story = { 'slug' => 'my-story', 'status' => 'in_progress', 'last_note_at' => nil }
    html  = render([card(in_progress: story, worst_lane_state: 'live', lane_count: 1)])

    expect(html).to include('lv-live')
    expect(html).to include('my-story')
  end

  it 'renders no glyph at all when the project has no lanes' do
    html = render([card(in_progress: nil, worst_lane_state: nil, lane_count: 0, status: :idle)])

    expect(html).not_to match(/lv-\w/)
  end
end
