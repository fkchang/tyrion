# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Known: section in tyrion resume' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }

  let(:story) do
    s = store.create_story(epic_id: ctx.epic['id'], slug: 'my-story', title: 'My Story', sequence: 1)
    store.start_story(s['id'])
    store.find_story(ctx.epic['id'], 'my-story')
  end

  before { story }

  def mark(question, epic_id: nil)
    store.create_discovery(project_id: ctx.project['id'], status: 'mark',
                           question: question, epic_id: epic_id)
  end

  def finding(question, finding, epic_id: nil)
    store.create_discovery(project_id: ctx.project['id'], status: 'findings_ready',
                           question: question, finding: finding, epic_id: epic_id)
  end

  def resume_output
    out, = capture_io { Tyrion::Commands.cmd_resume(['my-story'], store) }
    out
  end

  it 'omits the section entirely when there are no open discoveries' do
    expect(resume_output).not_to match(/Known:/)
  end

  it 'omits the section when every discovery is already resolved' do
    store.create_discovery(project_id: ctx.project['id'], status: 'promoted_to_story', question: 'done one')
    store.create_discovery(project_id: ctx.project['id'], status: 'deferred', question: 'later one')

    expect(resume_output).not_to match(/Known:/)
  end

  it "shows a mark's id and question text" do
    d = mark('why is import slow')

    out = resume_output
    expect(out).to match(/Known:/)
    expect(out).to include("#{d['id']}  why is import slow")
  end

  it "shows a findings_ready discovery's finding text plus its promote command" do
    d = finding('does WAL help', 'WAL cut import time in half')

    out = resume_output
    expect(out).to include("#{d['id']}  WAL cut import time in half")
    expect(out).to match(/tyrion spike promote #{d['id']}/)
  end

  it 'orders open discoveries newest-created-first' do
    first  = mark('oldest question')
    second = mark('newest question')

    out = resume_output
    expect(out.index(second['id'])).to be < out.index(first['id'])
  end

  it 'is scoped to the whole project, not the active epic or story' do
    other_epic = store.create_epic(project_id: ctx.project['id'], slug: 'other-epic', name: 'Other Epic')
    d = mark('captured in another epic', epic_id: other_epic['id'])

    expect(resume_output).to include(d['id'])
  end

  it 'caps at 5 and reports the overflow count' do
    ids = 7.times.map { |i| mark("question #{i}")['id'] }

    out = resume_output
    # newest 5 shown, the two oldest omitted
    ids.last(5).each { |id| expect(out).to include(id) }
    ids.first(2).each { |id| expect(out).not_to include(id) }
    expect(out).to match(/\(2 more — tyrion discovery list --status all\)/)
  end

  it 'omits the overflow line at exactly 5 open discoveries' do
    5.times { |i| mark("question #{i}") }

    expect(resume_output).not_to match(/more — tyrion discovery list/)
  end

  it 'prints Known: after the Lessons block' do
    store.create_lesson(project_id: ctx.project['id'], trigger: 'uat', text: 'watch for flaky uploads')
    mark('why is import slow')

    out = resume_output
    expect(out.index('Lessons:')).to be < out.index('Known:')
  end
end
