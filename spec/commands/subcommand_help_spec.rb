# frozen_string_literal: true

require 'spec_helper'

# Shared coverage for Tyrion::Commands.route_subcommand — the one helper every
# subcommand-group command (project, epic, discovery, spike, criteria,
# followup, lesson, setup, hook, whitelist, epic depends, depends, wave) now
# routes through instead of each hand-rolling its own --help/unknown-subcommand
# handling. Table-driven (a local, not a constant — a second file naming
# `GROUPS` would collide with a constant defined here) so the next group added
# to the list below is covered for free, and a regression in the shared helper
# fails once here instead of once per group's own spec file.
RSpec.describe 'tyrion <group> --help (route_subcommand)' do
  let(:ctx)   { tyrion_worktree }
  let(:store) { ctx.store }

  groups = {
    'project'      => [:cmd_project,      Tyrion::Commands::PROJECT_USAGE],
    'epic'         => [:cmd_epic,         Tyrion::Commands::EPIC_USAGE],
    'discovery'    => [:cmd_discovery,    Tyrion::Commands::DISCOVERY_USAGE],
    'spike'        => [:cmd_spike,        Tyrion::Commands::SPIKE_USAGE],
    'criteria'     => [:cmd_criteria,     Tyrion::Commands::CRITERIA_USAGE],
    'followup'     => [:cmd_followup,     Tyrion::Commands::FOLLOWUP_USAGE],
    'lesson'       => [:cmd_lesson,       Tyrion::Commands::LESSON_USAGE],
    'setup'        => [:cmd_setup,        Tyrion::Commands::SETUP_USAGE],
    'hook'         => [:cmd_hook,         Tyrion::Commands::HOOK_USAGE],
    'whitelist'    => [:cmd_whitelist,    Tyrion::Commands::WHITELIST_USAGE],
    'epic depends' => [:cmd_epic_depends, Tyrion::Commands::EPIC_DEPENDS_USAGE],
    'depends'      => [:cmd_depends,      Tyrion::Commands::DEPENDS_USAGE],
    'wave'         => [:cmd_wave,         Tyrion::Commands::WAVE_USAGE]
  }

  groups.each do |name, (method_name, usage)|
    describe "tyrion #{name} --help" do
      it 'prints usage on stdout and exits cleanly (not an error)' do
        out, err = capture_io { Tyrion::Commands.public_send(method_name, ['--help'], store) }

        expect(out).to eq("#{usage}\n")
        expect(err).to eq('')
      end

      it 'also recognizes -h' do
        out, = capture_io { Tyrion::Commands.public_send(method_name, ['-h'], store) }

        expect(out).to eq("#{usage}\n")
      end
    end

    describe "tyrion #{name} bogus" do
      it 'still dies (exit 1) with the group usage on stderr' do
        _out, err = capture_io do
          expect { Tyrion::Commands.public_send(method_name, ['bogus'], store) }.to raise_error(SystemExit)
        end

        expect(err).to include(usage.lines.first.strip)
      end
    end
  end

  # whitelist is the one group where a bare invocation has a real default
  # subcommand ('show') rather than dying — confirm centralizing --help
  # through route_subcommand didn't disturb that default.
  it 'tyrion whitelist (bare) still defaults to show, not an error' do
    out, = capture_io { Tyrion::Commands.cmd_whitelist([], store) }

    expect(out).to match(/whitelist status/)
  end

  # spike's --help predates this generalization and explicitly also accepted
  # the bare word 'help' (unlike free-text-eating leaf commands, a subcommand
  # token is never plausible real content) — confirm the shared helper kept it.
  it "tyrion spike help (bare word) works too, not just the flag forms" do
    out, = capture_io { Tyrion::Commands.cmd_spike(['help'], store) }

    expect(out).to eq("#{Tyrion::Commands::SPIKE_USAGE}\n")
  end

  # route_subcommand only recognizes --help as the subcommand token itself
  # (`tyrion setup --help`), not anywhere later in a group's remaining args —
  # so a leaf reached *after* a real subcommand is matched, and that has a
  # side effect, must guard itself. These are the two that do (cmd_setup_claude
  # writes a shim + settings.json + CLAUDE.md; whitelist_add/remove write
  # settings.json) — regression coverage for the actual disc-092-class bug
  # this generalization was chasing, not just the group-level --help text.
  describe 'tyrion setup claude --help' do
    it 'prints usage and touches no files' do
      expect(Tyrion::Repo).not_to receive(:worktree_root)

      out, = capture_io { Tyrion::Commands.cmd_setup(%w[claude --help], store) }

      expect(out).to match(/Usage: tyrion setup claude/)
    end
  end

  describe 'tyrion whitelist add --help' do
    it 'prints usage and writes no settings file' do
      expect(Tyrion::Commands).not_to receive(:load_settings)
      expect(Tyrion::Commands).not_to receive(:write_settings)

      out, = capture_io { Tyrion::Commands.cmd_whitelist(%w[add --help], store) }

      expect(out).to match(/Usage: tyrion whitelist/)
    end
  end

  # cmd_project_new has no entity lookup to catch a bad token before writing
  # (unlike e.g. epic activate), so a stray --help would otherwise be written
  # straight into the new project's slug or name.
  describe 'tyrion project new --help' do
    it 'prints usage and creates no project' do
      before_count = store.list_projects.length

      out, = capture_io { Tyrion::Commands.cmd_project(%w[new --help], store) }

      expect(out).to eq("#{Tyrion::Commands::PROJECT_USAGE}\n")
      expect(store.list_projects.length).to eq before_count
    end
  end

  describe 'tyrion setup-codex --help' do
    it 'prints usage and touches no files' do
      store # materialise the worktree fixture (its own setup uses FileUtils.mkdir_p) first
      expect(FileUtils).not_to receive(:mkdir_p)
      expect(File).not_to receive(:symlink)

      out, = capture_io { Tyrion::Commands.cmd_setup_codex(['--help'], store) }

      expect(out).to eq("#{Tyrion::Commands::SETUP_CODEX_USAGE}\n")
    end
  end
end
