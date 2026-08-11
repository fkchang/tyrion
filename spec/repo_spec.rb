# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Tyrion::Repo do
  let(:tmpdir) { Dir.mktmpdir('tyrion-repo-spec-') }

  after { FileUtils.rm_rf(tmpdir) }

  describe '.active_story / .write_active_story' do
    it 'returns nil when .tyrion/active-story does not exist' do
      expect(described_class.active_story(tmpdir)).to be_nil
    end

    it 'round-trips a slug through write then read' do
      described_class.write_active_story('my-story', tmpdir)
      expect(described_class.active_story(tmpdir)).to eq('my-story')
    end

    it 'creates .tyrion/ dir if absent' do
      described_class.write_active_story('slug', tmpdir)
      expect(File.exist?("#{tmpdir}/.tyrion/active-story")).to be true
    end

    it 'strips trailing whitespace/newlines on read' do
      FileUtils.mkdir_p("#{tmpdir}/.tyrion")
      File.write("#{tmpdir}/.tyrion/active-story", "my-story\n  ")
      expect(described_class.active_story(tmpdir)).to eq('my-story')
    end
  end

  describe '.tyrion_root' do
    it 'returns nil for a path that no longer exists (deleted project dir)' do
      expect(described_class.tyrion_root("#{tmpdir}/gone/deeper")).to be_nil
    end

    it 'finds the root when invoked from a subdir' do
      FileUtils.mkdir_p("#{tmpdir}/.tyrion")
      FileUtils.touch("#{tmpdir}/#{described_class::MARKER}")
      FileUtils.mkdir_p("#{tmpdir}/sub/dir")
      expect(described_class.tyrion_root("#{tmpdir}/sub/dir")).to eq(File.realpath(tmpdir))
    end
  end

  describe '.lane_dir' do
    it 'returns a path under .tyrion/lanes/ keyed by the first 16 hex chars of sha256(token)' do
      token = 'claude:12345:abcdef'
      expected_hash = Digest::SHA256.hexdigest(token)[0, 16]
      expect(described_class.lane_dir(token, tmpdir)).to eq("#{tmpdir}/.tyrion/lanes/#{expected_hash}")
    end

    it 'produces different dirs for different tokens' do
      dir_a = described_class.lane_dir('claude:111:aaa', tmpdir)
      dir_b = described_class.lane_dir('claude:222:bbb', tmpdir)
      expect(dir_a).not_to eq(dir_b)
    end

    it 'produces the same dir for the same token' do
      token = 'codex:thread-abc'
      expect(described_class.lane_dir(token, tmpdir)).to eq(described_class.lane_dir(token, tmpdir))
    end
  end

  describe '.active_epic / .write_active_epic with token:' do
    let(:token_a) { 'claude:100:stampA' }
    let(:token_b) { 'claude:200:stampB' }

    it 'returns nil when no per-lane file exists' do
      expect(described_class.active_epic(tmpdir, token: token_a)).to be_nil
    end

    it 'write then read round-trips for a given token' do
      described_class.write_active_epic('epic-a', tmpdir, token: token_a)
      expect(described_class.active_epic(tmpdir, token: token_a)).to eq('epic-a')
    end

    it 'isolates lane A from lane B' do
      described_class.write_active_epic('epic-a', tmpdir, token: token_a)
      described_class.write_active_epic('epic-b', tmpdir, token: token_b)

      expect(described_class.active_epic(tmpdir, token: token_a)).to eq('epic-a')
      expect(described_class.active_epic(tmpdir, token: token_b)).to eq('epic-b')
    end

    it 'writes the per-lane file under .tyrion/lanes/<hash>/active-epic' do
      described_class.write_active_epic('epic-x', tmpdir, token: token_a)
      hash = Digest::SHA256.hexdigest(token_a)[0, 16]
      expect(File.exist?("#{tmpdir}/.tyrion/lanes/#{hash}/active-epic")).to be true
    end

    it 'shared fallback (no token) returns the shared .tyrion/active-epic' do
      FileUtils.mkdir_p("#{tmpdir}/.tyrion")
      File.write("#{tmpdir}/.tyrion/active-epic", "shared-epic\n")

      described_class.write_active_epic('epic-a', tmpdir, token: token_a)

      expect(described_class.active_epic(tmpdir)).to eq('shared-epic')
    end

    it 'falls back to shared file when per-lane file is absent' do
      FileUtils.mkdir_p("#{tmpdir}/.tyrion")
      File.write("#{tmpdir}/.tyrion/active-epic", "shared-epic\n")

      expect(described_class.active_epic(tmpdir, token: token_a)).to eq('shared-epic')
    end

    it 'nil token uses shared file (legacy behavior)' do
      FileUtils.mkdir_p("#{tmpdir}/.tyrion")
      File.write("#{tmpdir}/.tyrion/active-epic", "legacy-epic\n")

      expect(described_class.active_epic(tmpdir, token: nil)).to eq('legacy-epic')
    end
  end

  describe '.active_story / .write_active_story / .clear_active_story with token:' do
    let(:token) { 'claude:42:stamp42' }

    it 'write then read round-trips per-lane story' do
      described_class.write_active_story('my-story', tmpdir, token: token)
      expect(described_class.active_story(tmpdir, token: token)).to eq('my-story')
    end

    it 'clear_active_story removes the per-lane pin' do
      described_class.write_active_story('my-story', tmpdir, token: token)
      described_class.clear_active_story(tmpdir, token: token)
      expect(described_class.active_story(tmpdir, token: token)).to be_nil
    end

    it 'clear_active_story is idempotent when file absent' do
      expect { described_class.clear_active_story(tmpdir, token: token) }.not_to raise_error
    end

    it 'legacy no-token still round-trips through shared file' do
      described_class.write_active_story('old-story', tmpdir)
      expect(described_class.active_story(tmpdir)).to eq('old-story')
    end
  end

  describe '.parse_lane_pid_token' do
    it 'parses a pid token "<label>:<pid>:<16-hex-stamp>" into [pid, stamp]' do
      stamp = 'a1b2c3d4e5f60718'
      expect(described_class.parse_lane_pid_token("claude:12345:#{stamp}")).to eq([12345, stamp])
    end

    it 'tolerates labels containing a hyphen or extra colons in the agent label' do
      stamp = '0123456789abcdef'
      expect(described_class.parse_lane_pid_token("my-agent:777:#{stamp}")).to eq([777, stamp])
    end

    it 'returns nil for an explicit label token (no pid segment)' do
      expect(described_class.parse_lane_pid_token('lane-lane-liveness')).to be_nil
    end

    it 'returns nil for a codex thread token' do
      expect(described_class.parse_lane_pid_token('codex:thread_abc123')).to be_nil
    end

    it 'returns nil when the stamp is not 16 hex chars (e.g. a hand-set TYRION_LANE)' do
      expect(described_class.parse_lane_pid_token('claude:99999:abc123')).to be_nil
    end

    it 'returns nil for nil' do
      expect(described_class.parse_lane_pid_token(nil)).to be_nil
    end
  end

  describe '.pid_alive?' do
    context 'when ps is available' do
      before { allow(described_class).to receive(:ps_available?).and_return(true) }

      it 'returns :live when the pid exists and its start-stamp matches' do
        allow(described_class).to receive(:pid_start_stamp).with(123).and_return('matchingstamp000')
        expect(described_class.pid_alive?(123, 'matchingstamp000')).to eq(:live)
      end

      it 'returns :dead when the pid no longer exists' do
        allow(described_class).to receive(:pid_start_stamp).with(123).and_return(nil)
        expect(described_class.pid_alive?(123, 'anystamp00000000')).to eq(:dead)
      end

      it 'returns :dead when the pid exists but its start-stamp differs (recycled pid)' do
        allow(described_class).to receive(:pid_start_stamp).with(123).and_return('otherstamp000000')
        expect(described_class.pid_alive?(123, 'matchingstamp000')).to eq(:dead)
      end
    end

    context 'when ps is unavailable/denied' do
      before { allow(described_class).to receive(:ps_available?).and_return(false) }

      it 'returns :unknown without probing the target pid' do
        expect(described_class).not_to receive(:pid_start_stamp).with(123)
        expect(described_class.pid_alive?(123, 'matchingstamp000')).to eq(:unknown)
      end
    end
  end

  describe '.lane_liveness' do
    it 'returns :unknown for a non-pid token without touching ps' do
      expect(described_class).not_to receive(:ps_available?)
      expect(described_class.lane_liveness('lane-lane-liveness')).to eq(:unknown)
    end

    it 'delegates to pid_alive? for a pid token' do
      stamp = '0123456789abcdef'
      allow(described_class).to receive(:pid_alive?).with(555, stamp).and_return(:dead)
      expect(described_class.lane_liveness("claude:555:#{stamp}")).to eq(:dead)
    end

    it 'returns :unknown for a nil token' do
      expect(described_class.lane_liveness(nil)).to eq(:unknown)
    end
  end

  describe '.ps_available?' do
    it 'is true when the current process start-stamp resolves' do
      allow(described_class).to receive(:pid_start_stamp).with(Process.pid).and_return('somestamp0000000')
      expect(described_class.ps_available?).to be true
    end

    it 'is false when ps yields nothing for the current process (denied/sandboxed)' do
      allow(described_class).to receive(:pid_start_stamp).with(Process.pid).and_return(nil)
      expect(described_class.ps_available?).to be false
    end
  end
end
