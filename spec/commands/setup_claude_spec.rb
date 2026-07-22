# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'tyrion setup claude' do
  let(:ctx)   { tyrion_worktree(project_slug: 'setupproj', epic_slug: 'setup-epic') }
  let(:store) { ctx.store }

  let(:settings_path) { File.join(ctx.tmpdir, Tyrion::Commands::SETTINGS_RELATIVE_PATH) }
  let(:shim_path)     { File.join(ctx.tmpdir, Tyrion::Commands::SHIM_INSTALL_PATH) }

  def write_settings(hash)
    FileUtils.mkdir_p(File.dirname(settings_path))
    File.write(settings_path, JSON.pretty_generate(hash))
  end

  # ── install path (no --check) ───────────────────────────────────────────

  describe 'install (no --check)' do
    it 'writes settings.json (hooks for all 3 events + whitelist) and the shim (0755, current version), prints success' do
      out, = capture_io { Tyrion::Commands.cmd_setup_claude([], store) }

      expect(File).to exist(settings_path)
      expect(File).to exist(shim_path)
      expect(File.stat(shim_path).mode & 0o777).to eq(0o755)
      expect(Tyrion::Commands.installed_shim_version(shim_path)).to eq(Tyrion::Commands::SHIM_VERSION)

      settings = JSON.parse(File.read(settings_path))
      expect(settings['hooks'].keys).to include('SessionStart', 'PreCompact', 'PreToolUse')
      expect(settings.dig('permissions', 'allow')).to include(*Tyrion::Commands::TYRION_PERMISSIONS)

      expect(out).to match(/installed/i)
    end

    it 'preserves foreign hooks and foreign permissions untouched, in original order, alongside new tyrion entries' do
      write_settings(
        'hooks' => {
          'Stop' => [{ 'matcher' => '', 'hooks' => [{ 'type' => 'command', 'command' => 'echo foreign' }] }]
        },
        'permissions' => { 'allow' => ['Bash(echo foreign-perm)'] }
      )

      capture_io { Tyrion::Commands.cmd_setup_claude([], store) }

      settings = JSON.parse(File.read(settings_path))
      expect(settings.dig('hooks', 'Stop')).to eq(
        [{ 'matcher' => '', 'hooks' => [{ 'type' => 'command', 'command' => 'echo foreign' }] }]
      )
      allow = settings.dig('permissions', 'allow')
      expect(allow.first).to eq('Bash(echo foreign-perm)')
      expect(allow).to include(*Tyrion::Commands::TYRION_PERMISSIONS)
    end

    it 'replaces a stale tyrion-owned PreToolUse group in place rather than duplicating it' do
      stale_command = %("$CLAUDE_PROJECT_DIR"/#{Tyrion::Commands::SHIM_INSTALL_PATH} tyrion hook claim-gate --old-flag)
      write_settings(
        'hooks' => {
          'PreToolUse' => [{ 'matcher' => 'Bash', 'hooks' => [{ 'type' => 'command', 'command' => stale_command }] }]
        }
      )

      capture_io { Tyrion::Commands.cmd_setup_claude([], store) }

      settings = JSON.parse(File.read(settings_path))
      pre_tool_use_groups = settings.dig('hooks', 'PreToolUse')
      expect(pre_tool_use_groups.length).to eq(1)
      expect(pre_tool_use_groups.first['hooks'].first['command']).not_to include('--old-flag')
    end

    it 'dies with zero writes when settings.json is malformed JSON' do
      FileUtils.mkdir_p(File.dirname(settings_path))
      malformed = 'not { valid json'
      File.write(settings_path, malformed)

      expect { Tyrion::Commands.cmd_setup_claude([], store) }
        .to raise_error(having_attributes(status: 1)).and output(/refusing to install/).to_stderr

      expect(File).not_to exist(shim_path)
      expect(File.read(settings_path)).to eq(malformed)
    end

    it 'is idempotent: running twice leaves settings.json byte-identical' do
      capture_io { Tyrion::Commands.cmd_setup_claude([], store) }
      first_bytes = File.read(settings_path)

      capture_io { Tyrion::Commands.cmd_setup_claude([], store) }
      second_bytes = File.read(settings_path)

      expect(second_bytes).to eq(first_bytes)
    end
  end

  # ── --check ──────────────────────────────────────────────────────────────

  describe '--check' do
    it 'reports all 3 managed surfaces absent on a fresh worktree, exits 2 (PARTIAL), prints CLAUDE.md line, writes nothing' do
      out, = capture_io do
        expect { Tyrion::Commands.cmd_setup_claude(['--check'], store) }
          .to raise_error(having_attributes(status: 2))
      end

      expect(out).to match(/hooks:.*absent/i)
      expect(out).to match(/whitelist:.*absent/i)
      expect(out).to match(/gate shim.*absent/i)
      expect(out).to match(/CLAUDE\.md block: not yet managed by this tyrion version/)

      expect(File).not_to exist(settings_path)
      expect(File).not_to exist(shim_path)
    end

    context 'after a full successful install' do
      around do |example|
        fake_bin_dir = Dir.mktmpdir('tyrion-fake-bin')
        old_path = ENV['PATH']
        begin
          @fake_bin_dir = fake_bin_dir
          example.run
        ensure
          ENV['PATH'] = old_path
          FileUtils.remove_entry(fake_bin_dir)
        end
      end

      def install_fake_tyrion_on_path(fake_bin_dir)
        fake_tyrion = File.join(fake_bin_dir, 'tyrion')
        File.write(fake_tyrion, <<~SH)
          #!/usr/bin/env bash
          if [ "$1" = "hook" ] && [ "$2" = "claim-gate" ]; then
            echo armed
            echo "version: 1"
            exit 0
          fi
          exit 0
        SH
        File.chmod(0o755, fake_tyrion)
        ENV['PATH'] = "#{fake_bin_dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}"
      end

      it 'exits 0 (CURRENT) when the shim reports armed via a fake tyrion on PATH' do
        capture_io { Tyrion::Commands.cmd_setup_claude([], store) }
        install_fake_tyrion_on_path(@fake_bin_dir)

        capture_io do
          expect { Tyrion::Commands.cmd_setup_claude(['--check'], store) }
            .to raise_error(having_attributes(status: 0))
        end
      end

      it 'exits 3 (FAIL-OPEN) when tyrion is not resolvable on PATH' do
        capture_io { Tyrion::Commands.cmd_setup_claude([], store) }
        ENV['PATH'] = @fake_bin_dir # empty dir, no tyrion on it

        capture_io do
          expect { Tyrion::Commands.cmd_setup_claude(['--check'], store) }
            .to raise_error(having_attributes(status: 3))
        end
      end

      it 'exits 1 (DRIFT) when the installed shim version is older than SHIM_VERSION' do
        capture_io { Tyrion::Commands.cmd_setup_claude([], store) }
        install_fake_tyrion_on_path(@fake_bin_dir)

        File.write(shim_path, "#!/usr/bin/env bash\n# tyrion-shim v0 — stale\nexit 0\n")
        File.chmod(0o755, shim_path)

        capture_io do
          expect { Tyrion::Commands.cmd_setup_claude(['--check'], store) }
            .to raise_error(having_attributes(status: 1))
        end
      end

      it 'exits 2 (PARTIAL) when hooks are current but whitelist entries are missing, even though shim is current' do
        capture_io { Tyrion::Commands.cmd_setup_claude([], store) }
        install_fake_tyrion_on_path(@fake_bin_dir)

        settings = JSON.parse(File.read(settings_path))
        settings['permissions']['allow'] = settings['permissions']['allow'] - Tyrion::Commands::TYRION_PERMISSIONS
        File.write(settings_path, JSON.pretty_generate(settings))

        capture_io do
          expect { Tyrion::Commands.cmd_setup_claude(['--check'], store) }
            .to raise_error(having_attributes(status: 2))
        end
      end
    end
  end
end
