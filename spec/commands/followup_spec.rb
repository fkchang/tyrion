# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion followup' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let!(:story) do
    store.create_story(epic_id: ctx.epic['id'], slug: 'done-story', title: 'Done Story')
    s = store.find_story(ctx.epic['id'], 'done-story')
    store.start_story(s['id'])
    store.complete_story(s['id'], 'done')
    store.find_story(ctx.epic['id'], 'done-story')
  end

  describe 'tyrion followup list' do
    context 'when story has two followup notes' do
      before do
        store.add_note(story['id'], 'followup', 'Check the deploy logs')
        store.add_note(story['id'], 'followup', 'Notify the team')
      end

      it 'shows each followup with index, body, and created_at' do
        out, = capture_io { Tyrion::Commands.cmd_followup_list(['done-story'], store) }
        expect(out).to match(/1\.\s+Check the deploy logs/)
        expect(out).to match(/2\.\s+Notify the team/)
        expect(out).to match(/\d{4}-\d{2}-\d{2}/)
      end

      it 'shows resolved notes with a resolved marker' do
        notes = store.followup_notes(story['id'])
        store.resolve_followup_note(notes.first['id'])
        expect { Tyrion::Commands.cmd_followup_list(['done-story'], store) }
          .to output(/resolved/).to_stdout
      end
    end

    it 'prints a message when there are no followup notes' do
      expect { Tyrion::Commands.cmd_followup_list(['done-story'], store) }
        .to output(/No followup notes/).to_stdout
    end

    it 'exits with error when story not found' do
      expect { Tyrion::Commands.cmd_followup_list(['no-story'], store) }
        .to raise_error(SystemExit)
        .and output(/not found/i).to_stderr
    end
  end

  describe 'tyrion followup resolve' do
    before do
      store.add_note(story['id'], 'followup', 'Check the deploy logs')
      store.add_note(story['id'], 'followup', 'Notify the team')
    end

    it 'sets resolved_at on followup 1' do
      Tyrion::Commands.cmd_followup_resolve(['done-story', '1'], store, output: StringIO.new)
      notes = store.followup_notes(story['id'])
      expect(notes[0]['resolved_at']).not_to be_nil
      expect(notes[1]['resolved_at']).to be_nil
    end

    it 'prints confirmation on resolve' do
      expect { Tyrion::Commands.cmd_followup_resolve(['done-story', '1'], store) }
        .to output(/Followup 1 resolved/).to_stdout
    end

    it 'resolving one followup keeps the story in NEEDS FOLLOW-UP' do
      Tyrion::Commands.cmd_followup_resolve(['done-story', '1'], store, output: StringIO.new)
      remaining = store.done_stories_with_followup_notes(ctx.project['id'])
      expect(remaining).not_to be_empty
    end

    it 'removes story from NEEDS FOLLOW-UP when all followups are resolved' do
      sink = StringIO.new
      Tyrion::Commands.cmd_followup_resolve(['done-story', '1'], store, output: sink)
      Tyrion::Commands.cmd_followup_resolve(['done-story', '2'], store, output: sink)
      remaining = store.done_stories_with_followup_notes(ctx.project['id'])
      expect(remaining).to be_empty
    end

    it 'exits with error when index is out of range' do
      expect { Tyrion::Commands.cmd_followup_resolve(['done-story', '9'], store) }
        .to raise_error(SystemExit)
        .and output(/Index 9 out of range \(1-2\)/).to_stderr
    end

    it 'exits with error when followup is already resolved' do
      Tyrion::Commands.cmd_followup_resolve(['done-story', '1'], store, output: StringIO.new)
      expect { Tyrion::Commands.cmd_followup_resolve(['done-story', '1'], store) }
        .to raise_error(SystemExit)
        .and output(/already resolved/i).to_stderr
    end

    it 'exits with error when story not found' do
      expect { Tyrion::Commands.cmd_followup_resolve(['no-story', '1'], store) }
        .to raise_error(SystemExit)
        .and output(/not found/i).to_stderr
    end
  end

  describe 'done_stories_with_followup_notes filtering' do
    it 'excludes stories where all followups are resolved' do
      store.add_note(story['id'], 'followup', 'needs doing')
      notes = store.followup_notes(story['id'])
      store.resolve_followup_note(notes.first['id'])
      result = store.done_stories_with_followup_notes(ctx.project['id'])
      expect(result).to be_empty
    end

    it 'includes stories with at least one unresolved followup' do
      store.add_note(story['id'], 'followup', 'resolved one')
      store.add_note(story['id'], 'followup', 'still open')
      notes = store.followup_notes(story['id'])
      store.resolve_followup_note(notes.first['id'])
      result = store.done_stories_with_followup_notes(ctx.project['id'])
      expect(result.length).to eq(1)
    end
  end

  describe 'tyrion status NEEDS FOLLOW-UP lane' do
    context 'with one resolved and one unresolved followup' do
      before do
        store.add_note(story['id'], 'followup', 'first unresolved note')
        store.add_note(story['id'], 'followup', 'second resolved note')
        notes = store.followup_notes(story['id'])
        store.resolve_followup_note(notes.last['id'])
      end

      it 'shows the story in NEEDS FOLLOW-UP' do
        expect { Tyrion::Commands.cmd_status([], store) }
          .to output(/NEEDS FOLLOW-UP/).to_stdout
      end

      it 'shows the story slug in the NEEDS FOLLOW-UP lane' do
        expect { Tyrion::Commands.cmd_status([], store) }
          .to output(/done-story/).to_stdout
      end

      it 'shows the latest unresolved body, not the latest overall' do
        out, = capture_io { Tyrion::Commands.cmd_status([], store) }
        expect(out).to include('first unresolved note')
        expect(out).not_to include('second resolved note')
      end
    end

    context 'when all followups are resolved' do
      before do
        store.add_note(story['id'], 'followup', 'now resolved')
        notes = store.followup_notes(story['id'])
        store.resolve_followup_note(notes.first['id'])
      end

      it 'does not show NEEDS FOLLOW-UP' do
        expect { Tyrion::Commands.cmd_status([], store) }
          .not_to output(/NEEDS FOLLOW-UP/).to_stdout
      end
    end
  end
end
