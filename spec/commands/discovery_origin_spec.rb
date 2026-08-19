# frozen_string_literal: true

require 'spec_helper'

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

    it 'records origin=human when --auto is omitted on a human-filed spike' do
      expect(spike_done([])['origin']).to eq 'human'
    end

    it 'leaves an agent-filed spike agent when closed without --auto' do
      # Omitting the flag must never silently relabel a spike an agent framed — the close
      # preserves the stored origin rather than defaulting it back to human.
      store.send(:with_db) { |db| db.execute("UPDATE discoveries SET origin='agent'") }
      expect(spike_done([])['origin']).to eq 'agent'
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

    it 'tags each rendered mark row with its origin' do
      store.create_discovery(project_id: ctx.project['id'], status: 'mark',
                             question: 'm1', origin: 'agent')
      store.create_discovery(project_id: ctx.project['id'], status: 'mark',
                             question: 'm2', origin: 'human')

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }

      expect(out[/.*m1.*/]).to include('[agent]')
      expect(out[/.*m2.*/]).to include('[human]')
    end
  end

  describe 'tyrion discovery show' do
    it 'tags the detail view with the origin' do
      d = store.create_discovery(project_id: ctx.project['id'], status: 'mark',
                                 question: 'q', origin: 'agent')
      out, = capture_io { Tyrion::Commands.cmd_discovery_show([d['id']], store) }
      expect(out).to include('[agent]')
    end

    it 'renders a humanized verdict distinctly from status' do
      store.create_discovery(project_id: ctx.project['id'], status: 'active_spike', question: 'q2')
      spike = store.active_spike_for(ctx.project['id'])
      disc  = store.close_spike(spike['id'], finding: 'f', confidence: 'high', recommendation: 'r',
                                              verdict: 'falsified_alternative')

      out, = capture_io { Tyrion::Commands.cmd_discovery_show([disc['id']], store) }
      expect(out).to match(/\[findings_ready\]/)
      expect(out).to match(/Verdict:\s+falsified alternative/)
    end

    it 'shows unscored for a findings_ready discovery closed without --verdict' do
      d = store.create_discovery(project_id: ctx.project['id'], status: 'findings_ready', question: 'q3')
      out, = capture_io { Tyrion::Commands.cmd_discovery_show([d['id']], store) }
      expect(out).to match(/Verdict:\s+\(unscored\)/)
    end

    it 'omits the Verdict line entirely for a mark (can never carry one)' do
      d = store.create_discovery(project_id: ctx.project['id'], status: 'mark', question: 'q4')
      out, = capture_io { Tyrion::Commands.cmd_discovery_show([d['id']], store) }
      expect(out).not_to match(/Verdict:/)
    end

    it 'omits the Verdict line for a deferred mark -- deferred alone does not imply scoreable' do
      d = store.create_discovery(project_id: ctx.project['id'], status: 'mark', question: 'q5')
      store.defer_discovery(d['id'], reason: 'not worth pursuing')
      out, = capture_io { Tyrion::Commands.cmd_discovery_show([d['id']], store) }
      expect(out).not_to match(/Verdict:/)
    end

    it 'still shows a recorded verdict after the scored finding is later deferred' do
      store.create_discovery(project_id: ctx.project['id'], status: 'active_spike', question: 'q6')
      spike = store.active_spike_for(ctx.project['id'])
      disc  = store.close_spike(spike['id'], finding: 'f', confidence: 'high', recommendation: 'r', verdict: 'partial')
      store.defer_discovery(disc['id'], reason: 'shelved')

      out, = capture_io { Tyrion::Commands.cmd_discovery_show([disc['id']], store) }
      expect(out).to match(/\[deferred\]/)
      expect(out).to match(/Verdict:\s+partial/)
    end
  end
end
