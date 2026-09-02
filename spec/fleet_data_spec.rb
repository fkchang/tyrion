# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
require_relative '../web/lib/tyrion_web/data'
require_relative '../web/lib/tyrion_web/presenter'
Dir.glob(File.expand_path('../web/views/**/*.rb', __dir__)).sort.each { |f| require f }

# fleet-visibility/fleet-board: cross-project board, one row per in-progress
# story grouped by project, sorted by attention weight then recency, with
# idle projects folded into a footer line and a "needs you" band up top.
RSpec.describe 'TyrionWeb::Data.load_fleet_view' do
  let(:ctx)     { tyrion_worktree(project_slug: 'fl-proj', project_name: 'FL Test') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { store.create_epic(project_id: project['id'], slug: 'e1', name: 'E1') }

  before do
    allow(TyrionWeb::Data).to receive(:store).and_return(store)
    Tyrion::Liveness::Snapshot.reset!
  end
  after { Tyrion::Liveness::Snapshot.reset! }

  # A lane row in the shape Tyrion::Liveness::Snapshot hands over, built via
  # the real (already-tested) Liveness.lane_row -- see spec/liveness_spec.rb.
  def fake_lane_row(project_id:, story_id: 'st-1', slug: story_id, status: 'in_progress', now: Time.now, **over)
    lane = {
      'story_id' => story_id, 'slug' => slug, 'status' => status,
      'claimed_by' => 'lane-x', 'epic_slug' => 'e1', 'project_slug' => 'p', 'project_id' => project_id,
      'started_at' => nil, 'updated_at' => nil, 'last_note_at' => nil,
      'note' => nil, 'gate' => nil, 'commit' => nil, 'criterion' => nil,
      'liveness' => :unknown, 'resolution' => nil, 'worktree' => nil
    }.merge(over)
    Tyrion::Liveness.lane_row(lane, now: now)
  end

  def stub_snapshot(rows, project_activity: {})
    allow(Tyrion::Liveness::Snapshot).to receive(:current).and_return(
      Tyrion::Liveness::Snapshot::EMPTY.merge(
        'built_at' => Time.now.to_i, 'stale' => false, 'rows' => rows,
        'attention' => Tyrion::Liveness.attention_items(rows), 'project_activity' => project_activity
      )
    )
  end

  describe 'grouping and row unit' do
    it 'groups rows by project, one row per in-progress story' do
      story = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.start_story(story['id'], claimed_by: 'lane-1')

      row = fake_lane_row(project_id: project['id'], story_id: story['id'], slug: 's1',
                           'updated_at' => Time.now.utc.iso8601)
      stub_snapshot([row])

      view = TyrionWeb::Data.load_fleet_view
      group = view[:projects].find { |g| g[:project]['id'] == project['id'] }
      expect(group[:rows].map { |r| r['slug'] }).to eq ['s1']
    end

    it 'excludes blocked rows from the row list -- only in-progress lanes are rows' do
      blocked_row = fake_lane_row(project_id: project['id'], story_id: 'st-2', status: 'blocked',
                                   'blocked_on' => 'waiting')
      stub_snapshot([blocked_row])

      view = TyrionWeb::Data.load_fleet_view
      expect(view[:projects]).to be_empty
      # ...but it still surfaces via attention (blocked qualifies as an item).
      expect(view[:attention].map { |a| a['story_id'] }).to include('st-2')
    end
  end

  describe 'row sort inside a project: attention weight then newest_at descending' do
    it 'puts a dead lane before a live one regardless of recency' do
      live_row = fake_lane_row(project_id: project['id'], story_id: 'st-live', slug: 'live-story',
                                'updated_at' => Time.now.utc.iso8601)
      dead_row = fake_lane_row(project_id: project['id'], story_id: 'st-dead', slug: 'dead-story',
                                'liveness' => :dead, 'updated_at' => (Time.now - 3600).utc.iso8601)
      stub_snapshot([live_row, dead_row])

      group = TyrionWeb::Data.load_fleet_view[:projects].first
      expect(group[:rows].map { |r| r['slug'] }).to eq %w[dead-story live-story]
    end

    it 'orders two equally-urgent (non-attention) rows by newest_at descending' do
      newer = fake_lane_row(project_id: project['id'], story_id: 'st-a', slug: 'newer',
                             'updated_at' => Time.now.utc.iso8601)
      older = fake_lane_row(project_id: project['id'], story_id: 'st-b', slug: 'older',
                             'updated_at' => (Time.now - 600).utc.iso8601)
      stub_snapshot([older, newer])

      group = TyrionWeb::Data.load_fleet_view[:projects].first
      expect(group[:rows].map { |r| r['slug'] }).to eq %w[newer older]
    end
  end

  describe 'project group order: worst-lane project first' do
    it 'sorts the project groups themselves by their worst row, not by store.list_projects order' do
      quiet_project = store.create_project(slug: 'fl-quiet', name: 'Quiet')
      quiet_row = fake_lane_row(project_id: quiet_project['id'], story_id: 'st-quiet', slug: 'quiet-story',
                                 'updated_at' => (Time.now - 1200).utc.iso8601) # quiet band (>=15m, <30m)
      dead_row  = fake_lane_row(project_id: project['id'], story_id: 'st-dead', slug: 'dead-story',
                                 'liveness' => :dead, 'updated_at' => Time.now.utc.iso8601)
      stub_snapshot([quiet_row, dead_row])

      slugs = TyrionWeb::Data.load_fleet_view[:projects].map { |g| g[:project]['slug'] }
      expect(slugs).to eq %w[fl-proj fl-quiet]
    end
  end

  describe 'idle projects' do
    it 'folds a project with zero in-progress lanes into idle_projects with its last-activity age' do
      stub_snapshot([], project_activity: {
        project['id'] => { 'activity_at' => (Time.now - 86_400).utc.iso8601, 'done' => 0, 'total' => 0 }
      })

      view = TyrionWeb::Data.load_fleet_view
      expect(view[:projects]).to be_empty
      idle = view[:idle_projects].find { |ip| ip[:project]['id'] == project['id'] }
      expect(idle).not_to be_nil
      expect(idle[:last_activity_at]).not_to be_nil
    end

    it 'falls back to projects.updated_at when project_activity has no activity_at' do
      stub_snapshot([], project_activity: { project['id'] => { 'activity_at' => nil, 'done' => 0, 'total' => 0 } })

      idle = TyrionWeb::Data.load_fleet_view[:idle_projects].find { |ip| ip[:project]['id'] == project['id'] }
      expect(idle[:last_activity_at]).to eq Tyrion::Liveness.epoch(project['updated_at'])
    end

    it 'normalizes last_activity_at to an epoch integer so the view never parses a timestamp itself' do
      stub_snapshot([], project_activity: {
        project['id'] => { 'activity_at' => (Time.now - 3600).utc.iso8601, 'done' => 0, 'total' => 0 }
      })

      idle = TyrionWeb::Data.load_fleet_view[:idle_projects].find { |ip| ip[:project]['id'] == project['id'] }
      expect(idle[:last_activity_at]).to be_a(Integer)
    end

    it 'does not list a project with an in-progress lane as idle' do
      story = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.start_story(story['id'], claimed_by: 'lane-1')
      stub_snapshot([fake_lane_row(project_id: project['id'], story_id: story['id'], slug: 's1',
                                    'updated_at' => Time.now.utc.iso8601)])

      idle_slugs = TyrionWeb::Data.load_fleet_view[:idle_projects].map { |ip| ip[:project]['slug'] }
      expect(idle_slugs).not_to include('fl-proj')
    end
  end

  describe 'header counts' do
    it 'counts live_count across only in-progress lanes' do
      live_row    = fake_lane_row(project_id: project['id'], story_id: 'st-1', slug: 'a',
                                   'updated_at' => Time.now.utc.iso8601)
      blocked_row = fake_lane_row(project_id: project['id'], story_id: 'st-2', status: 'blocked',
                                   'blocked_on' => 'x')
      stub_snapshot([live_row, blocked_row])

      expect(TyrionWeb::Data.load_fleet_view[:live_count]).to eq 1
    end

    it 'exposes attention as the same list Tyrion::Liveness.attention_items derives' do
      dead_row = fake_lane_row(project_id: project['id'], story_id: 'st-1', slug: 'a', 'liveness' => :dead)
      stub_snapshot([dead_row])

      expect(TyrionWeb::Data.load_fleet_view[:attention].size).to eq 1
    end
  end

  # fleet-visibility/fleet-board
  describe 'TyrionWeb::Data.fleet_poll_token' do
    def view_with(rows: [], attention: [], idle: [])
      { projects: [{ project: { 'slug' => 'p1' }, rows: rows }], attention: attention, idle_projects: idle }
    end

    def signals(**over)
      { 'note' => nil, 'criterion' => nil, 'gate' => nil, 'commit' => nil, 'edit' => nil, 'process' => 'unknown' }.merge(over)
    end

    def row(**over)
      { 'story_id' => 's1', 'status' => 'in_progress', 'claimed_by' => 'lane-1', 'met' => 1, 'total' => 2,
        'display_state' => 'live', 'resolution_state' => 'resolved',
        'commit_sha' => 'abc', 'dirty_count' => 0, 'newest_dirty_mtime' => nil,
        'signals' => signals }.merge(over)
    end

    it 'is stable for the same view' do
      v = view_with(rows: [row])
      expect(TyrionWeb::Data.fleet_poll_token(v)).to eq TyrionWeb::Data.fleet_poll_token(v)
    end

    it 'changes when a row liveness state changes' do
      a = TyrionWeb::Data.fleet_poll_token(view_with(rows: [row]))
      b = TyrionWeb::Data.fleet_poll_token(view_with(rows: [row('display_state' => 'dead')]))
      expect(a).not_to eq b
    end

    it 'changes when met/total changes' do
      a = TyrionWeb::Data.fleet_poll_token(view_with(rows: [row]))
      b = TyrionWeb::Data.fleet_poll_token(view_with(rows: [row('met' => 2)]))
      expect(a).not_to eq b
    end

    it 'changes when a per-source signal timestamp changes' do
      a = TyrionWeb::Data.fleet_poll_token(view_with(rows: [row]))
      b = TyrionWeb::Data.fleet_poll_token(view_with(rows: [row('signals' => signals('edit' => 12_345))]))
      expect(a).not_to eq b
    end

    it 'changes when the newest commit sha, dirty count, or newest dirty mtime changes' do
      base = TyrionWeb::Data.fleet_poll_token(view_with(rows: [row]))
      expect(base).not_to eq TyrionWeb::Data.fleet_poll_token(view_with(rows: [row('commit_sha' => 'def')]))
      expect(base).not_to eq TyrionWeb::Data.fleet_poll_token(view_with(rows: [row('dirty_count' => 3)]))
      expect(base).not_to eq TyrionWeb::Data.fleet_poll_token(view_with(rows: [row('newest_dirty_mtime' => 999)]))
    end

    it 'changes when an attention item is added or its kind changes' do
      base = TyrionWeb::Data.fleet_poll_token(view_with(rows: [row]))
      with_attention = TyrionWeb::Data.fleet_poll_token(
        view_with(rows: [row], attention: [{ 'story_id' => 's1', 'kind' => 'dead' }])
      )
      expect(base).not_to eq with_attention
    end

    it 'changes when an idle project last-activity value changes' do
      a = TyrionWeb::Data.fleet_poll_token(view_with(idle: [{ project: { 'slug' => 'p2' }, last_activity_at: 'a' }]))
      b = TyrionWeb::Data.fleet_poll_token(view_with(idle: [{ project: { 'slug' => 'p2' }, last_activity_at: 'b' }]))
      expect(a).not_to eq b
    end

    it 'does not change merely because wall-clock time has passed' do
      v = view_with(rows: [row])
      first = TyrionWeb::Data.fleet_poll_token(v)
      sleep 0.01
      expect(TyrionWeb::Data.fleet_poll_token(v)).to eq first
    end
  end
end

# fleet-visibility/fleet-board
RSpec.describe 'TyrionWeb::Presenter.attention_weight' do
  it 'matches Tyrion::Liveness::SEVERITY for attention-qualifying states' do
    Tyrion::Liveness::SEVERITY.each do |state, weight|
      expect(TyrionWeb::Presenter.attention_weight(state)).to eq weight
    end
  end

  it 'ranks a non-attention state (live/working/quiet) after every real attention state' do
    worst_real = Tyrion::Liveness::SEVERITY.values.max
    expect(TyrionWeb::Presenter.attention_weight('live')).to be > worst_real
    expect(TyrionWeb::Presenter.attention_weight('working')).to be > worst_real
    expect(TyrionWeb::Presenter.attention_weight('quiet')).to be > worst_real
  end
end

# fleet-visibility/fleet-board: LaneRow is the shared component the fleet
# board and (phase 2) the cockpit's Now tab both render.
RSpec.describe 'Views::Components::LaneRow' do
  def row(**over)
    {
      'story_id' => 'abc-123', 'slug' => 'my-story', 'lane' => 'v0-A',
      'display_state' => 'live', 'met' => 2, 'total' => 4,
      'newest_at' => Time.now.to_i, 'evidence' => 'full', 'resolution_state' => 'resolved',
      'signals' => { 'edit' => Time.now.to_i, 'commit' => nil, 'note' => nil, 'gate' => nil, 'process' => 'unknown' }
    }.merge(over.transform_keys(&:to_s))
  end

  def render(r) = Views::Components::LaneRow.new(row: r).call

  it 'renders the glyph, lane label, story link, and met/total' do
    html = render(row)
    expect(html).to include('lv-live')
    expect(html).to include('v0-A')
    expect(html).to include('href="/stories/abc-123"')
    expect(html).to include('my-story')
    expect(html).to include('2/4')
  end

  it 'renders a data-at epoch for each signal so ages tick client-side' do
    html = render(row)
    expect(html).to include('data-at=')
    expect(html).to include('data-label="edit"')
  end

  # Regression guard for a real bug: the client-side age ticker does
  # `el.textContent = ...` on every [data-at] element, which destroys any
  # children that element has. data-at must only ever sit on a leaf node
  # (glyph/label/story/progress are all siblings, never inside one) -- the
  # container div is exactly the kind of element this must never touch.
  it 'never puts data-at on the row container, which has children' do
    html = render(row)
    expect(html).to match(%r{\A<div class="lane-row">})
  end

  it 'shows the ledger-only evidence marker only when evidence is not full' do
    expect(render(row(evidence: 'full'))).not_to include('lane-evidence')
    expect(render(row(evidence: Tyrion::Liveness::EVIDENCE_LEDGER))).to include('lane-evidence')
  end

  it 'shows a resolution label only for a failing resolution state' do
    expect(render(row(resolution_state: 'resolved'))).not_to include('lane-resolution')
    expect(render(row(resolution_state: 'missing'))).to include('lane-resolution')
    expect(render(row(resolution_state: 'missing'))).to include(TyrionWeb::Presenter.resolution_label('missing'))
  end

  it 'omits the progress chip when the row carries no criteria at all' do
    expect(render(row(total: nil))).not_to include('lane-progress')
  end
end

# fleet-visibility/fleet-board: the full page render. Exists specifically
# because a client-side-only bug (data-at on a container) shipped past a
# Data-layer-only spec suite once already -- see LaneRow's regression guard.
RSpec.describe 'Views::Fleet' do
  def lane_row(slug: 'my-story', story_id: 'st-1')
    {
      'story_id' => story_id, 'slug' => slug, 'lane' => 'v0-A', 'display_state' => 'live',
      'met' => 1, 'total' => 2, 'newest_at' => Time.now.to_i, 'evidence' => 'full',
      'resolution_state' => 'resolved',
      'signals' => { 'edit' => Time.now.to_i, 'commit' => nil, 'note' => nil, 'gate' => nil, 'process' => 'unknown' }
    }
  end

  def fleet_view(projects: [], idle_projects: [], attention: [], live_count: 0, stale: false, partial: false)
    { projects: projects, idle_projects: idle_projects, attention: attention, live_count: live_count,
      generation: 1, built_at: Time.now.to_i, stale: stale, partial: partial }
  end

  def render(fleet)
    Views::Fleet.new(fleet: fleet, project: nil, epic: nil, stories: [],
                      disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }, token: 'tok').call
  end

  it 'renders the header counts and a ticking snapshot age' do
    html = render(fleet_view(live_count: 3, attention: [{ 'story_id' => 's1', 'kind' => 'dead' }]))
    expect(html).to include('3 live')
    expect(html).to include('1 need you')
    expect(html).to match(/id="fl-snapshot-age" data-at="\d+"/)
  end

  it 'flags a stale or partial snapshot in the header rather than reading confidently' do
    expect(render(fleet_view(stale: true))).to include('· stale')
    expect(render(fleet_view(partial: true))).to include('· partial')
    expect(render(fleet_view)).not_to include('· stale')
  end

  it 'renders the needs-you band above the project groups, each item linking to its cockpit' do
    item = { 'project_slug' => 'p1', 'epic_slug' => 'e1', 'slug' => 'my-story', 'reason' => 'process gone', 'at' => Time.now.to_i }
    html = render(fleet_view(projects: [{ project: { 'slug' => 'p1', 'name' => 'P1' }, rows: [lane_row] }],
                              attention: [item]))
    expect(html.index('fl-needs-you')).to be < html.index('fl-project-group')
    expect(html).to include('/cockpit?project=p1&epic=e1')
  end

  it 'omits the needs-you band entirely when there is nothing to flag' do
    expect(render(fleet_view)).not_to include('fl-needs-you')
  end

  it 'renders each project group with a cockpit-linked header and its LaneRow rows' do
    html = render(fleet_view(projects: [{ project: { 'slug' => 'p1', 'name' => 'Project One' }, rows: [lane_row] }]))
    expect(html).to include('/cockpit?project=p1')
    expect(html).to include('Project One')
    expect(html).to include('lane-row')
  end

  it 'folds idle projects into one footer line' do
    html = render(fleet_view(idle_projects: [{ project: { 'slug' => 'idle-1' }, last_activity_at: Time.now.to_i }]))
    expect(html).to include('fl-idle-footer')
    expect(html).to include('idle-1')
  end

  it 'seeds the poll badge with the page token and never gives a container a data-at' do
    html = render(fleet_view(projects: [{ project: { 'slug' => 'p1', 'name' => 'P1' }, rows: [lane_row] }]))
    expect(html).to include('data-token="tok"')
    # The row container, the project group, and the outer shell must never
    # carry data-at -- only leaf age spans may (LaneRow's own regression
    # guard covers the row itself; this covers the page-level containers).
    expect(html).not_to match(/class="fl-project-group" data-at=/)
    expect(html).not_to match(/class="lane-row" data-at=/)
  end
end
