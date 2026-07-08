# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'epic completion seal commands' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
    allow(Tyrion::Repo).to receive(:clear_active_story)
  end

  def create_story(slug, done: false)
    s = store.create_story(epic_id: epic['id'], slug: slug, title: slug)
    store.complete_story(s['id'], 'done', force: true) if done
    store.find_story(epic['id'], slug)
  end

  # ── cmd_done seal prompt ──────────────────────────────────────────────────
  describe 'cmd_done seal prompt (criteria 1-3)' do
    before { create_story('first', done: true) }

    it 'prompts to seal when the last story closes' do
      s = create_story('last'); store.start_story(s['id'])
      out = StringIO.new
      Tyrion::Commands.cmd_done(['last', 'wrapped up'], store,
        input: StringIO.new("n\n"), output: out)
      expect(out.string).to match(/All 2 stories done\. Seal epic my-epic as complete\? \[y\/N\]/)
    end

    it 'seals the epic when the user answers y' do
      s = create_story('last'); store.start_story(s['id'])
      Tyrion::Commands.cmd_done(['last', 'wrapped up'], store,
        input: StringIO.new("y\n"), output: StringIO.new)
      expect(store.find_epic_by_id(epic['id'])['status']).to eq('done')
    end

    it 'leaves the epic active and prints the hint when the user answers n' do
      s = create_story('last'); store.start_story(s['id'])
      out = StringIO.new
      Tyrion::Commands.cmd_done(['last', 'wrapped up'], store,
        input: StringIO.new("n\n"), output: out)
      expect(store.find_epic_by_id(epic['id'])['status']).to eq('active')
      expect(out.string).to match(/tyrion epic complete my-epic/)
    end

    it 'does not prompt when stories remain unfinished' do
      create_story('middle')  # stays pending
      s = create_story('last'); store.start_story(s['id'])
      out = StringIO.new
      Tyrion::Commands.cmd_done(['last', 'wrapped up'], store,
        input: StringIO.new("y\n"), output: out)
      expect(out.string).not_to match(/Seal epic/)
      expect(store.find_epic_by_id(epic['id'])['status']).to eq('active')
    end
  end

  # ── tyrion epic complete ──────────────────────────────────────────────────
  describe 'cmd_epic_complete (criterion 4)' do
    it 'seals the epic when all stories are done' do
      create_story('a', done: true)
      create_story('b', done: true)
      expect { Tyrion::Commands.cmd_epic_complete(['my-epic'], store) }
        .to output(/Epic my-epic sealed as done\./).to_stdout
      expect(store.find_epic_by_id(epic['id'])['status']).to eq('done')
    end

    it 'refuses when a story is not done and names it' do
      create_story('a', done: true)
      create_story('b')  # pending
      expect { Tyrion::Commands.cmd_epic_complete(['my-epic'], store) }
        .to raise_error(SystemExit).and output(/not done.*b/).to_stderr
      expect(store.find_epic_by_id(epic['id'])['status']).to eq('active')
    end

    it 'seals anyway with --force despite undone stories' do
      create_story('a', done: true)
      create_story('b')  # pending
      Tyrion::Commands.cmd_epic_complete(['my-epic', '--force'], store)
      expect(store.find_epic_by_id(epic['id'])['status']).to eq('done')
    end

    it 'refuses an epic with no stories' do
      expect { Tyrion::Commands.cmd_epic_complete(['my-epic'], store) }
        .to raise_error(SystemExit).and output(/no stories/i).to_stderr
    end
  end
end
