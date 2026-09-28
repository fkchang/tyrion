# frozen_string_literal: true

require 'spec_helper'
require 'digest'

RSpec.describe Tyrion::WorkerSession do
  let(:ctx) { tyrion_worktree(project_slug: 'workers', epic_slug: 'launch') }
  let(:store) { ctx.store }
  let(:feature) { File.join(ctx.tmpdir, 'launch.feature') }

  before do
    File.write(feature, <<~FEATURE)
      Feature: Launch worker
        Background:
          Every worker must read the complete approved contract.

        @isolated
        # Scenario constraint: stay within this lane.
        Scenario: build-it
          # Intent: Build the thing
          Given a named lane
          When a worker starts
          Then it must preserve the exact binding

        @other_scope
        # Next story only: do not include this unrelated constraint
        Scenario: other-story
          Then it does something else
    FEATURE
    store.update_epic(ctx.epic['id'],
                      'feature_source_path' => feature,
                      'feature_source_hash' => Digest::SHA256.file(feature).hexdigest)
    File.write(File.join(ctx.tmpdir, 'AGENTS.md'), 'Never edit a neighboring lane.')
    File.write(File.join(ctx.tmpdir, 'CLAUDE.md'), 'Run focused tests before closing.')
  end

  it 'hands the worker the imported canonical revision and recorded constraints' do
    story = store.create_story(epic_id: ctx.epic['id'], slug: 'build-it', title: 'Build it')
    store.add_note(story['id'], 'plan', 'Use exact pane binding')
    store.add_note(story['id'], 'decision', 'Do not infer identity from name')
    epic = store.find_epic(ctx.project['id'], 'launch')

    handoff = described_class.handoff(store: store, epic: epic, story: story,
                                      worktree: ctx.tmpdir, task: 'Implement the approved story')
    expect(handoff[:text]).to include('Given a named lane', 'Then it must preserve the exact binding')
    expect(handoff[:text]).to include('Every worker must read the complete approved contract.')
    expect(handoff[:text]).to include('@isolated', 'Scenario constraint: stay within this lane.')
    expect(handoff[:text]).not_to include('Next story only', '@other_scope')
    expect(handoff[:text]).to include(Digest::SHA256.file(feature).hexdigest)
    expect(handoff[:text]).to include('Use exact pane binding', 'Do not infer identity from name')
    expect(handoff[:text]).to include('Never edit a neighboring lane.', 'Run focused tests before closing.')
    expect(handoff[:text]).to include('Implement the approved story')
    expect(handoff[:sha256]).to eq(Digest::SHA256.hexdigest(handoff[:text]))
  end

  it 'gives a later Feature scenario the shared Background and only its own leading metadata' do
    story = store.create_story(epic_id: ctx.epic['id'], slug: 'other-story', title: 'Other story')
    epic = store.find_epic(ctx.project['id'], 'launch')

    text = described_class.handoff(store: store, epic: epic, story: story,
                                   worktree: ctx.tmpdir, task: 'Do the later story')[:text]
    expect(text).to include('Every worker must read the complete approved contract.')
    expect(text).to include('@other_scope', 'Next story only: do not include this unrelated constraint')
    expect(text).to include('Then it does something else')
    expect(text).not_to include('@isolated', 'Scenario constraint: stay within this lane.',
                                'Then it must preserve the exact binding')
  end

  it 'includes the applicable Rule background but no neighboring Rule context' do
    File.write(feature, <<~FEATURE)
      Feature: Launch worker
        Background:
          Global contract applies.

        Rule: current rule
          Background:
            Current rule contract applies.
          @first_in_rule
          # First Rule scenario only.
          Scenario: build-it
            Then this rule is honored

          @later_in_rule
          # Later Rule scenario only.
          Scenario: later-in-rule
            Then later rule work is honored

        Rule: unrelated rule
          Background:
            Neighbor rule must not appear.
          Scenario: other-story
            Then ignore this
    FEATURE
    store.update_epic(ctx.epic['id'], 'feature_source_hash' => Digest::SHA256.file(feature).hexdigest)
    story = store.create_story(epic_id: ctx.epic['id'], slug: 'build-it', title: 'Build it')
    epic = store.find_epic(ctx.project['id'], 'launch')

    text = described_class.handoff(store: store, epic: epic, story: story,
                                   worktree: ctx.tmpdir, task: 'Do it')[:text]
    expect(text).to include('Global contract applies.', 'Current rule contract applies.')
    expect(text).to include('@first_in_rule', 'First Rule scenario only.')
    expect(text).not_to include('Neighbor rule must not appear.', '@later_in_rule',
                                'Later Rule scenario only.')
  end

  it 'gives a later Rule scenario shared Feature and Rule backgrounds but no first-scenario metadata' do
    File.write(feature, <<~FEATURE)
      Feature: Launch worker
        Background:
          Global contract applies.

        @rule_scope
        # Rule-wide constraint.
        Rule: current rule
          Background:
            Current rule contract applies.
          @first_in_rule
          # First Rule scenario only.
          Scenario: build-it
            Then first work is honored

          @later_in_rule
          # Later Rule scenario only.
          Scenario: later-in-rule
            Then later work is honored

        Rule: unrelated rule
          Background:
            Neighbor rule must not appear.
          Scenario: other-story
            Then ignore this
    FEATURE
    store.update_epic(ctx.epic['id'], 'feature_source_hash' => Digest::SHA256.file(feature).hexdigest)
    story = store.create_story(epic_id: ctx.epic['id'], slug: 'later-in-rule', title: 'Later in rule')
    epic = store.find_epic(ctx.project['id'], 'launch')

    text = described_class.handoff(store: store, epic: epic, story: story,
                                   worktree: ctx.tmpdir, task: 'Do later rule work')[:text]
    expect(text).to include('Global contract applies.', 'Current rule contract applies.')
    expect(text).to include('@rule_scope', 'Rule-wide constraint.', '@later_in_rule',
                            'Later Rule scenario only.', 'Then later work is honored')
    expect(text).not_to include('@first_in_rule', 'First Rule scenario only.',
                                'Then first work is honored', 'Neighbor rule must not appear.')
  end

  it 'keeps heading-like text and later steps inside both Gherkin Doc String fence styles' do
    ['"""', '`' * 3].each do |fence|
      File.write(feature, <<~FEATURE)
        Feature: Launch worker
          Background:
            Global contract applies.

          Scenario: build-it
            Given a canonical payload
            When the payload is read
              #{fence}json
              Rule: payload text, not a new rule
              Scenario: payload text, not a new scenario
              REQUIRED-CANONICAL-DETAIL
              #{fence}
            And the post-payload condition remains required

          Scenario: neighbor-story
            Then neighbor details stay out
      FEATURE
      store.update_epic(ctx.epic['id'], 'feature_source_hash' => Digest::SHA256.file(feature).hexdigest)
      story = store.find_story(ctx.epic['id'], 'build-it') ||
              store.create_story(epic_id: ctx.epic['id'], slug: 'build-it', title: 'Build it')
      epic = store.find_epic(ctx.project['id'], 'launch')

      text = described_class.handoff(store: store, epic: epic, story: story,
                                     worktree: ctx.tmpdir, task: 'Do it')[:text]
      expect(text).to include('Global contract applies.', 'Rule: payload text, not a new rule',
                              'Scenario: payload text, not a new scenario', 'REQUIRED-CANONICAL-DETAIL',
                              'And the post-payload condition remains required')
      expect(text).not_to include('neighbor details stay out')
    end
  end

  it 'keeps plan and decision constraints even after more than 1000 later progress notes' do
    story = store.create_story(epic_id: ctx.epic['id'], slug: 'build-it', title: 'Build it')
    store.add_note(story['id'], 'decision', 'Old but binding decision')
    1001.times { |index| store.add_note(story['id'], 'progress', "Later progress #{index}") }
    epic = store.find_epic(ctx.project['id'], 'launch')

    text = described_class.handoff(store: store, epic: epic, story: story,
                                   worktree: ctx.tmpdir, task: 'Do it')[:text]
    expect(text).to include('Old but binding decision')
  end

  it 'refuses a changed canonical source before handing off any work' do
    story = store.create_story(epic_id: ctx.epic['id'], slug: 'build-it', title: 'Build it')
    File.write(feature, File.read(feature) + "\n  # unimported change\n")
    epic = store.find_epic(ctx.project['id'], 'launch')

    expect do
      described_class.handoff(store: store, epic: epic, story: story,
                              worktree: ctx.tmpdir, task: 'Implement the approved story')
    end.to raise_error(ArgumentError, /revision|import/i)
  end

  it 'passes the complete pinned handoff to the shared launcher on the command path' do
    story = store.create_story(epic_id: ctx.epic['id'], slug: 'build-it', title: 'Build it')
    store.start_story(story['id'], claimed_by: 'dispatched:worker-1')
    store.add_note(story['id'], 'decision', 'Preserve exact lane identity')
    task_file = File.join(ctx.tmpdir, 'task.md')
    File.write(task_file, 'Implement only this story')
    allow(Tyrion::Repo).to receive(:worktrees).and_return([{ path: ctx.tmpdir }])
    captured = nil
    allow(described_class).to receive(:run) do |*args|
      captured = args
      [{ success: false, status: 'unknown', attempt: 'attempt-1', lane: 'worker-1',
         via: 'herdr', runtime_scope: 'default' }.to_json, '',
       instance_double(Process::Status, exitstatus: 2, success?: false)]
    end

    argv = ['launch', 'build-it', '--worktree', ctx.tmpdir, '--task-file', task_file,
            '--name', 'build it', '--lane', 'worker-1', '--attempt', 'attempt-1']
    expect { Tyrion::Commands.cmd_worker(argv, store) }.to raise_error(SystemExit)
    task = captured[captured.index('--task') + 1]
    expect(task).to include('Given a named lane', 'Preserve exact lane identity',
                            'Never edit a neighboring lane.', 'Implement only this story')
    expect(task).to include(Digest::SHA256.file(feature).hexdigest)
  end
end
