# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion worker launch' do
  let(:ctx) { tyrion_worktree(project_slug: 'workers', epic_slug: 'launch') }
  let(:store) { ctx.store }
  let(:worktree) { ctx.tmpdir }
  let(:task_file) { File.join(worktree, 'task.md') }
  let(:argv) do
    ['launch', 'build-it', '--worktree', worktree, '--task-file', task_file,
     '--name', 'build it', '--lane', 'worker-1', '--attempt', 'attempt-1']
  end

  before do
    story = store.create_story(epic_id: ctx.epic['id'], slug: 'build-it', title: 'Build it')
    store.start_story(story['id'], claimed_by: 'dispatched:worker-1')
    File.write(task_file, 'Implement the approved story')
    allow(Tyrion::Repo).to receive(:worktrees).and_return([{ path: worktree }])
  end

  it 'delegates to the one shared launcher with exact story worktree and lane' do
    response = ['{"success":true,"status":"started","attempt":"attempt-1","lane":"worker-1","via":"herdr","runtime_scope":"default","tab_id":"w1:t1"}', '',
                instance_double(Process::Status, exitstatus: 0, success?: true)]
    expect(Tyrion::WorkerSession).to receive(:run).with(
      '--dir', File.realpath(worktree), '--task-file', File.realpath(task_file), '--name', 'build it',
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
      '--dir', File.realpath(worktree), '--task-file', File.realpath(task_file), '--name', 'build it',
      '--provider', 'claude', '--runtime', 'herdr', '--lane', 'worker-1', '--attempt', 'attempt-1',
      '--json', '--herdr-session', 'worker-launch-uat'
    ).and_return(['{"success":true,"status":"started","attempt":"attempt-1","lane":"worker-1","via":"herdr","runtime_scope":"worker-launch-uat"}', '',
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
      '--dir', File.realpath(worktree), '--task-file', File.realpath(task_file), '--name', 'build it',
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
