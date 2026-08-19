# frozen_string_literal: true

require 'spec_helper'

# Specs for epic-tree-and-waiting: pure rendering over the epic_graph/
# unmet_prereqs primitives shipped by epic-graph-schema, epic-relations-cli,
# and epic-eligibility-routing. No new Store logic is exercised here beyond
# what those stories already cover in store_spec.rb.

RSpec.describe 'epic tree and waiting display' do
  let(:ctx)     { tyrion_worktree(epic_slug: 'root', project_slug: 'treeproj') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:root)    { ctx.epic } # slug: 'root'

  def make_epic(slug:, name: slug)
    store.create_epic(project_id: project['id'], slug: slug, name: name)
  end

  def seal!(epic)
    s = store.create_story(epic_id: epic['id'], slug: "#{epic['slug']}-s", title: 's')
    store.complete_story(s['id'], 'done', force: true)
    store.seal_epic(epic['id'])
  end

  # ── tyrion epic list ─────────────────────────────────────────────────────
  describe 'cmd_epic_list' do
    it 'indents a child epic under its parent' do
      child = make_epic(slug: 'child')
      store.set_epic_parent(child['id'], root['id'])

      out, = capture_io { Tyrion::Commands.cmd_epic_list([], store) }
      lines = out.lines
      root_line  = lines.find { |l| l.include?('root  ') }
      child_line = lines.find { |l| l.include?('child  ') }
      expect(root_line).not_to be_nil
      expect(child_line).not_to be_nil
      # child is indented further than its parent
      expect(child_line[/^\s*/].length).to be > root_line[/^\s*/].length
    end

    it 'appends a waiting suffix naming the unmet prerequisite and reason' do
      prereq = make_epic(slug: 'prereq')
      dependent = make_epic(slug: 'dependent')
      store.add_epic_dependency(dependent['id'], 'prereq')
      store.update_epic(prereq['id'], 'status' => 'abandoned')

      out, = capture_io { Tyrion::Commands.cmd_epic_list([], store) }
      dep_line = out.lines.find { |l| l.include?('dependent  ') }
      expect(dep_line).to match(/waiting — requires: prereq \(abandoned — will never unblock\)/)
    end

    it 'prints no waiting suffix once the prerequisite is sealed' do
      prereq = make_epic(slug: 'prereq')
      dependent = make_epic(slug: 'dependent')
      store.add_epic_dependency(dependent['id'], 'prereq')
      seal!(prereq)

      out, = capture_io { Tyrion::Commands.cmd_epic_list([], store) }
      dep_line = out.lines.find { |l| l.include?('dependent  ') }
      expect(dep_line).not_to include('waiting')
    end

    it 'shows derived n/m sealed counts on a container epic instead of its own story count' do
      child = make_epic(slug: 'child')
      store.set_epic_parent(child['id'], root['id'])
      seal!(child)

      out, = capture_io { Tyrion::Commands.cmd_epic_list([], store) }
      root_line = out.lines.find { |l| l.include?('root  ') }
      # root itself is 2 nodes (self + sealed child) — its own stories, not
      # counted here, are 0/0, so a bare story fraction would misleadingly
      # read as "done" — the derived "1/2 sealed" is what a container shows.
      expect(root_line).to match(%r{1/2 sealed})
    end

    it 'renders an archived parent\'s active child in the active section with a parent-archived note' do
      parent = make_epic(slug: 'parent')
      child  = make_epic(slug: 'child')
      store.set_epic_parent(child['id'], parent['id'])
      store.archive_epic(parent['id'])

      out, = capture_io { Tyrion::Commands.cmd_epic_list([], store) }
      active_section = out.split("\nArchived:").first
      expect(active_section).to include('child')
      expect(active_section).to match(/child.*\(parent archived\)/)

      archived_section = out.split("Archived:").last
      expect(archived_section).to include('parent')
      expect(archived_section).not_to include('child')
    end
  end

  # ── tyrion epic show ─────────────────────────────────────────────────────
  describe 'cmd_epic_show' do
    it 'prints Parent:, Requires:, and Children: lines after Status:' do
      parent = make_epic(slug: 'parent')
      child  = make_epic(slug: 'child')
      make_epic(slug: 'other-dep')
      store.set_epic_parent(child['id'], parent['id'])
      store.add_epic_dependency(child['id'], 'other-dep')

      out, = capture_io { Tyrion::Commands.cmd_epic_show(['child'], store) }
      expect(out).to match(/Status: active.*\nParent: parent/)
      expect(out).to match(/Requires: other-dep/)

      out2, = capture_io { Tyrion::Commands.cmd_epic_show(['parent'], store) }
      expect(out2).to match(/Children: child/)
    end

    it 'omits Parent:/Requires:/Children: lines when none apply' do
      make_epic(slug: 'lonely')
      out, = capture_io { Tyrion::Commands.cmd_epic_show(['lonely'], store) }
      expect(out).not_to match(/^Parent:/)
      expect(out).not_to match(/^Requires:/)
      expect(out).not_to match(/^Children:/)
    end
  end

  # ── tyrion status ────────────────────────────────────────────────────────
  describe 'cmd_status' do
    it 'shows a parent crumb on the Epic: line' do
      child = make_epic(slug: 'child')
      store.set_epic_parent(child['id'], root['id'])
      stub_repo(active_epic: 'child')

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to match(/Epic:.*root ›.*child \[child\]/)
    end

    it 'shows a waiting line when the active epic has an unmet prerequisite' do
      prereq = make_epic(slug: 'prereq')
      store.add_epic_dependency(root['id'], 'prereq')

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }
      expect(out).to match(/waiting on: prereq/)
    end
  end

  # ── tyrion resume ────────────────────────────────────────────────────────
  describe 'cmd_resume' do
    before do
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
    end

    it 'marks a waiting sibling epic in the Open: line' do
      store.create_story(epic_id: root['id'], slug: 'a', title: 'a')
      store.start_story(store.find_story(root['id'], 'a')['id'])

      prereq   = make_epic(slug: 'prereq')
      sibling  = make_epic(slug: 'sibling')
      store.create_story(epic_id: sibling['id'], slug: 'b', title: 'b')
      store.add_epic_dependency(sibling['id'], 'prereq')

      out, = capture_io { Tyrion::Commands.cmd_resume([], store) }
      open_line = out.lines.find { |l| l.include?('Open:') }
      expect(open_line).to match(/sibling \(1\).*waiting/)
    end
  end

  # ── tyrion prime ─────────────────────────────────────────────────────────
  describe 'cmd_prime' do
    before do
      ENV['TYRION_DB_PATH'] = File.join(ctx.tmpdir, 'test.db')
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
    end
    after { ENV.delete('TYRION_DB_PATH') }

    it 'carries the parent crumb in Tier 1 (no story claimed)' do
      child = make_epic(slug: 'child')
      store.set_epic_parent(child['id'], root['id'])
      stub_repo(active_epic: 'child')

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/epic: root › child/)
    end

    it 'carries the parent crumb in Tier 2 (story claimed)' do
      child = make_epic(slug: 'child')
      store.set_epic_parent(child['id'], root['id'])
      story = store.create_story(epic_id: child['id'], slug: 'a', title: 'a')
      store.start_story(story['id'])
      stub_repo(active_epic: 'child')

      out, = capture_io { Tyrion::Commands.cmd_prime([]) }
      expect(out).to match(/epic: root › child/)
    end
  end

  # ── tyrion project show ──────────────────────────────────────────────────
  describe 'cmd_project_show' do
    it 'renders tree indent for a child epic' do
      child = make_epic(slug: 'child')
      store.set_epic_parent(child['id'], root['id'])

      out, = capture_io { Tyrion::Commands.cmd_project_show([], store) }
      lines = out.lines
      root_line  = lines.find { |l| l.include?('root  ') }
      child_line = lines.find { |l| l.include?('child  ') }
      expect(child_line[/^\s*/].length).to be > root_line[/^\s*/].length
    end

    it 'filters archived epics out of the epic list' do
      archived = make_epic(slug: 'gone')
      store.archive_epic(archived['id'])

      out, = capture_io { Tyrion::Commands.cmd_project_show([], store) }
      expect(out).not_to include('gone')
    end
  end
end
