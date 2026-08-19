# frozen_string_literal: true

require 'spec_helper'
require_relative '../web/lib/tyrion_web/data'

# ambient-route-and-view, criteria 4/5/7: project fallback, newest-3 marks,
# findings_ready count independent of the marks list.
RSpec.describe 'TyrionWeb::Data.load_ambient_view' do
  let(:ctx)     { tyrion_worktree(project_slug: 'am-proj', project_name: 'Ambient Test') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }

  before do
    TyrionWeb::Data.instance_variable_set(:@store, store)
    allow(TyrionWeb::Data).to receive(:resolve_active_project).and_return(project)
  end

  after { TyrionWeb::Data.instance_variable_set(:@store, nil) }

  def mark(question)
    store.create_discovery(project_id: project['id'], question: question, status: 'mark')
  end

  describe 'project resolution' do
    it 'uses the named project when the slug is known' do
      expect(TyrionWeb::Data.load_ambient_view(project_slug: 'am-proj')[:project]['slug']).to eq 'am-proj'
    end

    it 'falls back to the resolved active project for an unknown slug' do
      expect(TyrionWeb::Data.load_ambient_view(project_slug: 'nope')[:project]['slug']).to eq 'am-proj'
    end

    it 'falls back to the resolved active project when no slug is given' do
      expect(TyrionWeb::Data.load_ambient_view[:project]['slug']).to eq 'am-proj'
    end

    it 'returns a no-project result when nothing resolves' do
      allow(TyrionWeb::Data).to receive(:resolve_active_project).and_return(nil)
      expect(TyrionWeb::Data.load_ambient_view(project_slug: 'nope'))
        .to eq(project: nil, marks: [], findings_ready_count: 0)
    end
  end

  describe 'marks' do
    it 'returns the newest 10 open marks by default, newest first' do
      12.times { |i| mark("mark #{i}") }
      questions = TyrionWeb::Data.load_ambient_view(project_slug: 'am-proj')[:marks].map { |m| m['question'] }
      expect(questions).to eq ['mark 11', 'mark 10', 'mark 9', 'mark 8', 'mark 7', 'mark 6', 'mark 5', 'mark 4', 'mark 3', 'mark 2']
    end

    it 'honours an explicit mark_limit' do
      5.times { |i| mark("mark #{i}") }
      questions = TyrionWeb::Data.load_ambient_view(project_slug: 'am-proj', mark_limit: 3)[:marks].map { |m| m['question'] }
      expect(questions).to eq ['mark 4', 'mark 3', 'mark 2']
    end

    it 'excludes discoveries that are not open marks' do
      mark('still open')
      store.create_discovery(project_id: project['id'], question: 'promoted', status: 'promoted_to_story')
      store.create_discovery(project_id: project['id'], question: 'deferred', status: 'deferred')

      expect(TyrionWeb::Data.load_ambient_view(project_slug: 'am-proj')[:marks].map { |m| m['question'] })
        .to eq ['still open']
    end
  end

  describe 'findings_ready count' do
    it 'counts findings_ready even when there are zero open marks' do
      2.times { |i| store.create_discovery(project_id: project['id'], question: "f#{i}", status: 'findings_ready') }

      d = TyrionWeb::Data.load_ambient_view(project_slug: 'am-proj')
      expect(d[:marks]).to be_empty
      expect(d[:findings_ready_count]).to eq 2
    end
  end
end
