# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'tyrion setup-codex' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'setup-epic') }
  let(:store) { ctx.store }
  let(:fake_home) { Dir.mktmpdir('tyrion-fake-home') }
  let(:link) { File.join(fake_home, '.agents', 'skills', 'tyrion') }

  before { allow(Dir).to receive(:home).and_return(fake_home) }
  after  { FileUtils.remove_entry(fake_home) }

  def run_setup
    Tyrion::Commands.cmd_setup_codex([], store)
  end

  it 'creates ~/.agents/skills/tyrion as a symlink to the skills directory' do
    expect { run_setup }.to output(/\.agents\/skills\/tyrion/).to_stdout
    expect(File.symlink?(link)).to be true
    target = File.readlink(link)
    expect(target).to end_with('/skills')
    expect(File).to exist(File.join(target, 'tyrion-implement', 'SKILL.md'))
  end

  it 'prints the discovered skill names and restart guidance' do
    expect { run_setup }.to output(/tyrion-implement.*Restart the Codex CLI/m).to_stdout
  end

  it 'is idempotent — re-running refreshes the symlink without error' do
    capture_io { run_setup }
    expect { run_setup }.to output(/\.agents\/skills\/tyrion/).to_stdout
    expect(File.symlink?(link)).to be true
  end

  it 'refreshes a stale symlink pointing elsewhere' do
    FileUtils.mkdir_p(File.dirname(link))
    File.symlink(Dir.mktmpdir('stale-target'), link)
    capture_io { run_setup }
    expect(File.readlink(link)).to end_with('/skills')
  end

  it 'dies when the link path is a real directory' do
    FileUtils.mkdir_p(link)
    expect { run_setup }.to raise_error(SystemExit)
      .and output(/not a symlink|move it aside/).to_stderr
  end

  it 'is dispatched from the CLI as setup-codex' do
    expect { Tyrion::Commands.run(['setup-codex']) }.to output(/Restart the Codex CLI/).to_stdout
    expect(File.symlink?(link)).to be true
  end
end
