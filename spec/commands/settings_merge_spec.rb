# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'settings merge engine' do
  # ── fixtures ───────────────────────────────────────────────────────────

  def tyrion_command_for(*subcmd)
    %("$CLAUDE_PROJECT_DIR"/#{Tyrion::Commands::SHIM_INSTALL_PATH} #{subcmd.join(' ')})
  end

  let(:foreign_group) do
    { 'matcher' => '', 'hooks' => [{ 'type' => 'command', 'command' => 'echo hi' }] }
  end

  let(:stale_tyrion_group) do
    # Simulates an older shim path reference (pre-shim, direct hook script call).
    { 'matcher' => 'Bash',
      'hooks' => [{ 'type' => 'command', 'command' => '"$CLAUDE_PROJECT_DIR"/.claude/hooks/tyrion-shim.sh tyrion hook OLD-SUBCMD' }] }
  end

  # ── merge_hook_groups ─────────────────────────────────────────────────────

  describe '.merge_hook_groups' do
    let(:tyrion_group) do
      { 'matcher' => 'Bash', 'hooks' => [{ 'type' => 'command', 'command' => tyrion_command_for('tyrion', 'hook', 'claim-gate') }] }
    end

    it 'appends when existing is nil (absent event)' do
      result = Tyrion::Commands.merge_hook_groups(nil, tyrion_group)
      expect(result).to eq([tyrion_group])
    end

    it 'appends when existing is empty' do
      result = Tyrion::Commands.merge_hook_groups([], tyrion_group)
      expect(result).to eq([tyrion_group])
    end

    it 'appends after foreign groups, preserving them untouched' do
      result = Tyrion::Commands.merge_hook_groups([foreign_group], tyrion_group)
      expect(result).to eq([foreign_group, tyrion_group])
    end

    it 'replaces a stale tyrion-owned group in place (same array position)' do
      other_foreign = { 'matcher' => 'Write', 'hooks' => [{ 'type' => 'command', 'command' => 'echo write' }] }
      result = Tyrion::Commands.merge_hook_groups([other_foreign, stale_tyrion_group], tyrion_group)
      expect(result).to eq([other_foreign, tyrion_group])
      expect(result[1]).to equal(tyrion_group)
    end

    it 'does not mutate the input array' do
      input = [foreign_group]
      Tyrion::Commands.merge_hook_groups(input, tyrion_group)
      expect(input).to eq([foreign_group])
    end

    it 'does not touch a tyrion-owned-looking group under a different matcher' do
      different_matcher_tyrion = stale_tyrion_group.merge('matcher' => 'Write')
      result = Tyrion::Commands.merge_hook_groups([different_matcher_tyrion], tyrion_group)
      expect(result).to eq([different_matcher_tyrion, tyrion_group])
    end
  end

  # ── merge_settings_hooks ──────────────────────────────────────────────────

  describe '.merge_settings_hooks' do
    it 'builds all three tyrion hook groups when hooks key is absent' do
      result = Tyrion::Commands.merge_settings_hooks({})
      hooks = result['hooks']
      expect(hooks.keys).to eq(%w[SessionStart PreCompact PreToolUse])
      expect(hooks['SessionStart']).to eq(
        [{ 'matcher' => '', 'hooks' => [{ 'type' => 'command', 'command' => tyrion_command_for('tyrion', 'prime') }] }]
      )
      expect(hooks['PreCompact']).to eq(
        [{ 'matcher' => '', 'hooks' => [{ 'type' => 'command', 'command' => tyrion_command_for('tyrion', 'prime') }] }]
      )
      expect(hooks['PreToolUse']).to eq(
        [{ 'matcher' => 'Bash', 'hooks' => [{ 'type' => 'command', 'command' => tyrion_command_for('tyrion', 'hook', 'claim-gate') }] }]
      )
    end

    it 'preserves a foreign event key untouched, in original key order' do
      original = {
        'hooks' => {
          'Stop' => [{ 'matcher' => '', 'hooks' => [{ 'type' => 'command', 'command' => 'echo stop' }] }],
          'SessionStart' => [foreign_group]
        }
      }
      result = Tyrion::Commands.merge_settings_hooks(original)
      expect(result['hooks'].keys).to eq(%w[Stop SessionStart PreCompact PreToolUse])
      expect(result['hooks']['Stop']).to eq(original['hooks']['Stop'])
      expect(result['hooks']['SessionStart']).to include(foreign_group)
    end

    it 'preserves other top-level keys unchanged' do
      original = { 'permissions' => { 'allow' => ['Bash(ls)'] }, 'someOtherKey' => 42 }
      result = Tyrion::Commands.merge_settings_hooks(original)
      expect(result['permissions']).to eq('allow' => ['Bash(ls)'])
      expect(result['someOtherKey']).to eq(42)
    end

    it 'does not mutate the input hash' do
      original = { 'hooks' => { 'Stop' => [foreign_group] } }
      Tyrion::Commands.merge_settings_hooks(original)
      expect(original['hooks'].keys).to eq(['Stop'])
    end
  end

  # ── validate_settings_shape ───────────────────────────────────────────────

  describe '.validate_settings_shape' do
    it 'accepts an empty hash' do
      expect(Tyrion::Commands.validate_settings_shape({})).to be true
    end

    it 'accepts a well-formed hash' do
      settings = {
        'hooks' => { 'PreToolUse' => [{ 'matcher' => 'Bash', 'hooks' => [{ 'type' => 'command', 'command' => 'x' }] }] },
        'permissions' => { 'allow' => ['Bash(ls)'] }
      }
      expect(Tyrion::Commands.validate_settings_shape(settings)).to be true
    end

    it 'rejects hooks as a non-Hash (Array)' do
      expect(Tyrion::Commands.validate_settings_shape({ 'hooks' => [] })).to be false
    end

    it 'rejects hooks as a non-Hash (String)' do
      expect(Tyrion::Commands.validate_settings_shape({ 'hooks' => 'nope' })).to be false
    end

    it "rejects an event's value that isn't an Array" do
      expect(Tyrion::Commands.validate_settings_shape({ 'hooks' => { 'PreToolUse' => {} } })).to be false
    end

    it "rejects a matcher-group that isn't a Hash" do
      expect(Tyrion::Commands.validate_settings_shape({ 'hooks' => { 'PreToolUse' => ['not-a-hash'] } })).to be false
    end

    it "rejects a matcher-group whose inner hooks key isn't an Array" do
      settings = { 'hooks' => { 'PreToolUse' => [{ 'matcher' => 'Bash', 'hooks' => 'nope' }] } }
      expect(Tyrion::Commands.validate_settings_shape(settings)).to be false
    end

    it "rejects permissions that isn't a Hash" do
      expect(Tyrion::Commands.validate_settings_shape({ 'permissions' => [] })).to be false
    end

    it "rejects permissions.allow that isn't an Array" do
      expect(Tyrion::Commands.validate_settings_shape({ 'permissions' => { 'allow' => 'nope' } })).to be false
    end
  end

  # ── load_settings_for_merge ───────────────────────────────────────────────

  describe '.load_settings_for_merge' do
    around do |example|
      Dir.mktmpdir('tyrion-settings-merge') { |dir| @tmpdir = dir; example.run }
    end

    it 'returns {} for an absent file' do
      path = File.join(@tmpdir, 'nope.json')
      expect(Tyrion::Commands.load_settings_for_merge(path)).to eq({})
    end

    it 'returns the parsed hash for valid JSON' do
      path = File.join(@tmpdir, 'settings.json')
      File.write(path, '{"permissions": {"allow": ["Bash(ls)"]}}')
      expect(Tyrion::Commands.load_settings_for_merge(path)).to eq('permissions' => { 'allow' => ['Bash(ls)'] })
    end

    it 'raises InvalidSettingsError for invalid JSON syntax' do
      path = File.join(@tmpdir, 'settings.json')
      File.write(path, '{not valid json')
      expect { Tyrion::Commands.load_settings_for_merge(path) }
        .to raise_error(Tyrion::Commands::InvalidSettingsError, /Invalid JSON/)
    end
  end

  # ── whitelist fold-in + composed build_merged_settings ──────────────────

  describe '.build_merged_settings' do
    it 'produces the three tyrion hook groups plus whitelist entries from empty settings' do
      result = Tyrion::Commands.build_merged_settings({})
      expect(result['hooks'].keys).to eq(%w[SessionStart PreCompact PreToolUse])
      expect(result['permissions']['allow']).to eq(Tyrion::Commands::TYRION_PERMISSIONS)
    end

    it 'preserves existing unrelated hooks/permissions/unknown top-level keys, in original order' do
      original = {
        'hooks' => { 'Stop' => [foreign_group] },
        'permissions' => { 'allow' => ['Bash(ls)'] },
        'unknownKey' => 'preserve-me'
      }
      result = Tyrion::Commands.build_merged_settings(original)
      expect(result['hooks']['Stop']).to eq([foreign_group])
      expect(result['permissions']['allow']).to eq(['Bash(ls)'] + Tyrion::Commands::TYRION_PERMISSIONS)
      expect(result['unknownKey']).to eq('preserve-me')
    end

    it 'is additive and de-duplicating for whitelist entries already present' do
      original = { 'permissions' => { 'allow' => Tyrion::Commands::TYRION_PERMISSIONS.dup } }
      result = Tyrion::Commands.build_merged_settings(original)
      expect(result['permissions']['allow']).to eq(Tyrion::Commands::TYRION_PERMISSIONS)
    end

    it 'replaces a stale tyrion-owned PreToolUse group in place rather than duplicating' do
      original = { 'hooks' => { 'PreToolUse' => [stale_tyrion_group] } }
      result = Tyrion::Commands.build_merged_settings(original)
      expect(result['hooks']['PreToolUse'].length).to eq(1)
      expect(result['hooks']['PreToolUse'].first['hooks'].first['command']).to eq(tyrion_command_for('tyrion', 'hook', 'claim-gate'))
    end

    it 'raises InvalidSettingsError and signals refusal for each malformed shape' do
      [
        { 'hooks' => [] },
        { 'hooks' => 'nope' },
        { 'hooks' => { 'PreToolUse' => {} } },
        { 'hooks' => { 'PreToolUse' => ['not-a-hash'] } },
        { 'hooks' => { 'PreToolUse' => [{ 'matcher' => 'Bash', 'hooks' => 'nope' }] } },
        { 'permissions' => [] },
        { 'permissions' => { 'allow' => 'nope' } }
      ].each do |malformed|
        expect { Tyrion::Commands.build_merged_settings(malformed) }
          .to raise_error(Tyrion::Commands::InvalidSettingsError), "expected refusal for #{malformed.inspect}"
      end
    end
  end

  # ── idempotency ───────────────────────────────────────────────────────────

  describe 'idempotency' do
    def pretty(hash) = JSON.pretty_generate(hash)

    it 'is idempotent for empty settings' do
      once  = Tyrion::Commands.build_merged_settings({})
      twice = Tyrion::Commands.build_merged_settings(once)
      expect(pretty(twice)).to eq(pretty(once))
    end

    it 'is idempotent for settings with foreign hooks/permissions already present' do
      seed = {
        'hooks' => { 'Stop' => [foreign_group] },
        'permissions' => { 'allow' => ['Bash(ls)'] },
        'unknownKey' => 'preserve-me'
      }
      once  = Tyrion::Commands.build_merged_settings(seed)
      twice = Tyrion::Commands.build_merged_settings(once)
      expect(pretty(twice)).to eq(pretty(once))
    end

    it 'is idempotent for settings with a stale tyrion-owned entry from an older shim path/version' do
      seed = { 'hooks' => { 'PreToolUse' => [stale_tyrion_group] } }
      once  = Tyrion::Commands.build_merged_settings(seed)
      twice = Tyrion::Commands.build_merged_settings(once)
      expect(pretty(twice)).to eq(pretty(once))
    end
  end
end
