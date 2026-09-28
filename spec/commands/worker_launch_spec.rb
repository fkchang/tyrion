# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion worker launch' do
  let(:ctx) { tyrion_worktree(project_slug: 'workers', epic_slug: 'launch') }
  let(:store) { ctx.store }
  let(:worktree) { ctx.tmpdir }
  let(:task_file) { File.join(worktree, 'task.md') }
  let(:handoff) { { text: 'Canonical scenario and task', sha256: 'payload-hash', scenario_revision: 'revision-hash', scenario_source: '/tmp/story.feature' } }
  let(:handle) do
    { worker_id: 'worker-1', attempt: 'attempt-1', lane: 'worker-1', provider: 'claude',
      runtime: { kind: 'herdr', scope: 'default', identity: 'socket-birth' },
      terminal: { tab_id: 'w1:t1', pane_id: 'w1:p1', terminal_id: 'term-1' },
      process: { pid: 123, birth: 'Sun Sep 27 10:00:00 2026', observed_at: '2026-09-27T10:00:01Z' },
      native_conversation: { value: nil, source: nil, freshness: 'unknown', observed_at: '2026-09-27T10:00:01Z' },
      actions: { focus: true, follow_up: false, complete_story: false } }
  end
  let(:started_result) do
    { success: true, status: 'started', attempt: 'attempt-1', lane: 'worker-1', via: 'herdr',
      runtime_scope: 'default', tab_id: 'w1:t1', pane_id: 'w1:p1', handle: handle }
  end
  let(:argv) do
    ['launch', 'build-it', '--worktree', worktree, '--task-file', task_file,
     '--name', 'build it', '--lane', 'worker-1', '--attempt', 'attempt-1']
  end

  before do
    story = store.create_story(epic_id: ctx.epic['id'], slug: 'build-it', title: 'Build it')
    store.start_story(story['id'], claimed_by: 'dispatched:worker-1')
    File.write(task_file, 'Implement the approved story')
    allow(Tyrion::Repo).to receive(:worktrees).and_return([{ path: worktree }])
    allow(Tyrion::WorkerSession).to receive(:handoff).and_return(handoff)
  end

  it 'delegates to the one shared launcher with exact story worktree and lane' do
    response = [started_result.to_json, '',
                instance_double(Process::Status, exitstatus: 0, success?: true)]
    expect(Tyrion::WorkerSession).to receive(:run).with(
      '--dir', File.realpath(worktree), '--task', handoff[:text], '--name', 'build it',
      '--provider', 'claude', '--runtime', 'herdr', '--lane', 'worker-1', '--attempt', 'attempt-1', '--json'
    ).and_return(response)

    expect { Tyrion::Commands.cmd_worker(argv.dup, store) }.to output(/"status":"started"/).to_stdout
  end

  it 'refuses a lane that does not own the story before calling the launcher' do
    expect(Tyrion::WorkerSession).not_to receive(:run)
    expect { Tyrion::Commands.cmd_worker(argv.dup.tap { |a| a[a.index('worker-1')] = 'neighbor' }, store) }
      .to raise_error(SystemExit).and output(/assigned to.*worker-1/).to_stderr
  end

  it 'refuses a directory outside the registered worktrees before calling the launcher' do
    allow(Tyrion::Repo).to receive(:worktrees).and_return([])
    expect(Tyrion::WorkerSession).not_to receive(:run)
    expect { Tyrion::Commands.cmd_worker(argv.dup, store) }
      .to raise_error(SystemExit).and output(/registered git worktree/).to_stderr
  end

  it 'passes an unknown result through without claiming launch success' do
    response = ['{"success":false,"status":"unknown","attempt":"attempt-1","lane":"worker-1","via":"herdr","runtime_scope":"default"}', '',
                instance_double(Process::Status, exitstatus: 2, success?: false)]
    allow(Tyrion::WorkerSession).to receive(:run).and_return(response)
    expect { Tyrion::Commands.cmd_worker(argv.dup, store) }
      .to raise_error(SystemExit) { |error| expect(error.status).to eq(2) }
      .and output(/"status":"unknown"/).to_stdout
  end

  it 'forwards a named Herdr session for isolated launches' do
    expect(Tyrion::WorkerSession).to receive(:run).with(
      '--dir', File.realpath(worktree), '--task', handoff[:text], '--name', 'build it',
      '--provider', 'claude', '--runtime', 'herdr', '--lane', 'worker-1', '--attempt', 'attempt-1',
      '--json', '--herdr-session', 'worker-launch-uat'
    ).and_return([started_result.merge(runtime_scope: 'worker-launch-uat',
                                       handle: handle.merge(runtime: handle[:runtime].merge(scope: 'worker-launch-uat'))).to_json, '',
                  instance_double(Process::Status, exitstatus: 0, success?: true)])
    expect { Tyrion::Commands.cmd_worker(argv.dup + ['--herdr-session', 'worker-launch-uat'], store) }
      .to output(/"status":"started"/).to_stdout
  end

  it 'rejects plain text from a misconfigured launcher even if it exits zero' do
    allow(Tyrion::WorkerSession).to receive(:run).and_return(
      ['launched successfully', '', instance_double(Process::Status, exitstatus: 0, success?: true)]
    )
    expect { Tyrion::Commands.cmd_worker(argv.dup, store) }
      .to raise_error(SystemExit).and output(/invalid structured result/).to_stderr
  end

  it 'rejects a native reference that lacks exact UUID, argv provenance, or process birth' do
    base = JSON.parse(started_result.to_json)
    uuid = 'e10456d2-20db-4aa7-b68c-64340252f995'
    native = { 'value' => uuid, 'kind' => 'id', 'source' => 'launcher_cli_arg+process_argv',
               'freshness' => 'current', 'observed_at' => '2026-09-27T10:00:01Z',
               'process_birth' => base.dig('handle', 'process', 'birth') }
    base['handle']['native_conversation'] = native
    expect(Tyrion::WorkerSession.valid_handle?(base, lane: 'worker-1', scope: 'default', attempt: 'attempt-1')).to be true

    [{ 'value' => 'neighbor' }, { 'kind' => 'path' }, { 'source' => 'herdr-candidate' },
     { 'process_birth' => 'another-process' }].each do |change|
      wrong = Marshal.load(Marshal.dump(base))
      wrong['handle']['native_conversation'].merge!(change)
      expect(Tyrion::WorkerSession.valid_handle?(wrong, lane: 'worker-1', scope: 'default', attempt: 'attempt-1')).to be false
    end
  end

  it 'rejects an unknown status paired with a success exit code' do
    allow(Tyrion::WorkerSession).to receive(:run).and_return(
      ['{"success":false,"status":"unknown"}', '',
       instance_double(Process::Status, exitstatus: 0, success?: true)]
    )
    expect { Tyrion::Commands.cmd_worker(argv.dup, store) }
      .to raise_error(SystemExit).and output(/result and exit code disagree/).to_stderr
  end

  it 'accepts a scoped dry-run result without creating a worker' do
    expect(Tyrion::WorkerSession).to receive(:run).with(
      '--dir', File.realpath(worktree), '--task', handoff[:text], '--name', 'build it',
      '--provider', 'claude', '--runtime', 'herdr', '--lane', 'worker-1', '--attempt', 'attempt-1',
      '--json', '--dry-run'
    ).and_return(['{"success":true,"status":"dry_run","attempt":"attempt-1","lane":"worker-1","via":"herdr","runtime_scope":"default"}', '',
                  instance_double(Process::Status, exitstatus: 0, success?: true)])
    expect { Tyrion::Commands.cmd_worker(argv.dup + ['--dry-run'], store) }
      .to output(/"status":"dry_run"/).to_stdout
  end

  it 'reports a vanished task file as a path race, not a missing launcher' do
    allow(File).to receive(:realpath).and_call_original
    allow(File).to receive(:realpath).with(task_file).and_raise(Errno::ENOENT, task_file)
    expect(Tyrion::WorkerSession).not_to receive(:run)
    expect { Tyrion::Commands.cmd_worker(argv.dup, store) }
      .to raise_error(SystemExit).and output(/worktree or task file disappeared/).to_stderr
  end
end
