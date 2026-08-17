# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Tyrion::Commands.cmd_discovery_defer' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'discovery-autonomy') }
  let(:store) { ctx.store }

  def discovery(status, question = 'Is this worth doing?')
    store.create_discovery(project_id: ctx.project['id'], status: status, question: question)
  end

  context 'criterion 2 — defer_reason column exists on discoveries' do
    it 'is present in the migrated schema' do
      cols = store.send(:with_db) { |db| db.execute('PRAGMA table_info(discoveries)').map { |r| r['name'] } }
      expect(cols).to include('defer_reason')
    end
  end

  context 'criterion 3/5 — defer from an open status sets deferred + reason' do
    it 'defers a mark with the supplied reason' do
      disc = discovery('mark')
      expect { Tyrion::Commands.cmd_discovery_defer([disc['id'], 'not worth it'], store) }
        .to output(/\[deferred\] #{disc['id']} — not worth it/).to_stdout

      after = store.find_discovery(disc['id'])
      expect(after['status']).to eq 'deferred'
      expect(after['defer_reason']).to eq 'not worth it'
    end

    it 'defers a findings_ready discovery' do
      disc = discovery('findings_ready')
      capture_io { Tyrion::Commands.cmd_discovery_defer([disc['id'], 'superseded'], store) }
      expect(store.find_discovery(disc['id'])['status']).to eq 'deferred'
    end

    it 'keeps an unquoted multi-word reason whole' do
      disc = discovery('mark')
      capture_io { Tyrion::Commands.cmd_discovery_defer([disc['id'], 'not', 'worth', 'the', 'effort'], store) }
      expect(store.find_discovery(disc['id'])['defer_reason']).to eq 'not worth the effort'
    end

    it 'leaves defer_reason nil when no reason is given' do
      disc = discovery('mark')
      capture_io { Tyrion::Commands.cmd_discovery_defer([disc['id']], store) }

      after = store.find_discovery(disc['id'])
      expect(after['status']).to eq 'deferred'
      expect(after['defer_reason']).to be_nil
    end
  end

  context 'criterion 4 — non-deferrable source statuses are refused' do
    %w[active_spike promoted_to_story invalidated].each do |status|
      it "refuses a #{status} discovery, naming the current status" do
        disc = discovery(status)
        _out, err = capture_io do
          expect { Tyrion::Commands.cmd_discovery_defer([disc['id']], store) }.to raise_error(SystemExit)
        end
        expect(err).to include(disc['id'])
        expect(err).to include(status)
        expect(store.find_discovery(disc['id'])['status']).to eq status
      end
    end
  end

  context 'criterion 5 — a deferred discovery drops out of the default open views' do
    # findings_ready rows print id + question in tyrion status; marks only collapse
    # into a count line, so this asserts against the status output that is visible.
    it 'no longer appears in tyrion status DISCOVERIES' do
      disc = discovery('findings_ready', 'ambient noise idea')
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to include('ambient noise idea').and include(disc['id'])

      capture_io { Tyrion::Commands.cmd_discovery_defer([disc['id'], 'nope'], store) }

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).not_to include('ambient noise idea')
      expect(out).not_to include(disc['id'])
    end

    it 'drops out of the marks shown in tyrion status' do
      disc = discovery('mark', 'worth a second look?')
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to include('worth a second look?')

      capture_io { Tyrion::Commands.cmd_discovery_defer([disc['id']], store) }

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).not_to include('worth a second look?')
    end

    it 'is excluded from the open-status discovery listings the web views query' do
      disc = discovery('mark')
      capture_io { Tyrion::Commands.cmd_discovery_defer([disc['id']], store) }

      marks = store.list_discoveries(project_id: ctx.project['id'], status: 'mark')
      ready = store.list_discoveries(project_id: ctx.project['id'], status: 'findings_ready')
      expect(marks.map { |d| d['id'] }).not_to include(disc['id'])
      expect(ready.map { |d| d['id'] }).not_to include(disc['id'])
    end

    it 'is still reachable via the deferred filter' do
      disc = discovery('mark')
      capture_io { Tyrion::Commands.cmd_discovery_defer([disc['id']], store) }
      out, = capture_io { Tyrion::Commands.cmd_discovery_list(['--status', 'deferred'], store) }
      expect(out).to include(disc['id'])
    end
  end

  context 'criterion 6 — unknown disc-id' do
    it 'prints not found and exits 1' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery_defer(['disc-999'], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('disc-999')
      expect(err).to include('not found')
    end
  end

  context 'criterion 7 — re-deferring is a friendly no-op' do
    it 'prints an already-deferred message without erroring and preserves the original reason' do
      disc = discovery('mark')
      capture_io { Tyrion::Commands.cmd_discovery_defer([disc['id'], 'first reason'], store) }

      expect { Tyrion::Commands.cmd_discovery_defer([disc['id'], 'second reason'], store) }
        .to output(/already deferred/).to_stdout

      expect(store.find_discovery(disc['id'])['defer_reason']).to eq 'first reason'
    end

    it 'echoes the reason already on record so the user sees which one won' do
      disc = discovery('mark')
      capture_io { Tyrion::Commands.cmd_discovery_defer([disc['id'], 'first reason'], store) }

      out, = capture_io { Tyrion::Commands.cmd_discovery_defer([disc['id'], 'second reason'], store) }
      expect(out).to include('first reason')
      expect(out).not_to include('second reason')
    end
  end

  context 'the source-state guard lives in the store, not just the CLI' do
    it 'refuses to overwrite a promoted discovery even when called directly' do
      disc = discovery('promoted_to_story')
      expect { store.defer_discovery(disc['id']) }.to raise_error(RuntimeError, /promoted_to_story/)
      expect(store.find_discovery(disc['id'])['status']).to eq 'promoted_to_story'
    end
  end

  context 'usage and dispatch' do
    it 'exits 1 with usage when no disc-id is given' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery_defer([], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('tyrion discovery defer')
    end

    it 'is reachable through the discovery subcommand dispatcher' do
      disc = discovery('mark')
      capture_io { Tyrion::Commands.cmd_discovery(['defer', disc['id'], 'via dispatch'], store) }
      expect(store.find_discovery(disc['id'])['status']).to eq 'deferred'
    end
  end
end
