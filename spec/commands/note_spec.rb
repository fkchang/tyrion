# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion note' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:story) { store.create_story(epic_id: ctx.epic['id'], slug: 'my-story', title: 'My Story') }

  describe 'happy path' do
    it 'adds a note of the given kind and prints confirmation' do
      story
      expect {
        Tyrion::Commands.cmd_note(['my-story', 'decision', 'use', 'postgres'], store)
      }.to output(/Note added to my-story \[decision\]/).to_stdout

      notes = store.notes_for_story(story['id'])
      expect(notes.last['kind']).to eq 'decision'
      expect(notes.last['body']).to eq 'use postgres'
    end
  end

  describe '--help' do
    it 'prints usage instead of storing "--help" as the note body (disc-092 class)' do
      story
      out, = capture_io { Tyrion::Commands.cmd_note(['my-story', 'decision', '--help'], store) }

      expect(out).to eq("#{Tyrion::Commands::NOTE_USAGE}\n")
      expect(store.notes_for_story(story['id'])).to be_empty
    end
  end
end
