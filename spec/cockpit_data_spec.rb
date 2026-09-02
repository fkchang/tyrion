# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
require_relative '../web/lib/tyrion_web/data'
require_relative '../web/lib/tyrion_web/presenter'
Dir.glob(File.expand_path('../web/views/**/*.rb', __dir__)).sort.each { |f| require f }

# fleet-visibility/cockpit-now-tab: GET /cockpit?project=&epic=&tab= scopes
# the fleet's liveness data down to one epic -- Needs you, Lanes (the shared
# LaneRow), and a Progress segmented bar -- with the active tab living in the
# URL and defaulting to 'now'.
RSpec.describe 'TyrionWeb::Data.load_cockpit_view' do
  let(:ctx)     { tyrion_worktree(project_slug: 'ck-proj', project_name: 'CK Test', epic_slug: 'e1') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { ctx.epic }

  before do
    allow(TyrionWeb::Data).to receive(:store).and_return(store)
    Tyrion::Liveness::Snapshot.reset!
    TyrionWeb::Data.reset_dead_lane_observations!
  end
  after do
    Tyrion::Liveness::Snapshot.reset!
    TyrionWeb::Data.reset_dead_lane_observations!
  end

  def fake_lane_row(story_id: 'st-1', slug: story_id, status: 'in_progress',
                     project_slug: 'ck-proj', epic_slug: 'e1', now: Time.now, **over)
    lane = {
      'story_id' => story_id, 'slug' => slug, 'status' => status,
      'claimed_by' => 'lane-x', 'epic_slug' => epic_slug, 'project_slug' => project_slug, 'project_id' => project['id'],
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

  describe 'scoping' do
    it 'scopes rows and attention to the requested project + epic only' do
      in_scope   = fake_lane_row(story_id: 'st-in', slug: 'in-scope', 'updated_at' => Time.now.utc.iso8601)
      other_epic = fake_lane_row(story_id: 'st-oe', slug: 'other-epic', epic_slug: 'e2', 'updated_at' => Time.now.utc.iso8601)
      other_proj = fake_lane_row(story_id: 'st-op', slug: 'other-proj-row', project_slug: 'other-proj', 'updated_at' => Time.now.utc.iso8601)
      stub_snapshot([in_scope, other_epic, other_proj])

      view = TyrionWeb::Data.load_cockpit_view(project_slug: 'ck-proj', epic_slug: 'e1')

      expect(view[:rows].map { |r| r['slug'] }).to eq ['in-scope']
    end

    it 'scopes attention items to the epic too' do
      dead_here  = fake_lane_row(story_id: 'st-dead-here', 'liveness' => :dead)
      dead_there = fake_lane_row(story_id: 'st-dead-there', epic_slug: 'e2', 'liveness' => :dead)
      stub_snapshot([dead_here, dead_there])

      view = TyrionWeb::Data.load_cockpit_view(project_slug: 'ck-proj', epic_slug: 'e1')
      expect(view[:attention].map { |a| a['story_id'] }).to eq ['st-dead-here']
    end

    it 'excludes blocked rows from the row list but keeps them in attention' do
      blocked_row = fake_lane_row(story_id: 'st-blk', status: 'blocked', 'blocked_on' => 'waiting')
      stub_snapshot([blocked_row])

      view = TyrionWeb::Data.load_cockpit_view(project_slug: 'ck-proj', epic_slug: 'e1')
      expect(view[:rows]).to be_empty
      expect(view[:attention].map { |a| a['story_id'] }).to include('st-blk')
    end
  end

  describe 'unknown project or epic' do
    it 'returns a nil epic for an unknown epic slug' do
      view = TyrionWeb::Data.load_cockpit_view(project_slug: 'ck-proj', epic_slug: 'nope')
      expect(view[:project]).not_to be_nil
      expect(view[:epic]).to be_nil
    end

    it 'returns a nil project for an unknown project slug' do
      view = TyrionWeb::Data.load_cockpit_view(project_slug: 'nope', epic_slug: 'e1')
      expect(view[:project]).to be_nil
      expect(view[:epic]).to be_nil
    end
  end

  describe 'tab normalization' do
    it 'defaults to now when tab is absent' do
      expect(TyrionWeb::Data.load_cockpit_view(project_slug: 'ck-proj', epic_slug: 'e1')[:tab]).to eq 'now'
    end

    it 'defaults to now for an unrecognized tab value' do
      view = TyrionWeb::Data.load_cockpit_view(project_slug: 'ck-proj', epic_slug: 'e1', tab: 'bogus')
      expect(view[:tab]).to eq 'now'
    end

    %w[now changes trail].each do |t|
      it "honors an explicit ?tab=#{t}" do
        view = TyrionWeb::Data.load_cockpit_view(project_slug: 'ck-proj', epic_slug: 'e1', tab: t)
        expect(view[:tab]).to eq t
      end
    end
  end

  describe 'story_counts' do
    it 'counts stories in the epic by status' do
      s1 = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.start_story(s1['id'], claimed_by: 'lane-1')
      s2 = store.create_story(epic_id: epic['id'], slug: 's2', title: 'S2')
      store.complete_story(s2['id'], 'done', force: true)
      store.create_story(epic_id: epic['id'], slug: 's3', title: 'S3')

      view = TyrionWeb::Data.load_cockpit_view(project_slug: 'ck-proj', epic_slug: 'e1')
      expect(view[:story_counts]).to include(done: 1, in_progress: 1, pending: 1, total: 3)
    end
  end

  # fleet-visibility/cockpit-changes-trail-tabs prep: the in-memory-only
  # lane_dead observation that load_cockpit_view feeds into its Changes
  # events. Unit-tested directly here (not just through load_cockpit_view)
  # since it is genuinely new state, not a pass-through of the snapshot.
  describe 'observe_dead_lanes / dead_lane_events_for' do
    def state_row(story_id:, state:, slug: story_id, project_slug: 'p1', epic_slug: 'e1')
      { 'story_id' => story_id, 'slug' => slug, 'state' => state, 'project_slug' => project_slug, 'epic_slug' => epic_slug }
    end

    it 'records a lane_dead event only on the transition from not-dead to dead' do
      TyrionWeb::Data.observe_dead_lanes([state_row(story_id: 's1', state: 'live')])
      expect(TyrionWeb::Data.dead_lane_events_for('p1', 'e1')).to be_empty

      TyrionWeb::Data.observe_dead_lanes([state_row(story_id: 's1', state: 'dead')])
      events = TyrionWeb::Data.dead_lane_events_for('p1', 'e1')
      expect(events.size).to eq 1
      expect(events.first).to include(kind: 'lane_dead', story_id: 's1', story_slug: 's1')
    end

    it 'does not re-record while the lane stays dead' do
      TyrionWeb::Data.observe_dead_lanes([state_row(story_id: 's1', state: 'dead')])
      TyrionWeb::Data.observe_dead_lanes([state_row(story_id: 's1', state: 'dead')])
      expect(TyrionWeb::Data.dead_lane_events_for('p1', 'e1').size).to eq 1
    end

    it 'records again if the lane recovers and dies a second time' do
      TyrionWeb::Data.observe_dead_lanes([state_row(story_id: 's1', state: 'dead')])
      TyrionWeb::Data.observe_dead_lanes([state_row(story_id: 's1', state: 'live')])
      TyrionWeb::Data.observe_dead_lanes([state_row(story_id: 's1', state: 'dead')])
      expect(TyrionWeb::Data.dead_lane_events_for('p1', 'e1').size).to eq 2
    end

    it 'scopes events to the project + epic they belong to' do
      TyrionWeb::Data.observe_dead_lanes([state_row(story_id: 's1', state: 'dead', project_slug: 'p1', epic_slug: 'e1')])
      TyrionWeb::Data.observe_dead_lanes([state_row(story_id: 's2', state: 'dead', project_slug: 'p2', epic_slug: 'e1')])

      expect(TyrionWeb::Data.dead_lane_events_for('p1', 'e1').map { |e| e[:story_id] }).to eq ['s1']
      expect(TyrionWeb::Data.dead_lane_events_for('p2', 'e1').map { |e| e[:story_id] }).to eq ['s2']
    end

    it 'is forgotten after reset_dead_lane_observations!' do
      TyrionWeb::Data.observe_dead_lanes([state_row(story_id: 's1', state: 'dead')])
      TyrionWeb::Data.reset_dead_lane_observations!
      expect(TyrionWeb::Data.dead_lane_events_for('p1', 'e1')).to be_empty
    end
  end

  # fleet-visibility/cockpit-now-tab
  describe 'TyrionWeb::Data.cockpit_poll_token' do
    def signals(**over)
      { 'note' => nil, 'criterion' => nil, 'gate' => nil, 'commit' => nil, 'edit' => nil, 'process' => 'unknown' }.merge(over)
    end

    def row(**over)
      { 'story_id' => 's1', 'status' => 'in_progress', 'claimed_by' => 'lane-1', 'met' => 1, 'total' => 2,
        'display_state' => 'live', 'resolution_state' => 'resolved',
        'commit_sha' => 'abc', 'dirty_count' => 0, 'newest_dirty_mtime' => nil,
        'signals' => signals }.merge(over)
    end

    def view_with(rows: [], attention: [], events: [], story_counts: { done: 0, in_progress: 0, blocked: 0, pending: 0, total: 0 })
      { rows: rows, attention: attention, events: events, story_counts: story_counts }
    end

    it 'is stable for the same view' do
      v = view_with(rows: [row])
      expect(TyrionWeb::Data.cockpit_poll_token(v)).to eq TyrionWeb::Data.cockpit_poll_token(v)
    end

    it 'changes when a row liveness state changes' do
      a = TyrionWeb::Data.cockpit_poll_token(view_with(rows: [row]))
      b = TyrionWeb::Data.cockpit_poll_token(view_with(rows: [row('display_state' => 'dead')]))
      expect(a).not_to eq b
    end

    it 'changes when an attention item is added' do
      base = TyrionWeb::Data.cockpit_poll_token(view_with(rows: [row]))
      with_attn = TyrionWeb::Data.cockpit_poll_token(view_with(rows: [row], attention: [{ 'story_id' => 's1', 'kind' => 'dead' }]))
      expect(base).not_to eq with_attn
    end

    it 'changes when the newest Changes event changes' do
      a = TyrionWeb::Data.cockpit_poll_token(view_with(events: [{ kind: 'note', at: 100, story_id: 's1' }]))
      b = TyrionWeb::Data.cockpit_poll_token(view_with(events: [{ kind: 'note', at: 200, story_id: 's1' }]))
      expect(a).not_to eq b
    end

    it 'changes when the epic status counts change' do
      a = TyrionWeb::Data.cockpit_poll_token(view_with(story_counts: { done: 1, in_progress: 0, blocked: 0, pending: 1, total: 2 }))
      b = TyrionWeb::Data.cockpit_poll_token(view_with(story_counts: { done: 2, in_progress: 0, blocked: 0, pending: 0, total: 2 }))
      expect(a).not_to eq b
    end

    it 'does not change merely because wall-clock time has passed' do
      v = view_with(rows: [row])
      first = TyrionWeb::Data.cockpit_poll_token(v)
      sleep 0.01
      expect(TyrionWeb::Data.cockpit_poll_token(v)).to eq first
    end
  end
end

# fleet-visibility/cockpit-now-tab: the page itself.
RSpec.describe 'Views::Cockpit' do
  def lane_row(slug: 'my-story', story_id: 'st-1')
    {
      'story_id' => story_id, 'slug' => slug, 'lane' => 'v0-A', 'display_state' => 'live',
      'met' => 1, 'total' => 2, 'newest_at' => Time.now.to_i, 'evidence' => 'full',
      'resolution_state' => 'resolved',
      'signals' => { 'edit' => Time.now.to_i, 'commit' => nil, 'note' => nil, 'gate' => nil, 'process' => 'unknown' }
    }
  end

  def attention_item(story_id:, slug:, kind: 'dead', reason: 'process gone', at: Time.now.to_i)
    { 'story_id' => story_id, 'slug' => slug, 'kind' => kind, 'reason' => reason, 'at' => at, 'severity' => 1 }
  end

  def project = { 'slug' => 'ck-proj', 'name' => 'CK Test' }
  def epic    = { 'slug' => 'e1', 'name' => 'Epic One' }

  def render(tab: 'now', rows: [], attention: [], story_counts: { done: 0, in_progress: 0, blocked: 0, pending: 0, total: 0 },
             events: [], trail_notes: [])
    Views::Cockpit.new(
      project: project, epic: epic, tab: tab, rows: rows, attention: attention, story_counts: story_counts,
      events: events, trail_notes: trail_notes, stories: [],
      disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }, project_slug: 'ck-proj', token: 'tok',
      built_at: Time.now.to_i, stale: false, partial: false
    ).call
  end

  it 'defaults to the now tab and renders lanes via the shared LaneRow' do
    html = render(rows: [lane_row])
    expect(html).to include('lane-row')
    expect(html).to include('my-story')
  end

  def active_tab_of(html) = html[/class="ck-tab active"[^>]*>([^<]+)</, 1]

  it 'renders the active tab from the tab param, one of now/changes/trail' do
    expect(active_tab_of(render(tab: 'changes'))).to eq 'Changes'
    expect(active_tab_of(render(tab: 'trail'))).to eq 'Trail'
  end

  # Tab normalization itself (absent/unrecognized -> 'now') is
  # TyrionWeb::Data.load_cockpit_view's job, covered in the Data spec above --
  # every real caller reaches this view only through that normalization, so
  # the view itself simply renders whatever valid tab it's handed.

  it 'renders the epic switcher in scoped mode (an interactive select, not a static crumb)' do
    html = render
    expect(html).to include('data-action="epic-switch"')
  end

  it 'renders the progress band as a segmented bar reflecting story_counts' do
    html = render(story_counts: { done: 2, in_progress: 1, blocked: 0, pending: 1, total: 4 })
    expect(html).to include('ck-seg-done')
    expect(html).to include('ck-seg-active')
    expect(html).to include('ck-seg-pending')
    expect(html).to include('2 done')
  end

  it 'renders no progress segments when the epic has no stories' do
    html = render(story_counts: { done: 0, in_progress: 0, blocked: 0, pending: 0, total: 0 })
    expect(html).not_to include('ck-seg-done')
  end

  describe 'Needs you band (disc-164 addendum: liveness ranks above blocked, blocked collapses past 5)' do
    it 'omits the band entirely when there is nothing to flag' do
      expect(render).not_to include('fl-needs-you')
    end

    it 'renders every liveness attention item directly, never collapsed' do
      items = (1..7).map { |i| attention_item(story_id: "st-#{i}", slug: "s#{i}", kind: 'dead') }
      html = render(attention: items)
      expect(html).not_to include('more blocked')
      (1..7).each { |i| expect(html).to include("s#{i}") }
    end

    it 'shows the first 5 blocked items directly and collapses the rest behind a details toggle' do
      blocked = (1..7).map { |i| attention_item(story_id: "st-b#{i}", slug: "blocked-#{i}", kind: 'blocked', reason: 'blocked: x') }
      html = render(attention: blocked)

      expect(html).to include('<details')
      expect(html).to include('+2 more blocked')
      (1..5).each { |i| expect(html).to include("blocked-#{i}") }
    end

    it 'ranks liveness items above blocked items regardless of input order' do
      blocked = attention_item(story_id: 'st-blk', slug: 'blocked-1', kind: 'blocked')
      dead    = attention_item(story_id: 'st-dead', slug: 'dead-1', kind: 'dead')
      html = render(attention: [blocked, dead])

      expect(html.index('dead-1')).to be < html.index('blocked-1')
    end
  end

  it 'never puts data-at on a container -- only leaf signal/age spans carry it' do
    html = render(rows: [lane_row], attention: [attention_item(story_id: 'st-1', slug: 'my-story')])
    expect(html).not_to match(/class="lane-row" data-at=/)
    expect(html).not_to match(/class="fl-need-row"[^>]*data-at=/)
  end

  it 'seeds the poll badge with the page token' do
    expect(render).to include('data-token="tok"')
  end
end
