# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
Dir.glob(File.expand_path('../../web/lib/tyrion_web/*.rb', __dir__)).sort.each { |f| require f }
Dir.glob(File.expand_path('../../web/views/*.rb', __dir__)).sort.each { |f| require f }

RSpec.describe 'discovery origin (agent vs human)' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'discovery-autonomy') }
  let(:store) { ctx.store }

  # ── criteria 1-3: schema ────────────────────────────────────────────────

  describe 'the origin column' do
    it 'exists on discoveries with NOT NULL and DEFAULT human' do
      col = store.send(:with_db) { |db| db.execute('PRAGMA table_info(discoveries)') }
             .find { |c| c['name'] == 'origin' }

      expect(col).not_to be_nil
      expect(col['notnull']).to eq 1
      expect(col['dflt_value'].to_s.delete("'")).to eq 'human'
    end

    it 'constrains values to agent or human' do
      ddl = store.send(:with_db) do |db|
        db.get_first_value("SELECT sql FROM sqlite_master WHERE type='table' AND name='discoveries'")
      end
      expect(ddl).to match(/origin[^,]*CHECK\s*\(\s*origin\s+IN\s*\(\s*'agent'\s*,\s*'human'\s*\)\s*\)/i)
    end

    it 'rejects an origin outside the allowed set' do
      expect do
        store.create_discovery(project_id: ctx.project['id'], status: 'mark',
                               question: 'bad', origin: 'robot')
      end.to raise_error(SQLite3::ConstraintException)
    end

    it 'backfills rows created before the column existed to human via the default' do
      # Simulate a pre-migration row by inserting without naming the origin column.
      store.send(:with_db) do |db|
        db.execute(
          "INSERT INTO discoveries (id, project_id, status, question, created_at, updated_at) " \
          "VALUES ('disc-900', ?, 'mark', 'legacy row', '2020-01-01T00:00:00Z', '2020-01-01T00:00:00Z')",
          [ctx.project['id']]
        )
      end

      expect(store.find_discovery('disc-900')['origin']).to eq 'human'
    end

    it 'defaults create_discovery to human when no origin is given' do
      disc = store.create_discovery(project_id: ctx.project['id'], status: 'mark', question: 'q')
      expect(disc['origin']).to eq 'human'
    end
  end

  # ── criteria 4-6: --auto on mark and discover ───────────────────────────

  describe 'tyrion mark' do
    def mark(args)
      out, = capture_io { Tyrion::Commands.cmd_mark(args, store) }
      store.find_discovery(out[/\[mark\] (disc-\d+)/, 1])
    end

    it 'records origin=agent when --auto is passed' do
      expect(mark(['found a gap', '--auto'])['origin']).to eq 'agent'
    end

    it 'records origin=human when --auto is omitted' do
      expect(mark(['found a gap'])['origin']).to eq 'human'
    end

    it 'does not swallow --auto into the question text' do
      expect(mark(['found a gap', '--auto'])['question']).to eq 'found a gap'
    end

    it 'accepts --auto before the description' do
      disc = mark(['--auto', 'found a gap'])
      expect(disc['origin']).to eq 'agent'
      expect(disc['question']).to eq 'found a gap'
    end
  end

  describe 'tyrion discover' do
    def discover(args)
      output = StringIO.new
      Tyrion::Commands.cmd_discover(args, store,
                                    input: StringIO.new("what\nfound\nno\n"), output: output)
      store.find_discovery(output.string[/\[findings_ready\] (disc-\d+)/, 1])
    end

    it 'records origin=agent when --auto is passed' do
      expect(discover(['--auto'])['origin']).to eq 'agent'
    end

    it 'records origin=human when --auto is omitted' do
      expect(discover([])['origin']).to eq 'human'
    end
  end

  # ── criterion 7: --auto on spike start / done ───────────────────────────

  describe 'tyrion spike start' do
    def spike_start(args)
      output = StringIO.new
      Tyrion::Commands.cmd_spike_start(args, store, input: StringIO.new("\n\n"), output: output)
      store.find_discovery(output.string[/\[active_spike\] (disc-\d+)/, 1])
    end

    it 'records origin=agent when --auto is passed' do
      disc = spike_start(['why is this slow?', '--auto'])
      expect(disc['origin']).to eq 'agent'
      expect(disc['question']).to eq 'why is this slow?'
    end

    it 'records origin=human when --auto is omitted' do
      expect(spike_start(['why is this slow?'])['origin']).to eq 'human'
    end

    it 'does not treat --auto as the question when it comes first' do
      disc = spike_start(['--auto', 'why is this slow?'])
      expect(disc['question']).to eq 'why is this slow?'
      expect(disc['origin']).to eq 'agent'
    end
  end

  describe 'tyrion spike done' do
    def spike_done(args)
      output = StringIO.new
      Tyrion::Commands.cmd_spike_done(args, store,
                                      input: StringIO.new("finding\nhigh\nrec\n"), output: output)
      store.find_discovery(output.string[/\[findings_ready\] (disc-\d+)/, 1])
    end

    before do
      store.create_discovery(project_id: ctx.project['id'], status: 'active_spike',
                             question: 'q', origin: 'human')
    end

    it 'records origin=agent on the updated discovery when --auto is passed' do
      expect(spike_done(['--auto'])['origin']).to eq 'agent'
    end

    it 'records origin=human when --auto is omitted' do
      expect(spike_done([])['origin']).to eq 'human'
    end

    it 'changes nothing else about the close' do
      disc = spike_done(['--auto'])
      expect(disc['status']).to eq 'findings_ready'
      expect(disc['finding']).to eq 'finding'
      expect(disc['confidence']).to eq 'high'
      expect(disc['recommendation']).to eq 'rec'
    end
  end

  # ── criteria 8-10: rendering markers ────────────────────────────────────

  describe 'Tyrion::Output.origin_tag' do
    it 'returns the agent tag for agent' do
      expect(Tyrion::Output.origin_tag('agent')).to include('[agent]')
    end

    it 'returns the human tag for human' do
      expect(Tyrion::Output.origin_tag('human')).to include('[human]')
    end

    it 'treats a missing origin as human' do
      expect(Tyrion::Output.origin_tag(nil)).to include('[human]')
    end
  end

  describe 'tyrion discovery list' do
    before do
      store.create_discovery(project_id: ctx.project['id'], status: 'mark',
                             question: 'agent-filed thing', origin: 'agent')
      store.create_discovery(project_id: ctx.project['id'], status: 'mark',
                             question: 'human-filed thing', origin: 'human')
    end

    it 'tags each discovery with its origin' do
      out, = capture_io { Tyrion::Commands.cmd_discovery_list([], store) }

      expect(out[/.*agent-filed thing.*/]).to include('[agent]')
      expect(out[/.*human-filed thing.*/]).to include('[human]')
    end
  end

  describe 'tyrion status' do
    before do
      store.create_discovery(project_id: ctx.project['id'], status: 'active_spike',
                             question: 'agent spike', origin: 'agent')
      store.create_discovery(project_id: ctx.project['id'], status: 'findings_ready',
                             question: 'human finding', origin: 'human')
    end

    it 'tags rendered discoveries with their origin' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }

      expect(out[/.*agent spike.*/]).to include('[agent]')
      expect(out[/.*human finding.*/]).to include('[human]')
    end

    it 'breaks the unformalized mark count down by origin' do
      store.create_discovery(project_id: ctx.project['id'], status: 'mark',
                             question: 'm1', origin: 'agent')
      store.create_discovery(project_id: ctx.project['id'], status: 'mark',
                             question: 'm2', origin: 'human')

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }

      expect(out).to match(/2 unformalized mark\(s\).*1 \[agent\].*1 \[human\]/)
    end
  end

  describe 'the web Discoveries view' do
    def render(spike: nil, findings_ready: [], marks: [])
      Views::DiscoveriesView.new(
        project: { 'name' => 'P', 'slug' => 'p' }, spike: spike,
        findings_ready: findings_ready, marks: marks,
        epic: { 'slug' => 'e', 'name' => 'E' }, stories: [],
        disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }, project_slug: 'p'
      ).call
    end

    def disc(id, status, question, origin)
      { 'id' => id, 'status' => status, 'question' => question, 'origin' => origin,
        'created_at' => Time.now.utc.iso8601 }
    end

    it 'tags the active spike card with its origin' do
      html = render(spike: disc('disc-001', 'active_spike', 'agent spike', 'agent'))
      expect(html).to include('[agent]')
    end

    it 'tags findings_ready cards with their origin' do
      html = render(findings_ready: [disc('disc-002', 'findings_ready', 'human finding', 'human')])
      expect(html).to include('[human]')
    end

    it 'tags mark cards with their origin' do
      html = render(marks: [disc('disc-003', 'mark', 'agent mark', 'agent'),
                            disc('disc-004', 'mark', 'human mark', 'human')])
      expect(html).to include('[agent]')
      expect(html).to include('[human]')
    end
  end
end
