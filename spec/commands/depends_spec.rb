# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'tyrion depends / wave show' do
  let(:ctx) do
    tyrion_worktree(
      project_slug: 'depsproj',
      epic_slug:    'deps-epic',
      git_branch:   'feature/depends-on'
    )
  end
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  def make_story(slug:, title: slug)
    store.create_story(epic_id: epic['id'], slug: slug, title: title)
    store.find_story(epic['id'], slug)
  end

  describe 'migration' do
    it 'adds depends_on column (NULL by default)' do
      story = make_story(slug: 'alpha')
      expect(story.key?('depends_on')).to be true
      expect(story['depends_on']).to be_nil
    end

    it 'is idempotent — second Store.new does not raise' do
      db_path = File.join(ctx.tmpdir, 'test.db')
      expect { Tyrion::Store.new(db_path: db_path) }.not_to raise_error
    end
  end

  describe 'store.update_story_depends_on' do
    it 'stores a JSON array of dep slugs' do
      story = make_story(slug: 'beta')
      store.update_story_depends_on(story['id'], ['alpha'])
      refreshed = store.find_story(epic['id'], 'beta')
      expect(JSON.parse(refreshed['depends_on'])).to eq ['alpha']
    end

    it 'stores NULL when array is empty' do
      story = make_story(slug: 'gamma')
      store.update_story_depends_on(story['id'], ['alpha'])
      store.update_story_depends_on(story['id'], [])
      refreshed = store.find_story(epic['id'], 'gamma')
      expect(refreshed['depends_on']).to be_nil
    end
  end

  describe 'cmd_depends_add' do
    before do
      make_story(slug: 'alpha')
      make_story(slug: 'beta')
    end

    it 'adds dep and prints confirmation' do
      expect {
        Tyrion::Commands.cmd_depends_add(['beta', 'alpha'], store)
      }.to output(/beta now depends on alpha/).to_stdout

      beta = store.find_story(epic['id'], 'beta')
      expect(JSON.parse(beta['depends_on'])).to include('alpha')
    end

    it 'is idempotent — adding same dep twice does not duplicate' do
      Tyrion::Commands.cmd_depends_add(['beta', 'alpha'], store)
      Tyrion::Commands.cmd_depends_add(['beta', 'alpha'], store)
      beta = store.find_story(epic['id'], 'beta')
      expect(JSON.parse(beta['depends_on'])).to eq ['alpha']
    end

    it 'dies when the story slug does not exist' do
      expect {
        Tyrion::Commands.cmd_depends_add(['nope', 'alpha'], store)
      }.to raise_error(SystemExit).and output(/Story not found: nope/).to_stderr
    end

    it 'dies when the dep slug does not exist' do
      expect {
        Tyrion::Commands.cmd_depends_add(['alpha', 'nope'], store)
      }.to raise_error(SystemExit).and output(/Story not found: nope/).to_stderr
    end

    it 'dies on self-dependency' do
      expect {
        Tyrion::Commands.cmd_depends_add(['alpha', 'alpha'], store)
      }.to raise_error(SystemExit).and output(/alpha cannot depend on itself/).to_stderr
    end
  end

  describe 'cmd_depends_rm' do
    before do
      make_story(slug: 'alpha')
      make_story(slug: 'beta')
      Tyrion::Commands.cmd_depends_add(['beta', 'alpha'], store)
    end

    it 'removes dep and prints confirmation' do
      expect {
        Tyrion::Commands.cmd_depends_rm(['beta', 'alpha'], store)
      }.to output(/beta no longer depends on alpha/).to_stdout

      beta = store.find_story(epic['id'], 'beta')
      expect(JSON.parse(beta['depends_on'] || '[]')).not_to include('alpha')
    end

    it 'is a no-op when dep not present' do
      expect {
        Tyrion::Commands.cmd_depends_rm(['beta', 'gamma'], store)
      }.to output(/does not depend on gamma/).to_stdout
    end

    it 'dies when story slug does not exist' do
      expect {
        Tyrion::Commands.cmd_depends_rm(['nope', 'alpha'], store)
      }.to raise_error(SystemExit).and output(/Story not found: nope/).to_stderr
    end
  end

  describe 'store.wave_plan' do
    it 'assigns all stories to wave 1 when there are no dependencies' do
      make_story(slug: 'alpha')
      make_story(slug: 'beta')
      waves = store.wave_plan(epic['id'])
      expect(waves[1]).to include('alpha', 'beta')
      expect(waves.size).to eq 1
    end

    it 'places dependent in a later wave than its prerequisite' do
      make_story(slug: 'alpha')
      make_story(slug: 'beta')
      store.update_story_depends_on(
        store.find_story(epic['id'], 'beta')['id'], ['alpha']
      )
      waves = store.wave_plan(epic['id'])
      expect(waves[1]).to include('alpha')
      expect(waves[2]).to include('beta')
    end

    it 'handles a chain A→B→C across three waves' do
      make_story(slug: 'a')
      make_story(slug: 'b')
      make_story(slug: 'c')
      store.update_story_depends_on(store.find_story(epic['id'], 'b')['id'], ['a'])
      store.update_story_depends_on(store.find_story(epic['id'], 'c')['id'], ['b'])
      waves = store.wave_plan(epic['id'])
      expect(waves[1]).to eq ['a']
      expect(waves[2]).to eq ['b']
      expect(waves[3]).to eq ['c']
    end

    it 'recomputes immediately after removing a dependency' do
      make_story(slug: 'alpha')
      make_story(slug: 'beta')
      beta = store.find_story(epic['id'], 'beta')
      store.update_story_depends_on(beta['id'], ['alpha'])
      expect(store.wave_plan(epic['id'])[2]).to include('beta')

      store.update_story_depends_on(beta['id'], [])
      expect(store.wave_plan(epic['id'])[1]).to include('beta')
    end

    it 'surfaces cyclic stories under :cycle key' do
      make_story(slug: 'x')
      make_story(slug: 'y')
      store.update_story_depends_on(store.find_story(epic['id'], 'x')['id'], ['y'])
      store.update_story_depends_on(store.find_story(epic['id'], 'y')['id'], ['x'])
      waves = store.wave_plan(epic['id'])
      expect(waves[:cycle]).to include('x', 'y')
      expect(waves.keys.reject { |k| k == :cycle }).to be_empty
    end

    it 'includes stories downstream of a cycle in :cycle (they can never be assigned a wave)' do
      make_story(slug: 'x')
      make_story(slug: 'y')
      make_story(slug: 'z')
      store.update_story_depends_on(store.find_story(epic['id'], 'x')['id'], ['y'])
      store.update_story_depends_on(store.find_story(epic['id'], 'y')['id'], ['x'])
      store.update_story_depends_on(store.find_story(epic['id'], 'z')['id'], ['y'])
      waves = store.wave_plan(epic['id'])
      expect(waves[:cycle]).to include('x', 'y', 'z')
    end
  end

  describe 'cmd_wave_show' do
    def wave_line(out, n) = out.lines.find { |l| l.include?("Wave #{n}") }

    before do
      make_story(slug: 'alpha')
      make_story(slug: 'beta')
      store.update_story_depends_on(
        store.find_story(epic['id'], 'beta')['id'], ['alpha']
      )
    end

    it 'shows dependent in a later wave than its prerequisite' do
      out, = capture_io { Tyrion::Commands.cmd_wave_show([], store) }
      expect(wave_line(out, 1)).to include('alpha')
      expect(wave_line(out, 2)).to include('beta')
    end

    it 'shows three-wave chain as Wave 1/2/3 with correct slugs' do
      make_story(slug: 'a')
      make_story(slug: 'b')
      make_story(slug: 'c')
      store.update_story_depends_on(store.find_story(epic['id'], 'b')['id'], ['a'])
      store.update_story_depends_on(store.find_story(epic['id'], 'c')['id'], ['b'])
      out, = capture_io { Tyrion::Commands.cmd_wave_show([], store) }
      expect(wave_line(out, 1)).to include('a')
      expect(wave_line(out, 2)).to include('b')
      expect(wave_line(out, 3)).to include('c')
    end

    it 'immediately shows C unblocked to wave 1 when its dependency on B is removed' do
      make_story(slug: 'a')
      make_story(slug: 'b')
      make_story(slug: 'c')
      store.update_story_depends_on(store.find_story(epic['id'], 'b')['id'], ['a'])
      store.update_story_depends_on(store.find_story(epic['id'], 'c')['id'], ['b'])
      Tyrion::Commands.cmd_depends_rm(['c', 'b'], store)
      out, = capture_io { Tyrion::Commands.cmd_wave_show([], store) }
      expect(wave_line(out, 1)).to include('a')
      expect(wave_line(out, 1)).to include('c')
      expect(wave_line(out, 2)).to include('b')
      expect(out).not_to include('Wave 3')
    end

    it 'renders a Cycle: line when circular dependencies exist' do
      make_story(slug: 'p')
      make_story(slug: 'q')
      store.update_story_depends_on(store.find_story(epic['id'], 'p')['id'], ['q'])
      store.update_story_depends_on(store.find_story(epic['id'], 'q')['id'], ['p'])
      out, = capture_io { Tyrion::Commands.cmd_wave_show([], store) }
      cycle_line = out.lines.find { |l| l.include?('Cycle') }
      expect(cycle_line).to include('p')
      expect(cycle_line).to include('q')
    end
  end
end
