# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion web ambient' do
  let(:ctx)   { tyrion_worktree(project_slug: 'my-proj') }
  let(:store) { ctx.store }

  before do
    ctx # worktree (and its Repo stubs) must be in place before the stubs below
    # Pretend a healthy server is already up so no process is ever spawned.
    allow(Tyrion::WebServer).to receive(:web_root).and_return('/tmp/web')
    allow(Tyrion::WebServer).to receive(:running_pid).and_return(4321)
    allow(Tyrion::WebServer).to receive(:healthy?).and_return(true)
    allow(Tyrion::WebServer).to receive(:open_app_window).and_return(true)
    allow(Tyrion::WebServer).to receive(:open_url)
  end

  it 'opens the ambient URL scoped to the shell-active project, not a bare /ambient' do
    expect(Tyrion::WebServer).to receive(:open_app_window)
      .with('http://localhost:4579/ambient?project=my-proj').and_return(true)

    expect { Tyrion::Commands.cmd_web(['ambient'], store) }
      .to output(%r{http://localhost:4579/ambient\?project=my-proj}).to_stdout
  end

  it 'starts the server when it is not already running' do
    allow(Tyrion::WebServer).to receive(:running_pid).and_return(nil)
    expect(Tyrion::WebServer).to receive(:start)
      .with(port: 4579, project: 'my-proj').and_return(true)

    expect { Tyrion::Commands.cmd_web(['ambient'], store) }.to output(/Starting tyrion web/).to_stdout
  end

  it 'falls back to a plain open of the same URL when app mode is unavailable' do
    allow(Tyrion::WebServer).to receive(:open_app_window).and_return(false)
    expect(Tyrion::WebServer).to receive(:open_url)
      .with('http://localhost:4579/ambient?project=my-proj')

    expect { Tyrion::Commands.cmd_web(['ambient'], store) }
      .to output(/normal window/).to_stdout
  end

  it 'still prints the URL under --no-open so a tab can be pinned by hand' do
    expect(Tyrion::WebServer).not_to receive(:open_app_window)
    expect(Tyrion::WebServer).not_to receive(:open_url)

    expect { Tyrion::Commands.cmd_web(%w[ambient --no-open], store) }
      .to output(%r{http://localhost:4579/ambient\?project=my-proj}).to_stdout
  end

  it 'honours --port' do
    expect(Tyrion::WebServer).to receive(:open_app_window)
      .with('http://localhost:5000/ambient?project=my-proj').and_return(true)

    expect { Tyrion::Commands.cmd_web(%w[ambient --port 5000], store) }
      .to output(%r{http://localhost:5000/ambient\?project=my-proj}).to_stdout
  end

  describe '--help' do
    it 'prints usage and never touches WebServer (no accidental launch)' do
      expect(Tyrion::WebServer).not_to receive(:start)
      expect(Tyrion::WebServer).not_to receive(:running_pid)
      expect(Tyrion::WebServer).not_to receive(:open_app_window)
      expect(Tyrion::WebServer).not_to receive(:open_url)

      expect { Tyrion::Commands.cmd_web(['--help'], store) }.to output(/Usage: tyrion web/).to_stdout
    end
  end
end

RSpec.describe Tyrion::WebServer do
  describe '.ambient_url' do
    it 'escapes the project slug' do
      expect(described_class.ambient_url(4579, 'a b&c'))
        .to eq 'http://localhost:4579/ambient?project=a+b%26c'
    end
  end

  describe '.app_mode_binary' do
    it 'picks the first existing Chrome-family app bundle on macOS' do
      allow(described_class).to receive(:host_family).and_return(:darwin)
      chromium = '/Applications/Chromium.app/Contents/MacOS/Chromium'
      allow(File).to receive(:executable?).and_return(false)
      allow(File).to receive(:executable?).with(chromium).and_return(true)

      expect(described_class.app_mode_binary).to eq chromium
    end

    it 'resolves bare binary names on PATH on linux' do
      allow(described_class).to receive(:host_family).and_return(:linux)
      allow(ENV).to receive(:fetch).with('PATH', '').and_return('/opt/bin')
      allow(File).to receive(:executable?).and_return(false)
      allow(File).to receive(:executable?).with('/opt/bin/chromium').and_return(true)
      allow(File).to receive(:directory?).and_return(false)

      expect(described_class.app_mode_binary).to eq '/opt/bin/chromium'
    end

    it 'returns nil on a platform with no known app-mode browser' do
      allow(described_class).to receive(:host_family).and_return(nil)
      expect(described_class.app_mode_binary).to be_nil
    end
  end

  describe '.open_app_window' do
    it 'passes url, window size, and a dedicated profile dir as separate argv entries — never a shell string' do
      allow(described_class).to receive(:app_mode_binary).and_return('/bin/chrome')
      allow(Process).to receive(:detach)
      # --user-data-dir is required, not optional decoration: without it, --app=
      # is forwarded via IPC to any already-running Chrome under the normal
      # profile, which silently ignores --window-size (only the process that
      # actually parses a flag honors it). See open_app_window's comment.
      expect(Process).to receive(:spawn)
        .with('/bin/chrome', '--app=http://localhost:4579/ambient?project=p',
              '--window-size=340,960', "--user-data-dir=#{described_class.ambient_profile_dir}",
              hash_including(:out, :err))
        .and_return(99)

      expect(described_class.open_app_window('http://localhost:4579/ambient?project=p')).to be true
    end

    it 'returns false when no supported browser is detected' do
      allow(described_class).to receive(:app_mode_binary).and_return(nil)
      expect(described_class.open_app_window('http://x')).to be false
    end

    it 'returns false rather than raising when the launch fails' do
      allow(described_class).to receive(:app_mode_binary).and_return('/bin/chrome')
      allow(Process).to receive(:spawn).and_raise(Errno::ENOENT)
      expect(described_class.open_app_window('http://x')).to be false
    end
  end
end
