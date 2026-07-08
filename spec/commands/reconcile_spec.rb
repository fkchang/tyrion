# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion reconcile' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let!(:story) do
    store.create_story(epic_id: ctx.epic['id'], slug: 'my-story', title: 'My Story')
    s = store.find_story(ctx.epic['id'], 'my-story')
    store.start_story(s['id'])
    store.update_context(s['id'], 'stale context')
    store.update_next_action(s['id'], 'stale next action')
    store.find_story(ctx.epic['id'], 'my-story')
  end

  let!(:criterion) do
    store.add_criteria(story['id'], [{ keyword: 'Then', semantic_kind: 'then', text: 'it works' }]).first
  end

  describe '--context/--next/--note flags' do
    it 'updates context, next_action, and adds a decision note' do
      expect {
        Tyrion::Commands.cmd_reconcile(
          ['my-story', '--context', 'fresh ctx', '--next', 'new step', '--note', 'what changed'],
          store
        )
      }.to output(/Reconciled my-story/).to_stdout

      updated = store.find_story(ctx.epic['id'], 'my-story')
      expect(updated['current_context']).to eq('fresh ctx')
      expect(updated['next_action']).to eq('new step')

      notes = store.notes_for_story(story['id'], limit: 10)
      expect(notes.any? { |n| n['kind'] == 'decision' && n['body'] == 'what changed' }).to be(true)
    end
  end

  describe '--check flag' do
    it 'marks the criterion as met and reports it in output' do
      out, = capture_io do
        Tyrion::Commands.cmd_reconcile(
          ['my-story', '--context', 'ctx', '--next', 'next', '--note', 'note', '--check', '1', 'test passed'],
          store
        )
      end
      criteria = store.criteria_for_story(story['id'])
      expect(criteria.first['status']).to eq('met')
      expect(criteria.first['evidence']).to eq('test passed')
      expect(out).to match(/criterion 1 marked met/)
    end
  end

  describe 'atomicity' do
    it 'rolls back all changes when a criterion check fails' do
      expect {
        Tyrion::Commands.cmd_reconcile(
          ['my-story', '--context', 'new ctx', '--next', 'new next', '--note', 'note', '--check', '99', 'evidence'],
          store
        )
      }.to raise_error(SystemExit).and output(/Criterion 99 not found/).to_stderr

      updated = store.find_story(ctx.epic['id'], 'my-story')
      expect(updated['current_context']).to eq('stale context')
      expect(updated['next_action']).to eq('stale next action')
      notes = store.notes_for_story(story['id'], limit: 10)
      expect(notes.none? { |n| n['kind'] == 'decision' }).to be(true)
    end
  end

  describe 'interactive form' do
    it 'prompts for each field when no flags given' do
      input  = StringIO.new("prompted context\nprompted next\nprompted note\n")
      output = StringIO.new
      Tyrion::Commands.cmd_reconcile(['my-story'], store, input: input, output: output)
      expect(output.string).to match(/Current context:/)
      expect(output.string).to match(/Next action:/)
      expect(output.string).to match(/Decision note:/)
      updated = store.find_story(ctx.epic['id'], 'my-story')
      expect(updated['current_context']).to eq('prompted context')
      expect(updated['next_action']).to eq('prompted next')
    end
  end

  it 'exits with error when story not found' do
    expect { Tyrion::Commands.cmd_reconcile(['no-story'], store) }
      .to raise_error(SystemExit)
      .and output(/not found/i).to_stderr
  end
end
