# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion attention' do
  let(:ctx)   { tyrion_worktree(project_slug: 'alpha', project_name: 'Alpha', epic_slug: 'stalled-epic', epic_name: 'Stalled Epic') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  # Liveness::Snapshot is a process-wide cache keyed on nothing but a TTL, so
  # a snapshot built by an earlier spec file's temp DB could otherwise leak
  # in here (same reset convention as spec/global_view_data_spec.rb).
  before { Tyrion::Liveness::Snapshot.reset! }
  after  { Tyrion::Liveness::Snapshot.reset! }

  # Backdates every story in the epic so the epic's own last-activity reads
  # as `days_ago` old, regardless of which timestamp column is the newest --
  # `updated_at` is always present, `completed_at` only for a done story.
  def backdate_epic(epic_id, days_ago)
    t = (Time.now.utc - (days_ago * 86_400)).iso8601(6)
    store.send(:with_db) do |db|
      db.execute(
        'UPDATE stories SET updated_at = ?, completed_at = CASE WHEN completed_at IS NOT NULL THEN ? ELSE completed_at END WHERE epic_id = ?',
        [t, t, epic_id]
      )
    end
  end

  def json_report(argv)
    out, = capture_io { Tyrion::Commands.cmd_attention(argv, store) }
    JSON.parse(out)
  end

  describe 'a stalled epic' do
    before do
      s1 = store.create_story(epic_id: epic['id'], slug: 's1', title: 'Story One')
      s2 = store.create_story(epic_id: epic['id'], slug: 's2', title: 'Story Two')
      store.update_next_action(s2['id'], 'pick this up')
      store.complete_story(s1['id'], 'done')
      backdate_epic(epic['id'], 10)
      @s2 = s2
    end

    it 'renders in the human table under STALLED, with counts and idle days' do
      out, = capture_io { Tyrion::Commands.cmd_attention([], store) }
      expect(out).to match(/STALLED/)
      expect(out).to match(%r{alpha / stalled-epic})
      expect(out).to match(%r{1/2 done})
      expect(out).to match(/idle 10 days/)
    end

    it 'emits the documented --json contract shape' do
      report = json_report(['--json'])
      expect(report.keys).to contain_exactly('generated_at', 'stale_days', 'summary', 'epics')

      row = report['epics'].find { |e| e['epic_slug'] == 'stalled-epic' }
      expect(row).to include(
        'project_slug' => 'alpha', 'epic_name' => 'Stalled Epic', 'mode' => 'shape',
        'status' => 'active', 'category' => 'stalled', 'idle_days' => 10
      )
      expect(row['counts']).to eq('done' => 1, 'pending' => 1, 'in_progress' => 0, 'blocked' => 0, 'total' => 2)
      expect(row['current_story']).to eq('slug' => 's2', 'title' => 'Story Two', 'next_action' => 'pick this up')
      expect(row['lanes']).to eq []
      expect(row['suggested_commands']).not_to be_empty
    end

    it 'honors --stale-days to tighten or loosen the threshold' do
      expect(json_report(['--json', '--stale-days', '30'])['summary']).to eq(
        'stalled' => 0, 'waiting' => 0, 'fine' => 1
      )
      expect(json_report(['--json', '--stale-days', '2'])['summary']).to eq(
        'stalled' => 1, 'waiting' => 0, 'fine' => 0
      )
    end
  end

  describe 'a waiting epic' do
    it 'lists a paused epic under waiting, even with no story activity at all' do
      store.create_story(epic_id: epic['id'], slug: 's1', title: 'Story One')
      store.update_epic(epic['id'], 'status' => 'paused')

      row = json_report(['--json'])['epics'].find { |e| e['epic_slug'] == 'stalled-epic' }
      expect(row['category']).to eq 'waiting'
      expect(row['waiting_reasons']).to eq ['paused']
    end

    it 'lists a blocked story under waiting with its reason and linked discovery' do
      s1 = store.create_story(epic_id: epic['id'], slug: 's1', title: 'Story One')
      s2 = store.create_story(epic_id: epic['id'], slug: 's2', title: 'Story Two')
      store.complete_story(s1['id'], 'done')
      disc = store.create_discovery(project_id: ctx.project['id'], epic_id: epic['id'], status: 'mark', question: 'q')
      store.block_story(s2['id'], blocked_on: 'waiting on vendor API', blocked_on_discovery: disc['id'])

      row = json_report(['--json'])['epics'].find { |e| e['epic_slug'] == 'stalled-epic' }
      expect(row['category']).to eq 'waiting'
      expect(row['waiting_reasons']).to eq ["s2: waiting on vendor API [#{disc['id']}]"]
    end
  end

  describe '--project scoping' do
    it 'narrows the report to the named project only' do
      store.create_project(slug: 'beta', name: 'Beta')
      store.update_epic(epic['id'], 'status' => 'paused')

      report = json_report(['--json', '--project', 'alpha'])
      expect(report['epics'].map { |e| e['project_slug'] }.uniq).to eq ['alpha']
    end

    it 'dies with a clear message for an unknown project slug' do
      expect { Tyrion::Commands.cmd_attention(['--project', 'nope'], store) }
        .to raise_error(SystemExit).and output(/Project not found: nope/).to_stderr
    end
  end

  it 'works with no active project set at all -- this command is cross-cwd by design' do
    stub_repo(active_project: nil)
    expect { capture_io { Tyrion::Commands.cmd_attention([], store) } }.not_to raise_error
  end

  it 'prints nothing-to-see-here when no epic needs attention' do
    store.create_story(epic_id: epic['id'], slug: 's1', title: 'Story One')

    out, = capture_io { Tyrion::Commands.cmd_attention([], store) }
    expect(out).to match(/Nothing needs attention/)
  end
end
