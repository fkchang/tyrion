# frozen_string_literal: true

require 'spec_helper'

# Specs for `tyrion statusline` — the one-line lane surface embedded in the
# Claude Code statusline. current_lane_token is stubbed so no `ps` walk runs.
RSpec.describe 'Commands.cmd_statusline' do
  let(:ctx)     { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store)   { ctx.store }
  let(:epic_id) { ctx.epic['id'] }
  let(:token)   { 'claude:111:stampA' }

  before { allow(Tyrion::Commands).to receive(:current_lane_token).and_return(token) }

  def seed_story(slug, status: 'pending', claimed_by: nil)
    story = store.create_story(epic_id: epic_id, slug: slug, title: slug)
    store.start_story(story['id'], claimed_by: claimed_by) if status == 'in_progress'
    store.complete_story(story['id'], 'done') if status == 'done'
    story
  end

  it 'prints "<epic>/<story> (done/total)" for the lane\'s claimed story' do
    seed_story('done-a',  status: 'done')
    seed_story('active-a', status: 'in_progress', claimed_by: token)
    seed_story('pending-a')

    expect { Tyrion::Commands.cmd_statusline([], store) }
      .to output("my-epic/active-a (1/3)\n").to_stdout
  end

  it 'prints nothing and exits 0 when the lane has no active epic' do
    store # force worktree setup before overriding the Repo stub below
    allow(Tyrion::Repo).to receive(:active_epic).and_return(nil)
    expect { Tyrion::Commands.cmd_statusline([], store) }.to output('').to_stdout
  end

  it 'shows the epic alone (no /story) when no story is in progress' do
    seed_story('done-a', status: 'done')
    seed_story('pending-a')
    expect { Tyrion::Commands.cmd_statusline([], store) }
      .to output("my-epic (1/2)\n").to_stdout
  end

  it 'excludes abandoned stories from the total' do
    seed_story('done-a', status: 'done')
    ab = seed_story('gone-a')
    store.update_story(ab['id'], status: 'abandoned')
    seed_story('pending-a')
    expect { Tyrion::Commands.cmd_statusline([], store) }
      .to output("my-epic (1/2)\n").to_stdout
  end

  it 'falls back to any in-progress story when this lane has claimed none (legacy single-session)' do
    seed_story('done-a', status: 'done')
    seed_story('unclaimed-a', status: 'in_progress', claimed_by: nil)

    expect { Tyrion::Commands.cmd_statusline([], store) }
      .to output("my-epic/unclaimed-a (1/2)\n").to_stdout
  end

  # Criteria 6 & 7 mechanism: two lanes in the same epic each surface THEIR own
  # claimed story, not each other's.
  it 'resolves a different story per lane token' do
    seed_story('story-a', status: 'in_progress', claimed_by: token)
    other = 'claude:222:stampB'
    seed_story('story-b', status: 'in_progress', claimed_by: other)

    expect { Tyrion::Commands.cmd_statusline([], store) }
      .to output("my-epic/story-a (0/2)\n").to_stdout

    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(other)
    expect { Tyrion::Commands.cmd_statusline([], store) }
      .to output("my-epic/story-b (0/2)\n").to_stdout
  end
end
