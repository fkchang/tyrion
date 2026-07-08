# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'wave_override — tyrion wave set' do
  let(:ctx) do
    tyrion_worktree(
      project_slug: 'woproj',
      epic_slug:    'wo-epic',
      git_branch:   'feature/wave-override'
    )
  end
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  def make_story(slug:)
    store.create_story(epic_id: epic['id'], slug: slug, title: slug)
    store.find_story(epic['id'], slug)
  end

  describe 'migration' do
    it 'adds wave_override column (NULL by default)' do
      story = make_story(slug: 'alpha')
      expect(story.key?('wave_override')).to be true
      expect(story['wave_override']).to be_nil
    end

    it 'adds wave_rationale column (NULL by default)' do
      story = make_story(slug: 'alpha')
      expect(story.key?('wave_rationale')).to be true
      expect(story['wave_rationale']).to be_nil
    end

    it 'is idempotent — second Store.new does not raise' do
      db_path = File.join(ctx.tmpdir, 'test.db')
      expect { Tyrion::Store.new(db_path: db_path) }.not_to raise_error
    end
  end

  describe 'store.find_story wave_source' do
    it 'returns wave_source "inferred" when no override set' do
      story = make_story(slug: 'web-note-expand')
      expect(story['wave_source']).to eq 'inferred'
    end

    it 'returns wave_source "user" after set_wave_override' do
      story = make_story(slug: 'web-note-expand')
      store.set_wave_override(story['id'], 2)
      refreshed = store.find_story(epic['id'], 'web-note-expand')
      expect(refreshed['wave_source']).to eq 'user'
    end
  end

  describe 'store.set_wave_override' do
    it 'sets wave_override on the story; wave_rationale nil when no rationale given' do
      story = make_story(slug: 'web-note-expand')
      store.set_wave_override(story['id'], 2)
      refreshed = store.find_story(epic['id'], 'web-note-expand')
      expect(refreshed['wave_override']).to eq 2
      expect(refreshed['wave_rationale']).to be_nil
    end

    it 'stores the rationale when provided' do
      story = make_story(slug: 'web-note-expand')
      store.set_wave_override(story['id'], 2, 'must run after deploy gate')
      refreshed = store.find_story(epic['id'], 'web-note-expand')
      expect(refreshed['wave_rationale']).to eq 'must run after deploy gate'
    end

    it 'leaves depends_on unchanged' do
      story = make_story(slug: 'web-note-expand')
      store.set_wave_override(story['id'], 2)
      refreshed = store.find_story(epic['id'], 'web-note-expand')
      expect(refreshed['depends_on']).to be_nil
    end
  end

  describe 'store.wave_plan with override' do
    it 'moves an override story to the specified wave' do
      make_story(slug: 'web-note-expand')
      make_story(slug: 'other')
      story = store.find_story(epic['id'], 'web-note-expand')
      expect(store.wave_plan(epic['id'])[1]).to include('web-note-expand')

      store.set_wave_override(story['id'], 2)
      waves = store.wave_plan(epic['id'])
      expect(waves[1]).not_to include('web-note-expand')
      expect(waves[2]).to include('web-note-expand')
    end

    it 'preserves depends_on of other stories when applying an override' do
      make_story(slug: 'alpha')
      make_story(slug: 'beta')
      beta = store.find_story(epic['id'], 'beta')
      store.update_story_depends_on(beta['id'], ['alpha'])
      store.set_wave_override(beta['id'], 3)

      waves = store.wave_plan(epic['id'])
      expect(waves[1]).to include('alpha')
      expect(waves[3]).to include('beta')
      expect(waves[2]).to be_nil
    end
  end

  describe 'cmd_wave_set' do
    it 'pins story to specified wave and prints confirmation' do
      make_story(slug: 'web-note-expand')
      expect {
        Tyrion::Commands.cmd_wave_set(['web-note-expand', '2'], store)
      }.to output(/web-note-expand.*wave 2|wave 2.*web-note-expand/i).to_stdout
    end

    it 'wave show reflects the override' do
      make_story(slug: 'web-note-expand')
      make_story(slug: 'other')
      Tyrion::Commands.cmd_wave_set(['web-note-expand', '2'], store)
      out, = capture_io { Tyrion::Commands.cmd_wave_show([], store) }
      wave2_line = out.lines.find { |l| l.include?('Wave 2') }
      expect(wave2_line).not_to be_nil
      expect(wave2_line).to include('web-note-expand')
    end

    it 'errors on missing slug' do
      expect { Tyrion::Commands.cmd_wave_set([], store) }.to raise_error(SystemExit)
        .and output(/Usage/).to_stderr
    end

    it 'errors on non-positive wave number' do
      make_story(slug: 'web-note-expand')
      expect { Tyrion::Commands.cmd_wave_set(['web-note-expand', '0'], store) }.to raise_error(SystemExit)
        .and output(/positive integer/).to_stderr
    end

    it 'errors on unknown story' do
      expect { Tyrion::Commands.cmd_wave_set(['no-such-story', '2'], store) }.to raise_error(SystemExit)
        .and output(/not found/).to_stderr
    end

    it 'refuses to override a story in a dependency cycle' do
      make_story(slug: 'x')
      make_story(slug: 'y')
      x = store.find_story(epic['id'], 'x')
      y = store.find_story(epic['id'], 'y')
      store.update_story_depends_on(x['id'], ['y'])
      store.update_story_depends_on(y['id'], ['x'])
      expect { Tyrion::Commands.cmd_wave_set(['x', '2'], store) }.to raise_error(SystemExit)
        .and output(/cycle/).to_stderr
    end

    it 'accepts optional rationale as third argument' do
      make_story(slug: 'web-note-expand')
      Tyrion::Commands.cmd_wave_set(['web-note-expand', '2', 'deploy gate first'], store)
      refreshed = store.find_story(epic['id'], 'web-note-expand')
      expect(refreshed['wave_rationale']).to eq 'deploy gate first'
    end
  end
end
