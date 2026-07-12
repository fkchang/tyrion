# frozen_string_literal: true

require 'spec_helper'

# `tyrion list [epic-slug]` — an optional epic-slug arg lists that epic's
# stories instead of the active epic's; no arg keeps the active-epic behavior;
# an unknown slug exits 1 naming the slug.
RSpec.describe 'tyrion list' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'active-epic') }
  let(:store) { ctx.store }
  let(:other_epic) do
    store.create_epic(project_id: ctx.project['id'], slug: 'other-epic', name: 'Other Epic')
  end

  before do
    store.create_story(epic_id: ctx.epic['id'], slug: 'active-one', title: 'Active One')
    store.create_story(epic_id: other_epic['id'], slug: 'other-one', title: 'Other One')
  end

  it "lists the named epic's stories rather than the active epic's" do
    out, = capture_io { Tyrion::Commands.cmd_list(['other-epic'], store) }
    expect(out).to include('other-one')
    expect(out).not_to include('active-one')
  end

  it 'with no argument still lists the active epic' do
    out, = capture_io { Tyrion::Commands.cmd_list([], store) }
    expect(out).to include('active-one')
    expect(out).not_to include('other-one')
  end

  it '--status filter still works alongside a named epic' do
    store.create_story(epic_id: other_epic['id'], slug: 'other-two', title: 'Other Two')
    out, = capture_io { Tyrion::Commands.cmd_list(['other-epic', '--status', 'pending'], store) }
    expect(out).to include('other-one').and include('other-two')
  end

  it 'exits 1 naming the slug for an unknown epic' do
    expect { Tyrion::Commands.cmd_list(['no-such-epic'], store) }
      .to raise_error(SystemExit)
      .and output(/no-such-epic/).to_stderr
  end
end
