# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Tyrion::Commands.cmd_discovery_delete' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'discovery-autonomy') }
  let(:store) { ctx.store }

  def discovery(status, question = 'a CLI-parsing accident')
    store.create_discovery(project_id: ctx.project['id'], status: status, question: question)
  end

  context 'criteria 1-3 — deleting a discovery that should not exist removes it permanently' do
    it 'deletes a mark and it no longer resolves' do
      disc = discovery('mark')
      expect { Tyrion::Commands.cmd_discovery_delete([disc['id']], store) }
        .to output(/\[deleted\] #{disc['id']}/).to_stdout

      expect(store.find_discovery(disc['id'])).to be_nil
    end

    it 'deletes a findings_ready discovery and it no longer resolves' do
      disc = discovery('findings_ready')
      capture_io { Tyrion::Commands.cmd_discovery_delete([disc['id']], store) }
      expect(store.find_discovery(disc['id'])).to be_nil
    end

    it 'echoes the full row (not just the glance line) so a mis-delete is re-fileable' do
      disc = store.create_discovery(
        project_id: ctx.project['id'], status: 'findings_ready',
        headline: 'a short headline', question: 'the raw question noticed',
        finding: 'the actual finding', recommendation: 'do the thing'
      )
      out, = capture_io { Tyrion::Commands.cmd_discovery_delete([disc['id']], store) }
      expect(out).to include('a short headline')
      expect(out).to include('the raw question noticed')
      expect(out).to include('the actual finding')
      expect(out).to include('do the thing')
    end
  end

  context 'criterion 4 — a discovery promoted to a story is refused, naming the story' do
    it 'refuses deletion and names the linked story slug' do
      story = store.create_story(epic_id: ctx.epic['id'], slug: 'the-linked-story', title: 'The Linked Story')
      disc  = store.create_discovery(project_id: ctx.project['id'], status: 'promoted_to_story', story_id: story['id'])

      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery_delete([disc['id']], store) }.to raise_error(SystemExit)
      end
      expect(err).to include(disc['id'])
      expect(err).to include('the-linked-story')

      expect(store.find_discovery(disc['id'])).not_to be_nil
    end

    it 'the guard lives in the store, not just the CLI' do
      story = store.create_story(epic_id: ctx.epic['id'], slug: 'another-story', title: 'Another Story')
      disc  = store.create_discovery(project_id: ctx.project['id'], status: 'promoted_to_story', story_id: story['id'])

      expect { store.delete_discovery(disc['id']) }.to raise_error(RuntimeError, /another-story/)
      expect(store.find_discovery(disc['id'])).not_to be_nil
    end
  end

  context 'criterion (blocked story) — a discovery a story is blocked on is refused, naming the story' do
    it 'refuses deletion and names the blocked story slug plus the unblock command' do
      story = store.create_story(epic_id: ctx.epic['id'], slug: 'the-blocked-story', title: 'The Blocked Story')
      disc  = discovery('findings_ready')
      store.block_story(story['id'], blocked_on: 'waiting on this', blocked_on_discovery: disc['id'])

      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery_delete([disc['id']], store) }.to raise_error(SystemExit)
      end
      expect(err).to include(disc['id'])
      expect(err).to include('the-blocked-story')
      expect(err).to include('tyrion unblock the-blocked-story')

      expect(store.find_discovery(disc['id'])).not_to be_nil
    end

    it 'the guard lives in the store, not just the CLI' do
      story = store.create_story(epic_id: ctx.epic['id'], slug: 'blocked-at-store-level', title: 'Blocked')
      disc  = discovery('findings_ready')
      store.block_story(story['id'], blocked_on: 'waiting', blocked_on_discovery: disc['id'])

      expect { store.delete_discovery(disc['id']) }.to raise_error(RuntimeError, /blocked-at-store-level/)
      expect(store.find_discovery(disc['id'])).not_to be_nil
    end
  end

  context 'unknown disc-id' do
    it 'prints not found and exits 1' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery_delete(['disc-999'], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('disc-999')
      expect(err).to include('not found')
    end
  end

  context 'project scope — same boundary as cmd_discover_upgrade' do
    it 'reports not found (not a leak) for a discovery belonging to another project, and does not delete it' do
      other   = store.create_project(slug: 'other-proj', name: 'Other')
      foreign = store.create_discovery(project_id: other['id'], status: 'mark', question: 'theirs')

      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery_delete([foreign['id']], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('not found')
      expect(store.find_discovery(foreign['id'])).not_to be_nil
    end
  end

  context 'usage and dispatch' do
    it 'exits 1 with usage when no disc-id is given' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery_delete([], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('tyrion discovery delete')
    end

    it 'is reachable through the discovery subcommand dispatcher' do
      disc = discovery('mark')
      capture_io { Tyrion::Commands.cmd_discovery(['delete', disc['id']], store) }
      expect(store.find_discovery(disc['id'])).to be_nil
    end
  end
end
