# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion notes' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:story) do
    store.create_story(epic_id: ctx.epic['id'], slug: 'test-story', title: 'Test Story')
    store.find_story(ctx.epic['id'], 'test-story')
  end

  before do
    long_body = 'A' * 130
    store.add_note(story['id'], 'decision', long_body)
    store.add_note(story['id'], 'plan', 'Short plan note.')
  end

  it 'prints all notes with kind, timestamp, and full untruncated body' do
    expect { Tyrion::Commands.cmd_notes(['test-story'], store) }
      .to output(/#{'A' * 130}/).to_stdout
  end

  it 'prints kind and timestamp for each note' do
    out, = capture_io { Tyrion::Commands.cmd_notes(['test-story'], store) }
    expect(out).to match(/\[decision\]/)
    expect(out).to match(/\[plan\]/)
    expect(out).to match(/\d{4}-\d{2}-\d{2}/)
  end

  it 'filters by --kind when flag is provided' do
    out, = capture_io { Tyrion::Commands.cmd_notes(['test-story', '--kind', 'plan'], store) }
    expect(out).to include('Short plan note.')
    expect(out).not_to match(/\[decision\]/)
  end

  it 'shows a message when no notes match the filter' do
    expect { Tyrion::Commands.cmd_notes(['test-story', '--kind', 'blocker'], store) }
      .to output(/No blocker notes/).to_stdout
  end

  it 'exits with error if story not found' do
    expect { Tyrion::Commands.cmd_notes(['no-such-story'], store) }
      .to raise_error(SystemExit)
      .and output(/not found/i).to_stderr
  end

  it 'errors when --kind is given without a value' do
    expect { Tyrion::Commands.cmd_notes(['test-story', '--kind'], store) }
      .to raise_error(SystemExit)
      .and output(/Missing value after --kind/).to_stderr
  end

  it 'errors when --kind is first with no subsequent slug' do
    expect { Tyrion::Commands.cmd_notes(['--kind', 'decision'], store) }
      .to raise_error(SystemExit)
      .and output(/Usage:/).to_stderr
  end

  it 'correctly identifies the slug when it equals the kind filter value' do
    store.create_story(epic_id: ctx.epic['id'], slug: 'plan', title: 'Plan Story')
    plan_story = store.find_story(ctx.epic['id'], 'plan')
    store.add_note(plan_story['id'], 'plan', 'note on the plan story')

    out, = capture_io { Tyrion::Commands.cmd_notes(['plan', '--kind', 'plan'], store) }
    expect(out).to include('note on the plan story')
  end
end
