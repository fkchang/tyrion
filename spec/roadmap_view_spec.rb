# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
Dir.glob(File.expand_path('../web/lib/tyrion_web/*.rb', __dir__)).sort.each { |f| require f }
Dir.glob(File.expand_path('../web/views/*.rb', __dir__)).sort.each { |f| require f }

# web-epic-tree, criterion 6: Views::Roadmap#render_epic nests children under
# parents, sorting root epics by attention weight and children by sequence
# (their existing order) within their parent.
RSpec.describe Views::RoadmapView do
  def epic(id, slug, parent_epic_id: nil, child_stats: nil, unmet: [], archived_at: nil)
    { 'id' => id, 'slug' => slug, 'parent_epic_id' => parent_epic_id, 'status' => 'active',
      'archived_at' => archived_at, 'unmet' => unmet, 'child_stats' => child_stats }
  end

  # pivot is a container (child_stats present, no own stories) with two
  # leaf children; blocked_epic is an unrelated root. Children are inserted
  # in an order whose own attention weight is the OPPOSITE of insertion
  # order (child1 :active/weight4 first, child2 :ready/weight1 second) so a
  # buggy global re-sort of children would be caught: it would put child2
  # first, and would even put child2 ahead of blocked_epic.
  let(:pivot)   { epic('p', 'pivot-epic', child_stats: { done: 1, total: 3 }) }
  let(:child1)  { epic('c1', 'child-active', parent_epic_id: 'p') }
  let(:child2)  { epic('c2', 'child-ready',  parent_epic_id: 'p') }
  let(:blocked_epic) { epic('b', 'blocked-epic') }
  let(:active_epics) { [pivot, child1, child2, blocked_epic] }

  # The real epic_graph shape (see Store#build_epic_graph) -- sorted_active_epics
  # delegates the actual tree walk to Store.epic_tree_order, so it needs one.
  let(:graph) do
    by_id = active_epics.to_h { |e| [e['id'], e] }
    {
      epics: by_id, by_slug: active_epics.to_h { |e| [e['slug'], e] },
      children: { 'p' => %w[c1 c2], 'c1' => [], 'c2' => [], 'b' => [] },
      depends_on: by_id.transform_values { [] }, story_counts: {}
    }
  end

  let(:stories_by_epic) do
    {
      'p'  => [],
      'c1' => [{ 'status' => 'in_progress', 'last_note_at' => Time.now.iso8601 }],
      'c2' => [{ 'status' => 'done' }],
      'b'  => [{ 'status' => 'blocked' }, { 'status' => 'pending' }]
    }
  end

  let(:view) do
    described_class.new(
      project: { 'id' => 'proj', 'name' => 'Proj' },
      active_epics: active_epics,
      archived_epics: [],
      active_epic: nil, active_story: nil,
      stories_by_epic: stories_by_epic, criteria: [], graph: graph,
      sidebar_stories: [], disc_summary: {}
    )
  end

  describe '#sorted_active_epics (private)' do
    subject(:sorted) { view.send(:sorted_active_epics) }

    it 'sorts root epics by attention weight' do
      root_slugs = sorted.select { |_, depth, _| depth.zero? }.map { |e, _, _| e['slug'] }
      # blocked (:blocked, weight 2) outranks pivot (:container, weight 9)
      expect(root_slugs).to eq %w[blocked-epic pivot-epic]
    end

    it 'nests children directly under their parent, in original order -- not globally re-sorted' do
      slugs_with_depth = sorted.map { |e, depth, _| [e['slug'], depth] }
      expect(slugs_with_depth).to eq [
        ['blocked-epic',  0],
        ['pivot-epic',    0],
        ['child-active',  1],
        ['child-ready',   1]
      ]
    end
  end

  describe 'rendering' do
    it 'renders without error and reflects the container/nesting decisions in the HTML' do
      html = view.call
      expect(html).to include('rm-seal pivot')   # :container color
      expect(html).to include('rm-epic-child')   # nested children
      expect(html).to include('container · 1/3 sealed')
    end
  end

  describe 'archived epics also nest, via the same Store.epic_tree_order call' do
    let(:archived_parent) { epic('ap', 'archived-parent', archived_at: '2026-01-01') }
    let(:archived_child)  { epic('ac', 'archived-child', parent_epic_id: 'ap', archived_at: '2026-01-01') }
    let(:archived_epics)  { [archived_parent, archived_child] }
    let(:archived_graph) do
      by_id = archived_epics.to_h { |e| [e['id'], e] }
      { epics: by_id, by_slug: {}, children: { 'ap' => ['ac'], 'ac' => [] },
        depends_on: {}, story_counts: {} }
    end

    let(:archived_view) do
      described_class.new(
        project: { 'id' => 'proj', 'name' => 'Proj' },
        active_epics: [], archived_epics: archived_epics,
        active_epic: nil, active_story: nil,
        stories_by_epic: {}, criteria: [], graph: archived_graph,
        sidebar_stories: [], disc_summary: {}
      )
    end

    it 'nests the archived child under the archived parent' do
      html = archived_view.call
      section = html[/rm-archived-list.*?<\/details>/m]
      expect(section).to include('rm-epic-child')
      expect(section.index('archived-parent')).to be < section.index('archived-child')
    end
  end
end
