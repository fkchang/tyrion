# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion block / unblock' do
  let(:ctx) do
    tyrion_worktree(
      project_slug: 'blockproj',
      epic_slug:    'block-epic',
      git_branch:   'feature/blocked-status'
    )
  end
  let(:store)  { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { ctx.epic }

  def make_story(slug: 'my-story', title: 'My Story', status: 'pending')
    story = store.create_story(epic_id: epic['id'], slug: slug, title: title)
    store.update_story(story['id'], 'status' => status) if status != 'pending'
    store.find_story(epic['id'], slug)
  end

  # ── Schema: migration idempotency ────────────────────────────────────────

  describe 'migration idempotency' do
    it 'adds blocked_on and blocked_on_discovery columns without error on a fresh DB' do
      story = make_story
      expect(story.key?('blocked_on')).to be true
      expect(story.key?('blocked_on_discovery')).to be true
      expect(story['blocked_on']).to be_nil
      expect(story['blocked_on_discovery']).to be_nil
    end

    it 'does not raise when Store.new is called a second time on the same DB path' do
      db_path = File.join(ctx.tmpdir, 'test.db')
      expect { Tyrion::Store.new(db_path: db_path) }.not_to raise_error
    end
  end

  # ── cmd_block ─────────────────────────────────────────────────────────────

  describe 'cmd_block' do
    context 'sets status=blocked and records the reason' do
      before { make_story }

      it 'prints Blocked: and the slug' do
        expect {
          Tyrion::Commands.cmd_block(['my-story', 'waiting for Finance approval'], store)
        }.to output(/Blocked:.*my-story/).to_stdout
      end

      it 'sets story status to blocked' do
        capture_io { Tyrion::Commands.cmd_block(['my-story', 'waiting for Finance approval'], store) }
        expect(store.find_story(epic['id'], 'my-story')['status']).to eq 'blocked'
      end

      it 'records the blocked_on reason' do
        capture_io { Tyrion::Commands.cmd_block(['my-story', 'waiting for Finance approval'], store) }
        expect(store.find_story(epic['id'], 'my-story')['blocked_on']).to eq 'waiting for Finance approval'
      end

      it 'leaves blocked_on_discovery nil when --discovery not given' do
        capture_io { Tyrion::Commands.cmd_block(['my-story', 'waiting for Finance approval'], store) }
        expect(store.find_story(epic['id'], 'my-story')['blocked_on_discovery']).to be_nil
      end
    end

    context 'records the block as a story note' do
      before { make_story }

      it 'writes a blocker note with the reason' do
        capture_io { Tyrion::Commands.cmd_block(['my-story', 'waiting for Finance approval'], store) }
        story = store.find_story(epic['id'], 'my-story')
        notes = store.notes_for_story(story['id']).select { |n| n['kind'] == 'blocker' }
        expect(notes.first['body']).to eq 'blocked: waiting for Finance approval'
      end

      it 'records metadata with the reason' do
        capture_io { Tyrion::Commands.cmd_block(['my-story', 'waiting for Finance approval'], store) }
        story = store.find_story(epic['id'], 'my-story')
        notes = store.notes_for_story(story['id']).select { |n| n['kind'] == 'blocker' }
        meta = JSON.parse(notes.first['metadata'])
        expect(meta).to include('action' => 'block', 'blocked_on' => 'waiting for Finance approval')
      end
    end

    context 'with --discovery flag' do
      before do
        make_story
        @disc = store.create_discovery(project_id: project['id'], status: 'active_spike', question: 'Q?')
      end

      it 'records blocked_on_discovery with the disc-id' do
        capture_io do
          Tyrion::Commands.cmd_block(['my-story', 'waiting on spike', '--discovery', @disc['id']], store)
        end
        story = store.find_story(epic['id'], 'my-story')
        expect(story['blocked_on_discovery']).to eq @disc['id']
      end

      it 'prints the disc-id in stdout' do
        expect {
          Tyrion::Commands.cmd_block(['my-story', 'waiting on spike', '--discovery', @disc['id']], store)
        }.to output(/#{Regexp.escape(@disc['id'])}/).to_stdout
      end

      it 'includes the disc-id in the blocker note body' do
        capture_io do
          Tyrion::Commands.cmd_block(['my-story', 'waiting on spike', '--discovery', @disc['id']], store)
        end
        story = store.find_story(epic['id'], 'my-story')
        notes = store.notes_for_story(story['id']).select { |n| n['kind'] == 'blocker' }
        expect(notes.first['body']).to include(@disc['id'])
      end
    end

    context 'refuses a done story' do
      before { make_story(status: 'done') }

      it 'exits 1' do
        _out, err = capture_io do
          expect { Tyrion::Commands.cmd_block(['my-story', 'any reason'], store) }.to raise_error(SystemExit)
        end
        expect(err).to match(/done/i)
      end

      it 'leaves status as done' do
        capture_io { expect { Tyrion::Commands.cmd_block(['my-story', 'reason'], store) }.to raise_error(SystemExit) }
        expect(store.find_story(epic['id'], 'my-story')['status']).to eq 'done'
      end
    end

    context 'missing reason' do
      before { make_story }

      it 'exits 1 with usage message' do
        _out, err = capture_io do
          expect { Tyrion::Commands.cmd_block(['my-story'], store) }.to raise_error(SystemExit)
        end
        expect(err).to match(/Usage:.*block/i)
      end
    end

    context 'with --discovery pointing at a non-existent disc-id' do
      before { make_story }

      it 'exits 1 with a not found error' do
        _out, err = capture_io do
          expect {
            Tyrion::Commands.cmd_block(['my-story', 'reason', '--discovery', 'disc-999'], store)
          }.to raise_error(SystemExit)
        end
        expect(err).to include('disc-999')
        expect(err).to match(/not found/i)
      end

      it 'leaves story status as pending' do
        capture_io do
          expect {
            Tyrion::Commands.cmd_block(['my-story', 'reason', '--discovery', 'disc-999'], store)
          }.to raise_error(SystemExit)
        end
        expect(store.find_story(epic['id'], 'my-story')['status']).to eq 'pending'
      end
    end
  end

  # ── cmd_unblock ───────────────────────────────────────────────────────────

  describe 'cmd_unblock' do
    context 'happy path — blocked story returns to pending' do
      before do
        story = make_story
        store.block_story(story['id'], blocked_on: 'waiting on Finance')
      end

      it 'prints Unblocked: and the slug' do
        expect {
          Tyrion::Commands.cmd_unblock(['my-story'], store)
        }.to output(/Unblocked:.*my-story/i).to_stdout
      end

      it 'sets status back to pending' do
        capture_io { Tyrion::Commands.cmd_unblock(['my-story'], store) }
        expect(store.find_story(epic['id'], 'my-story')['status']).to eq 'pending'
      end

      it 'clears blocked_on' do
        capture_io { Tyrion::Commands.cmd_unblock(['my-story'], store) }
        expect(store.find_story(epic['id'], 'my-story')['blocked_on']).to be_nil
      end

      it 'clears blocked_on_discovery' do
        disc = store.create_discovery(project_id: project['id'], status: 'active_spike', question: 'Q?')
        story = store.find_story(epic['id'], 'my-story')
        store.update_story(story['id'], 'blocked_on_discovery' => disc['id'])
        capture_io { Tyrion::Commands.cmd_unblock(['my-story'], store) }
        expect(store.find_story(epic['id'], 'my-story')['blocked_on_discovery']).to be_nil
      end

      it 'writes a blocker note preserving the prior reason' do
        capture_io { Tyrion::Commands.cmd_unblock(['my-story'], store) }
        story = store.find_story(epic['id'], 'my-story')
        notes = store.notes_for_story(story['id']).select { |n| n['kind'] == 'blocker' }
        expect(notes.first['body']).to eq 'unblocked (was: waiting on Finance)'
      end

      it 'records metadata with the prior reason' do
        capture_io { Tyrion::Commands.cmd_unblock(['my-story'], store) }
        story = store.find_story(epic['id'], 'my-story')
        notes = store.notes_for_story(story['id']).select { |n| n['kind'] == 'blocker' }
        meta = JSON.parse(notes.first['metadata'])
        expect(meta).to include('action' => 'unblock', 'blocked_on' => 'waiting on Finance')
      end

    end

    context 'full block/unblock cycle via commands' do
      before { make_story }

      it 'keeps both the block and unblock notes after unblocking, so the reason is recoverable' do
        capture_io { Tyrion::Commands.cmd_block(['my-story', 'waiting on Finance'], store) }
        capture_io { Tyrion::Commands.cmd_unblock(['my-story'], store) }

        story = store.find_story(epic['id'], 'my-story')
        notes = store.notes_for_story(story['id']).select { |n| n['kind'] == 'blocker' }
        bodies = notes.map { |n| n['body'] }
        expect(bodies).to include('blocked: waiting on Finance')
        expect(bodies).to include('unblocked (was: waiting on Finance)')
        expect(story['blocked_on']).to be_nil
      end
    end

    context 'refuses when story is not blocked' do
      before { make_story }

      it 'exits 1 with an error about the current status' do
        _out, err = capture_io do
          expect { Tyrion::Commands.cmd_unblock(['my-story'], store) }.to raise_error(SystemExit)
        end
        expect(err).to match(/not blocked/i)
      end
    end
  end

  # ── cmd_start refuses blocked story ──────────────────────────────────────

  describe 'cmd_start with a blocked story' do
    before do
      story = make_story
      store.block_story(story['id'], blocked_on: 'waiting for stakeholder answer')
    end

    it 'exits 1' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_start(['my-story'], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('blocked')
    end

    it 'includes the blocked reason in the error message' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_start(['my-story'], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('waiting for stakeholder answer')
    end

    it 'includes the unblock command in the error message' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_start(['my-story'], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('tyrion unblock my-story')
    end

    it 'leaves status as blocked' do
      capture_io { expect { Tyrion::Commands.cmd_start(['my-story'], store) }.to raise_error(SystemExit) }
      expect(store.find_story(epic['id'], 'my-story')['status']).to eq 'blocked'
    end
  end

  # ── cmd_status Blocked lane ───────────────────────────────────────────────

  describe 'cmd_status Blocked lane' do
    context 'with a blocked story' do
      before do
        story = make_story
        store.block_story(story['id'], blocked_on: 'waiting for Finance approval')
      end

      it 'renders a BLOCKED section heading' do
        expect { Tyrion::Commands.cmd_status([], store) }.to output(/BLOCKED/).to_stdout
      end

      it 'shows the story slug in the blocked lane' do
        expect { Tyrion::Commands.cmd_status([], store) }.to output(/my-story/).to_stdout
      end

      it 'shows the blocked_on reason in the blocked lane' do
        expect { Tyrion::Commands.cmd_status([], store) }.to output(/waiting for Finance approval/).to_stdout
      end

      it 'shows the unblock command hint' do
        expect { Tyrion::Commands.cmd_status([], store) }.to output(/tyrion unblock my-story/).to_stdout
      end
    end

    context 'with no blocked stories' do
      before { make_story }

      it 'does not render BLOCKED section' do
        expect { Tyrion::Commands.cmd_status([], store) }.not_to output(/BLOCKED/).to_stdout
      end
    end

    context 'orient extension — linked discovery that has resolved' do
      # Phase 5: when blocked_on_discovery is promoted/deferred/invalidated,
      # surface "resolved → unblock?" in the status output.
      it 'shows resolved indicator when linked discovery is promoted_to_story' do
        disc = store.create_discovery(project_id: project['id'], status: 'findings_ready', question: 'Q?')
        story = make_story
        store.block_story(story['id'], blocked_on: 'waiting on spike', blocked_on_discovery: disc['id'])

        another_epic = store.create_epic(project_id: project['id'], slug: 'promo-epic', name: 'Promo')
        store.promote_discovery_to_story(disc['id'], epic_id: another_epic['id'], slug: 'derived', title: 'Derived', intent: 'From finding')

        out, = capture_io { Tyrion::Commands.cmd_status([], store) }

        expect(out).to include(disc['id'])
        expect(out).to match(/resolved.*unblock\?/i)
      end
    end

    context 'with a blocked story linked to an unresolved discovery' do
      it 'shows the disc-id without the resolved indicator' do
        disc = store.create_discovery(project_id: project['id'], status: 'active_spike', question: 'Q?')
        story = make_story
        store.block_story(story['id'], blocked_on: 'spike in progress', blocked_on_discovery: disc['id'])

        out, = capture_io { Tyrion::Commands.cmd_status([], store) }

        expect(out).to include(disc['id'])
        expect(out).not_to match(/resolved.*unblock\?/i)
      end
    end
  end
end
