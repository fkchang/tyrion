# frozen_string_literal: true

require 'spec_helper'

# `tyrion context <story> "text"` (a STORY's current_context) and
# `tyrion epic-context ...` (the EPIC's wiki file) are different objects that
# share no code and no state. This pins the older one so adding the newer
# command cannot quietly change it.
RSpec.describe 'tyrion context' do
  let(:ctx)   { tyrion_worktree(project_slug: 'ctxproj', epic_slug: 'ctx-epic') }
  let(:store) { ctx.store }
  let(:story) { store.create_story(epic_id: ctx.epic['id'], slug: 'my-story', title: 'My Story') }

  it "updates the story's current_context" do
    story
    expect { Tyrion::Commands.cmd_context(['my-story', 'fresh', 'summary'], store) }
      .to output(/Context updated for my-story/).to_stdout

    expect(store.find_story(ctx.epic['id'], 'my-story')['current_context']).to eq 'fresh summary'
  end

  it 'dies with usage when the text is missing' do
    story
    expect { Tyrion::Commands.cmd_context(['my-story'], store) }.to raise_error(SystemExit)
      .and output(/Usage: tyrion context <slug>/).to_stderr
  end

  it 'dies when the story is not found' do
    expect { Tyrion::Commands.cmd_context(['nope', 'text'], store) }.to raise_error(SystemExit)
      .and output(/Story not found: nope/).to_stderr
  end

  it 'is dispatched separately from epic-context' do
    expect(Tyrion::Commands).to receive(:cmd_context).with(['my-story', 'text'], anything)
    expect(Tyrion::Commands).not_to receive(:cmd_epic_context)
    Tyrion::Commands.run(%w[context my-story text])
  end

  it 'routes epic-context to its own handler, not cmd_context' do
    expect(Tyrion::Commands).to receive(:cmd_epic_context).with(['show'], anything)
    expect(Tyrion::Commands).not_to receive(:cmd_context)
    Tyrion::Commands.run(%w[epic-context show])
  end
end
