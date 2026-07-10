# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'json'

# Integration coverage for hooks/claim-gate.sh. The hook runs as its own
# process, so these examples set up real on-disk .tyrion/ state + a temp DB and
# pipe fabricated Claude Code PreToolUse JSON at the script, asserting exit codes.
RSpec.describe 'hooks/claim-gate.sh' do
  HOOK = File.expand_path('../../hooks/claim-gate.sh', __dir__)
  LANE = 'lane-test'

  # Run the hook with +command+ as the Bash tool_input, in +cwd+, against +db_path+.
  def run_hook(command:, cwd:, db_path:)
    payload = { tool_name: 'Bash', tool_input: { command: command } }.to_json
    Open3.capture3({ 'TYRION_DB_PATH' => db_path }, HOOK, chdir: cwd, stdin_data: payload)
  end

  around do |example|
    Dir.mktmpdir('claim-gate-spec-') do |dir|
      @dir = dir
      @db  = File.join(dir, 'test.db')
      example.run
    end
  end

  # Build a Tyrion project + epic in the temp DB and mark it the active worktree.
  # Returns the created story hash. When +started_by+ is given, the story is
  # claimed in_progress under that lane token.
  def seed_project(started_by: nil)
    store   = Tyrion::Store.new(db_path: @db)
    project = store.create_project(slug: 'proj', name: 'Proj')
    epic    = store.create_epic(project_id: project['id'], slug: 'epic', name: 'Epic')
    story   = store.create_story(epic_id: epic['id'], slug: 'story-a', title: 'Story A')

    FileUtils.mkdir_p(File.join(@dir, '.tyrion'))
    File.write(File.join(@dir, '.tyrion', 'marker'), '')
    File.write(File.join(@dir, '.tyrion', 'active-project'), "proj\n")
    File.write(File.join(@dir, '.tyrion', 'active-epic'), "epic\n")

    store.start_story(story['id'], claimed_by: started_by) if started_by
    story
  end

  it 'exits 2 and tells the agent to claim first when the lane has no in_progress story' do
    seed_project # story left pending
    _out, err, status = run_hook(
      command: "TYRION_LANE=#{LANE} ruby bin/tyrion note story-a progress 'x'",
      cwd: @dir, db_path: @db
    )
    expect(status.exitstatus).to eq 2
    expect(err).to match(/tyrion start/)
  end

  it 'exits 0 when the active lane owns an in_progress story' do
    seed_project(started_by: LANE)
    _out, _err, status = run_hook(
      command: "TYRION_LANE=#{LANE} ruby bin/tyrion note story-a progress 'x'",
      cwd: @dir, db_path: @db
    )
    expect(status.exitstatus).to eq 0
  end

  it 'exits 0 for a non-tyrion Bash command regardless of lane state' do
    seed_project # pending story, no in_progress
    _out, _err, status = run_hook(
      command: 'ls -la /tmp',
      cwd: @dir, db_path: @db
    )
    expect(status.exitstatus).to eq 0
  end

  it 'exits 0 for a non-gated tyrion subcommand (only note/check/done are gated)' do
    seed_project # pending story, no in_progress
    _out, _err, status = run_hook(
      command: "TYRION_LANE=#{LANE} ruby bin/tyrion status",
      cwd: @dir, db_path: @db
    )
    expect(status.exitstatus).to eq 0
  end

  it 'exits 0 when the gated verb only appears inside a quoted string' do
    seed_project # pending story, no in_progress — the gate would block a real tyrion note
    _out, _err, status = run_hook(
      command: %(git commit -m "tyrion note: wire up the claim gate"),
      cwd: @dir, db_path: @db
    )
    expect(status.exitstatus).to eq 0
  end

  it 'exits 0 via the unclaimed fallback when the active epic has an in_progress story and no lane is named' do
    story = seed_project
    Tyrion::Store.new(db_path: @db).start_story(story['id'], claimed_by: nil) # legacy unclaimed
    _out, _err, status = run_hook(
      command: 'ruby bin/tyrion note story-a progress x', # no TYRION_LANE prefix
      cwd: @dir, db_path: @db
    )
    expect(status.exitstatus).to eq 0
  end

  it 'exits 0 (fail-open) when run outside a Tyrion project' do
    # @dir has no .tyrion/marker — a tyrion command here must still pass through.
    _out, _err, status = run_hook(
      command: "TYRION_LANE=#{LANE} ruby bin/tyrion note story-a progress 'x'",
      cwd: @dir, db_path: @db
    )
    expect(status.exitstatus).to eq 0
  end
end
