# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'tempfile'

RSpec.describe 'drift warning in status and resume' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }

  STALE_HASH = Digest::SHA256.hexdigest('stale').freeze

  def set_feature_hash(store, project_id:, epic_slug:, feature_path:, feature_hash:)
    store.upsert_epic(
      project_id:          project_id,
      slug:                epic_slug,
      name:                epic_slug,
      feature_source_path: feature_path,
      feature_source_hash: feature_hash
    )
  end

  # Yields a Tempfile whose stored hash is stale (guaranteed to mismatch real content).
  def with_changed_epic
    Tempfile.create(['feat', '.feature']) do |f|
      f.write("Feature: test\n")
      f.flush
      set_feature_hash(store, project_id: ctx.project['id'], epic_slug: 'my-epic',
                              feature_path: f.path,
                              feature_hash: STALE_HASH)
      yield f
    end
  end

  context 'tyrion status' do
    it 'shows drift warning when the epic feature file has changed since import' do
      with_changed_epic do
        expect { Tyrion::Commands.cmd_status([], store) }
          .to output(/feature file changed since import - criteria may be stale/).to_stdout
      end
    end

    it 'includes the re-import command in the drift warning' do
      with_changed_epic do |f|
        expect { Tyrion::Commands.cmd_status([], store) }
          .to output(/tyrion import #{Regexp.escape(f.path)}/).to_stdout
      end
    end

    it 'shows no drift warning when feature file is up to date' do
      Tempfile.create(['feat', '.feature']) do |f|
        f.write("Feature: test\n")
        f.flush
        hash = Digest::SHA256.file(f.path).hexdigest
        set_feature_hash(store, project_id: ctx.project['id'], epic_slug: 'my-epic',
                                feature_path: f.path,
                                feature_hash: hash)

        expect { Tyrion::Commands.cmd_status([], store) }
          .not_to output(/feature file changed since import/).to_stdout
      end
    end

    it 'shows no drift warning when epic has no tracked feature file' do
      expect { Tyrion::Commands.cmd_status([], store) }
        .not_to output(/feature file changed since import/).to_stdout
    end
  end

  context 'tyrion resume' do
    let(:story) do
      s = store.create_story(epic_id: ctx.epic['id'], slug: 'my-story', title: 'My Story', sequence: 1)
      store.start_story(s['id'])
      store.find_story(ctx.epic['id'], 'my-story')
    end

    before { story }

    it 'shows drift warning when the epic feature file has changed since import' do
      with_changed_epic do
        expect { Tyrion::Commands.cmd_resume(['my-story'], store) }
          .to output(/feature file changed since import - criteria may be stale/).to_stdout
      end
    end

    it 'includes the re-import command in the drift warning' do
      with_changed_epic do |f|
        expect { Tyrion::Commands.cmd_resume(['my-story'], store) }
          .to output(/tyrion import #{Regexp.escape(f.path)}/).to_stdout
      end
    end

    it 'shows no drift warning when feature file is up to date' do
      Tempfile.create(['feat', '.feature']) do |f|
        f.write("Feature: test\n")
        f.flush
        hash = Digest::SHA256.file(f.path).hexdigest
        set_feature_hash(store, project_id: ctx.project['id'], epic_slug: 'my-epic',
                                feature_path: f.path,
                                feature_hash: hash)

        expect { Tyrion::Commands.cmd_resume(['my-story'], store) }
          .not_to output(/feature file changed since import/).to_stdout
      end
    end
  end
end
