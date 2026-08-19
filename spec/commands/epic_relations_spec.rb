# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'tyrion epic parent / depends / waves' do
  let(:ctx) do
    tyrion_worktree(
      project_slug: 'relproj',
      git_branch:   'feature/epic-relations'
    )
  end
  let(:store)   { ctx.store }
  let(:project) { ctx.project }

  def make_epic(slug:, name: slug)
    store.create_epic(project_id: project['id'], slug: slug, name: name)
  end

  describe 'cmd_epic parent' do
    it 'sets the containing epic and prints confirmation' do
      make_epic(slug: 'parent-epic')
      child = make_epic(slug: 'child-epic')
      expect {
        Tyrion::Commands.cmd_epic(['parent', 'child-epic', 'parent-epic'], store)
      }.to output(/child-epic.*parent-epic|parent-epic.*child-epic/).to_stdout

      refreshed = store.find_epic_by_id(child['id'])
      parent    = store.find_epic(project['id'], 'parent-epic')
      expect(refreshed['parent_epic_id']).to eq parent['id']
    end

    it 'clears the containing epic with --none' do
      make_epic(slug: 'parent-epic')
      child = make_epic(slug: 'child-epic')
      Tyrion::Commands.cmd_epic(['parent', 'child-epic', 'parent-epic'], store)
      Tyrion::Commands.cmd_epic(['parent', 'child-epic', '--none'], store)
      refreshed = store.find_epic_by_id(child['id'])
      expect(refreshed['parent_epic_id']).to be_nil
    end

    it 'dies when the epic slug does not exist' do
      make_epic(slug: 'parent-epic')
      expect {
        Tyrion::Commands.cmd_epic(['parent', 'nope', 'parent-epic'], store)
      }.to raise_error(SystemExit).and output(/Epic not found: nope/).to_stderr
    end

    it 'dies when the parent slug does not exist' do
      make_epic(slug: 'child-epic')
      expect {
        Tyrion::Commands.cmd_epic(['parent', 'child-epic', 'nope'], store)
      }.to raise_error(SystemExit).and output(/Epic not found: nope/).to_stderr
    end

    it 'dies on self-parenting via the raised store message' do
      make_epic(slug: 'a')
      expect {
        Tyrion::Commands.cmd_epic(['parent', 'a', 'a'], store)
      }.to raise_error(SystemExit).and output(/own parent/).to_stderr
    end

    it 'dies on a containment cycle via the raised store message' do
      make_epic(slug: 'parent-epic')
      make_epic(slug: 'child-epic')
      Tyrion::Commands.cmd_epic(['parent', 'child-epic', 'parent-epic'], store)
      expect {
        Tyrion::Commands.cmd_epic(['parent', 'parent-epic', 'child-epic'], store)
      }.to raise_error(SystemExit).and output(/descendant/).to_stderr
    end
  end

  describe 'cmd_epic depends add/rm' do
    before do
      make_epic(slug: 'alpha')
      make_epic(slug: 'beta')
    end

    it 'adds an epic dependency and prints confirmation' do
      expect {
        Tyrion::Commands.cmd_epic(['depends', 'add', 'beta', 'alpha'], store)
      }.to output(/beta now depends on alpha/).to_stdout

      beta = store.find_epic(project['id'], 'beta')
      expect(JSON.parse(beta['depends_on'])).to include('alpha')
    end

    it 'is idempotent — adding the same dep twice prints the no-op message' do
      Tyrion::Commands.cmd_epic(['depends', 'add', 'beta', 'alpha'], store)
      expect {
        Tyrion::Commands.cmd_epic(['depends', 'add', 'beta', 'alpha'], store)
      }.to output(/beta already depends on alpha/).to_stdout
      beta = store.find_epic(project['id'], 'beta')
      expect(JSON.parse(beta['depends_on'])).to eq ['alpha']
    end

    it 'dies when the epic slug does not exist' do
      expect {
        Tyrion::Commands.cmd_epic(['depends', 'add', 'nope', 'alpha'], store)
      }.to raise_error(SystemExit).and output(/Epic not found: nope/).to_stderr
    end

    it 'dies on self-dependency via the raised store message' do
      expect {
        Tyrion::Commands.cmd_epic(['depends', 'add', 'alpha', 'alpha'], store)
      }.to raise_error(SystemExit).and output(/cannot depend on itself/).to_stderr
    end

    it 'removes an epic dependency and prints confirmation' do
      Tyrion::Commands.cmd_epic(['depends', 'add', 'beta', 'alpha'], store)
      expect {
        Tyrion::Commands.cmd_epic(['depends', 'rm', 'beta', 'alpha'], store)
      }.to output(/beta no longer depends on alpha/).to_stdout

      beta = store.find_epic(project['id'], 'beta')
      expect(JSON.parse(beta['depends_on'] || '[]')).not_to include('alpha')
    end

    it 'is a no-op with its own message when the dep is not present' do
      expect {
        Tyrion::Commands.cmd_epic(['depends', 'rm', 'beta', 'gamma'], store)
      }.to output(/beta does not depend on gamma/).to_stdout
    end
  end

  describe 'cmd_epic waves' do
    def wave_line(out, n) = out.lines.find { |l| l.include?("Wave #{n}") }

    it 'shows a dependent epic in a later wave than its prerequisite' do
      make_epic(slug: 'alpha')
      make_epic(slug: 'beta')
      Tyrion::Commands.cmd_epic(['depends', 'add', 'beta', 'alpha'], store)
      out, = capture_io { Tyrion::Commands.cmd_epic(['waves'], store) }
      expect(wave_line(out, 1)).to include('alpha')
      expect(wave_line(out, 2)).to include('beta')
    end

    it 'excludes a sealed epic from the wave output' do
      done = make_epic(slug: 'done-epic')
      s = store.create_story(epic_id: done['id'], slug: 'done-story', title: 'done')
      store.complete_story(s['id'], 'done', force: true)
      store.seal_epic(done['id'])
      make_epic(slug: 'active-epic')
      out, = capture_io { Tyrion::Commands.cmd_epic(['waves'], store) }
      expect(out).not_to include('done-epic')
      expect(out).to include('active-epic')
    end

    it 'renders a Cycle: line when circular dependencies exist' do
      # add_epic_dependency refuses any edge that would create a cycle, so
      # residue can only exist via a hand-edited DB.
      p_epic = make_epic(slug: 'p')
      q_epic = make_epic(slug: 'q')
      store.send(:with_db) do |db|
        db.execute('UPDATE epics SET depends_on = ? WHERE id = ?', [JSON.dump(['q']), p_epic['id']])
        db.execute('UPDATE epics SET depends_on = ? WHERE id = ?', [JSON.dump(['p']), q_epic['id']])
      end
      out, = capture_io { Tyrion::Commands.cmd_epic(['waves'], store) }
      cycle_line = out.lines.find { |l| l.include?('Cycle') }
      expect(cycle_line).to include('p')
      expect(cycle_line).to include('q')
    end

    it 'prints a dimmed message when there are no runnable epics' do
      done = make_epic(slug: 'done-epic')
      s = store.create_story(epic_id: done['id'], slug: 'done-story', title: 'done')
      store.complete_story(s['id'], 'done', force: true)
      store.seal_epic(done['id'])
      expect {
        Tyrion::Commands.cmd_epic(['waves'], store)
      }.to output(/No runnable epics/).to_stdout
    end
  end
end
