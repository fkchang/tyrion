# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'tempfile'

RSpec.describe 'tyrion drift' do
  let(:ctx)   { tyrion_worktree(epic_slug: nil) }
  let(:store) { ctx.store }

  def create_tracked_epic(store, project_id:, slug:, feature_path:, feature_hash:)
    store.upsert_epic(
      project_id:          project_id,
      slug:                slug,
      name:                slug,
      feature_source_path: feature_path,
      feature_source_hash: feature_hash
    )
  end

  it 'reports up to date when the file is unchanged' do
    Tempfile.create(['feat', '.feature']) do |f|
      f.write("Feature: test\n")
      f.flush
      hash = Digest::SHA256.file(f.path).hexdigest
      create_tracked_epic(store, project_id: ctx.project['id'], slug: 'my-epic',
                                 feature_path: f.path, feature_hash: hash)
      stub_repo(active_project: ctx.project['slug'], active_epic: nil,
                worktree_root: ctx.tmpdir)

      expect { Tyrion::Commands.cmd_drift([], store) }
        .to output(/my-epic: up to date/).to_stdout
    end
  end

  it 'reports changed when the feature file has changed since import' do
    Tempfile.create(['feat', '.feature']) do |f|
      f.write("Feature: original\n")
      f.flush
      stale_hash = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
      create_tracked_epic(store, project_id: ctx.project['id'], slug: 'changed-epic',
                                 feature_path: f.path, feature_hash: stale_hash)
      stub_repo(active_project: ctx.project['slug'], active_epic: nil,
                worktree_root: ctx.tmpdir)

      expect { Tyrion::Commands.cmd_drift([], store) }
        .to output(/changed-epic: feature file changed - run tyrion import #{Regexp.escape(f.path)}/).to_stdout
    end
  end

  it 'reports missing when the feature file does not exist' do
    create_tracked_epic(store, project_id: ctx.project['id'], slug: 'ghost-epic',
                               feature_path: '/nonexistent/path/ghost-epic.feature',
                               feature_hash: 'abc123')
    stub_repo(active_project: ctx.project['slug'], active_epic: nil,
              worktree_root: ctx.tmpdir)

    expect { Tyrion::Commands.cmd_drift([], store) }
      .to output(/ghost-epic: feature file missing/).to_stdout
  end

  it 'reports the no-tracked-epics notice when no epics have tracked files' do
    store.create_epic(project_id: ctx.project['id'], slug: 'untracked', name: 'Untracked')
    stub_repo(active_project: ctx.project['slug'], active_epic: nil)

    expect { Tyrion::Commands.cmd_drift([], store) }
      .to output(/No epics with tracked feature files/).to_stdout
  end

  it 'resolves relative feature_source_path against worktree_root' do
    feature_file = File.join(ctx.tmpdir, 'features', 'rel-epic.feature')
    FileUtils.mkdir_p(File.dirname(feature_file))
    File.write(feature_file, "Feature: relative\n")
    hash = Digest::SHA256.file(feature_file).hexdigest

    create_tracked_epic(store, project_id: ctx.project['id'], slug: 'rel-epic',
                               feature_path: 'features/rel-epic.feature',
                               feature_hash: hash)
    stub_repo(active_project: ctx.project['slug'], active_epic: nil,
              worktree_root: ctx.tmpdir)

    expect { Tyrion::Commands.cmd_drift([], store) }
      .to output(/rel-epic: up to date/).to_stdout
  end
end
