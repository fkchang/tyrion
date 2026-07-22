# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'tyrion setup claude' do
  let(:ctx)   { tyrion_worktree(project_slug: 'setupproj', epic_slug: 'setup-epic') }
  let(:store) { ctx.store }

  let(:settings_path)  { File.join(ctx.tmpdir, Tyrion::Commands::SETTINGS_RELATIVE_PATH) }
  let(:shim_path)      { File.join(ctx.tmpdir, Tyrion::Commands::SHIM_INSTALL_PATH) }
  let(:claude_md_path) { File.join(ctx.tmpdir, Tyrion::Commands::CLAUDE_MD_RELATIVE_PATH) }

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

    it 'is idempotent: running twice leaves settings.json and CLAUDE.md byte-identical' do
      capture_io { Tyrion::Commands.cmd_setup_claude([], store) }
      first_bytes = File.read(settings_path)
      first_claude_md = File.read(claude_md_path)

      capture_io { Tyrion::Commands.cmd_setup_claude([], store) }
      second_bytes = File.read(settings_path)
      second_claude_md = File.read(claude_md_path)

      expect(second_bytes).to eq(first_bytes)
      expect(second_claude_md).to eq(first_claude_md)
    end
  end

  # ── --check ──────────────────────────────────────────────────────────────

  describe '--check' do
    it 'reports all 4 managed surfaces absent on a fresh worktree, exits 2 (PARTIAL), prints CLAUDE.md line, writes nothing' do
      out, = capture_io do
        expect { Tyrion::Commands.cmd_setup_claude(['--check'], store) }
          .to raise_error(having_attributes(status: 2))
      end

      expect(out).to match(/hooks:.*absent/i)
      expect(out).to match(/whitelist:.*absent/i)
      expect(out).to match(/gate shim.*absent/i)
      expect(out).to match(/CLAUDE\.md block:.*absent/i)

      expect(File).not_to exist(settings_path)
      expect(File).not_to exist(shim_path)
      expect(File).not_to exist(claude_md_path)
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

      it 'reports CLAUDE.md block: current when everything is freshly installed' do
        capture_io { Tyrion::Commands.cmd_setup_claude([], store) }
        install_fake_tyrion_on_path(@fake_bin_dir)

        out, = capture_io do
          expect { Tyrion::Commands.cmd_setup_claude(['--check'], store) }
            .to raise_error(having_attributes(status: 0))
        end

        expect(out).to match(/CLAUDE\.md block:.*current/i)
      end

      it 'exits 1 (DRIFT) when the CLAUDE.md block version is stale relative to CLAUDE_MD_BLOCK_VERSION' do
        capture_io { Tyrion::Commands.cmd_setup_claude([], store) }
        install_fake_tyrion_on_path(@fake_bin_dir)

        stale = File.read(claude_md_path).sub(/BEGIN TYRION-MANAGED-BLOCK v\d+/, 'BEGIN TYRION-MANAGED-BLOCK v0')
        File.write(claude_md_path, stale)

        out, = capture_io do
          expect { Tyrion::Commands.cmd_setup_claude(['--check'], store) }
            .to raise_error(having_attributes(status: 1))
        end

        expect(out).to match(/CLAUDE\.md block:.*drift/i)
      end

      it 'exits 1 (DRIFT) with a manual-resolution suffix when CLAUDE.md markers are ambiguous' do
        capture_io { Tyrion::Commands.cmd_setup_claude([], store) }
        install_fake_tyrion_on_path(@fake_bin_dir)

        duplicated = File.read(claude_md_path) * 2
        File.write(claude_md_path, duplicated)

        out, = capture_io do
          expect { Tyrion::Commands.cmd_setup_claude(['--check'], store) }
            .to raise_error(having_attributes(status: 1))
        end

        expect(out).to match(/CLAUDE\.md block:.*ambiguous/i)
        expect(out).to match(/resolve manually/i)
      end
    end
  end

  # ── CLAUDE.md managed block ─────────────────────────────────────────────

  describe 'CLAUDE.md managed block' do
    def block_body_from(content)
      content.sub(/\A<!-- BEGIN TYRION-MANAGED-BLOCK v\d+ sha256:[0-9a-f]{64} -->\n/, '')
             .sub(/<!-- END TYRION-MANAGED-BLOCK -->\n?\z/, '')
             .chomp
    end

    it 'creates CLAUDE.md containing just the block when none exists (criterion 5)' do
      expect(File).not_to exist(claude_md_path)

      capture_io { Tyrion::Commands.cmd_setup_claude([], store) }

      expect(File).to exist(claude_md_path)
      content = File.read(claude_md_path)
      expect(content).to match(/\A<!-- BEGIN TYRION-MANAGED-BLOCK v\d+ sha256:[0-9a-f]{64} -->\n/)
      expect(content).to match(/<!-- END TYRION-MANAGED-BLOCK -->\n\z/)
    end

    it 'the block carries a version + a content hash over the body excluding marker lines, mandate rules, and a pointer at tyrion prime (criterion 1)' do
      capture_io { Tyrion::Commands.cmd_setup_claude([], store) }

      content = File.read(claude_md_path)
      m = content.match(/\A<!-- BEGIN TYRION-MANAGED-BLOCK v(\d+) sha256:([0-9a-f]{64}) -->\n/)
      expect(m).not_to be_nil
      expect(m[1].to_i).to eq(Tyrion::Commands::CLAUDE_MD_BLOCK_VERSION)

      body = block_body_from(content)
      expect(Digest::SHA256.hexdigest(body)).to eq(m[2])

      expect(body).to match(/claim before code/)
      expect(body).to match(/evidence via tyrion note\/check/)
      expect(body).to match(/tyrion prime/)
      # Not a static command-reference dump: no long enumerated command list.
      expect(body.lines.count).to be < 15
    end

    it 'replaces only the owned block on re-run; prefix and suffix survive byte-for-byte (criterion 2)' do
      prefix = "# My Project\n\nSome human-written notes.\n\n"
      suffix = "\n## Trailer\n\nMore human notes below the block.\n"
      stale_block = "<!-- BEGIN TYRION-MANAGED-BLOCK v0 sha256:#{'a' * 64} -->\nold stale body\n<!-- END TYRION-MANAGED-BLOCK -->\n"
      FileUtils.mkdir_p(File.dirname(claude_md_path))
      File.write(claude_md_path, prefix + stale_block + suffix)

      capture_io { Tyrion::Commands.cmd_setup_claude([], store) }

      content = File.read(claude_md_path)
      expect(content).to start_with(prefix)
      expect(content).to end_with(suffix)
      expect(content).not_to include('old stale body')
      expect(Tyrion::Commands.claude_md_status(claude_md_path)).to eq(:current)
    end

    it 'appends a block to existing content with a blank-line separator when no block is present' do
      existing = "# Existing CLAUDE.md\n\nSome content here."
      FileUtils.mkdir_p(File.dirname(claude_md_path))
      File.write(claude_md_path, existing)

      capture_io { Tyrion::Commands.cmd_setup_claude([], store) }

      content = File.read(claude_md_path)
      expect(content).to start_with(existing)
      expect(content[existing.length..]).to match(/\A\n\n<!-- BEGIN TYRION-MANAGED-BLOCK/)
    end

    it 'refuses with zero writes when CLAUDE.md has duplicate BEGIN/END markers (criterion 3)' do
      one_block = "<!-- BEGIN TYRION-MANAGED-BLOCK v1 sha256:#{'b' * 64} -->\nbody\n<!-- END TYRION-MANAGED-BLOCK -->\n"
      duplicated = one_block * 2
      FileUtils.mkdir_p(File.dirname(claude_md_path))
      File.write(claude_md_path, duplicated)

      expect { Tyrion::Commands.cmd_setup_claude([], store) }
        .to raise_error(having_attributes(status: 1)).and output(/refusing to install/).to_stderr

      expect(File.read(claude_md_path)).to eq(duplicated)
      expect(File).not_to exist(shim_path)
      expect(File).not_to exist(settings_path)
    end

    it 'refuses with zero writes when CLAUDE.md has reversed END-before-BEGIN markers (criterion 3)' do
      reversed = "<!-- END TYRION-MANAGED-BLOCK -->\nsome text\n<!-- BEGIN TYRION-MANAGED-BLOCK v1 sha256:#{'c' * 64} -->\nbody\n"
      FileUtils.mkdir_p(File.dirname(claude_md_path))
      File.write(claude_md_path, reversed)

      expect { Tyrion::Commands.cmd_setup_claude([], store) }
        .to raise_error(having_attributes(status: 1)).and output(/refusing to install/).to_stderr

      expect(File.read(claude_md_path)).to eq(reversed)
      expect(File).not_to exist(shim_path)
      expect(File).not_to exist(settings_path)
    end

    it 'refuses with zero writes when CLAUDE.md has an unpaired BEGIN marker with no END (criterion 3)' do
      unpaired = "<!-- BEGIN TYRION-MANAGED-BLOCK v1 sha256:#{'d' * 64} -->\nbody with no closing marker\n"
      FileUtils.mkdir_p(File.dirname(claude_md_path))
      File.write(claude_md_path, unpaired)

      expect { Tyrion::Commands.cmd_setup_claude([], store) }
        .to raise_error(having_attributes(status: 1)).and output(/refusing to install/).to_stderr

      expect(File.read(claude_md_path)).to eq(unpaired)
      expect(File).not_to exist(shim_path)
      expect(File).not_to exist(settings_path)
    end

    it 'refuses with zero writes when CLAUDE.md has a nested-looking duplicate BEGIN before the matching END (criterion 3)' do
      nested = "<!-- BEGIN TYRION-MANAGED-BLOCK v1 sha256:#{'e' * 64} -->\n" \
               "<!-- BEGIN TYRION-MANAGED-BLOCK v1 sha256:#{'f' * 64} -->\n" \
               "body\n<!-- END TYRION-MANAGED-BLOCK -->\n<!-- END TYRION-MANAGED-BLOCK -->\n"
      FileUtils.mkdir_p(File.dirname(claude_md_path))
      File.write(claude_md_path, nested)

      expect { Tyrion::Commands.cmd_setup_claude([], store) }
        .to raise_error(having_attributes(status: 1)).and output(/refusing to install/).to_stderr

      expect(File.read(claude_md_path)).to eq(nested)
      expect(File).not_to exist(shim_path)
      expect(File).not_to exist(settings_path)
    end
  end
end
