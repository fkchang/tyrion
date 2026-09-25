# frozen_string_literal: true

require 'spec_helper'

# The fold answers one question per active-or-paused epic: waiting (someone
# already decided), stalled (nobody decided anything and it went quiet), or
# fine (out of the list entirely). Most of what's asserted here is which
# epics the fold refuses to flag, since a false "stalled" sends someone to
# poke at work that's actually fine, and a false "fine" hides real neglect.
ATTENTION_NOW = Time.utc(2026, 9, 25, 12, 0, 0)

RSpec.describe Tyrion::Attention do
  def iso(seconds_ago) = (ATTENTION_NOW - seconds_ago).utc.iso8601(6)

  # `**over` is keyword-style (`a_story(status: 'blocked')`) but the row shape
  # underneath is string-keyed (matches what Store actually returns) -- so the
  # override keys are normalized to strings before merging, or a symbol-keyed
  # override would silently coexist with its string-keyed default instead of
  # replacing it.
  def a_story(**over)
    {
      'id' => 'st-1', 'slug' => 's1', 'title' => 'Story One', 'sequence' => 1,
      'status' => 'pending', 'next_action' => nil, 'claimed_by' => nil,
      'blocked_on' => nil, 'blocked_on_discovery' => nil,
      'last_note_at' => nil, 'updated_at' => iso(0), 'completed_at' => nil, 'claimed_at' => nil
    }.merge(over.transform_keys(&:to_s))
  end

  def gathered(epic_over: {}, counts_over: {}, stories: [])
    epic = { 'id' => 'ep-1', 'slug' => 'my-epic', 'name' => 'My Epic', 'status' => 'active', 'mode' => nil }.merge(epic_over)
    counts = { 'total' => 0, 'pending' => 0, 'in_progress' => 0, 'blocked' => 0, 'done' => 0, 'abandoned' => 0 }.merge(counts_over)
    {
      'project' => { 'id' => 'proj-1', 'slug' => 'myproj', 'name' => 'My Project' },
      'epic' => epic, 'counts' => counts, 'stories' => stories
    }
  end

  def epic_row(lanes_by_story: {}, stale_days: 7, **kwargs)
    described_class.epic_row(gathered(**kwargs), lanes_by_story, now: ATTENTION_NOW, stale_days: stale_days)
  end

  describe '.epic_row -- classification' do
    it 'is nil (fine) for a fully unstarted epic no matter how old' do
      row = epic_row(counts_over: { 'total' => 2, 'pending' => 2 },
                      stories: [a_story(status: 'pending', updated_at: iso(400 * 86_400))])
      expect(row).to be_nil
    end

    it 'is nil (fine) for a fully done epic' do
      row = epic_row(counts_over: { 'total' => 2, 'done' => 2 },
                      stories: [a_story(status: 'done', updated_at: iso(400 * 86_400))])
      expect(row).to be_nil
    end

    it 'is nil (fine) for a partially-done epic that is still recently active' do
      row = epic_row(counts_over: { 'total' => 2, 'done' => 1, 'pending' => 1 },
                      stories: [a_story(status: 'pending', updated_at: iso(3600))])
      expect(row).to be_nil
    end

    it 'is stalled for a partially-done, active epic idle past the threshold' do
      row = epic_row(counts_over: { 'total' => 2, 'done' => 1, 'pending' => 1 },
                      stories: [a_story(status: 'pending', updated_at: iso(8 * 86_400))])
      expect(row['category']).to eq 'stalled'
      expect(row['idle_days']).to eq 8
      expect(row['counts']).to eq('done' => 1, 'pending' => 1, 'in_progress' => 0, 'blocked' => 0, 'total' => 2)
    end

    it 'counts in_progress (not just pending) remaining work toward "partial", same as pending' do
      row = epic_row(counts_over: { 'total' => 2, 'done' => 1, 'in_progress' => 1 },
                      stories: [a_story(status: 'in_progress', updated_at: iso(8 * 86_400))])
      expect(row['category']).to eq 'stalled'
    end
  end

  describe 'threshold edges' do
    def row_at(idle_seconds, stale_days: 7)
      epic_row(counts_over: { 'total' => 2, 'done' => 1, 'pending' => 1 },
               stories: [a_story(status: 'pending', updated_at: iso(idle_seconds))],
               stale_days: stale_days)
    end

    it 'does not stall exactly at the threshold ("longer than", not "at least")' do
      expect(row_at(7 * 86_400)).to be_nil
    end

    it 'stalls one second past the threshold' do
      row = row_at((7 * 86_400) + 1)
      expect(row['category']).to eq 'stalled'
    end

    it 'honors a custom --stale-days threshold' do
      expect(row_at(2 * 86_400, stale_days: 3)).to be_nil
      expect(row_at((3 * 86_400) + 1, stale_days: 3)['category']).to eq 'stalled'
    end
  end

  describe 'waiting always wins over stalled' do
    it 'is waiting for a paused epic even when otherwise unstarted' do
      row = epic_row(epic_over: { 'status' => 'paused' },
                      counts_over: { 'total' => 1, 'pending' => 1 },
                      stories: [a_story(status: 'pending')])
      expect(row['category']).to eq 'waiting'
      expect(row['waiting_reasons']).to eq ['paused']
    end

    it 'is waiting for a paused epic that also looks stalled, never stalled' do
      row = epic_row(epic_over: { 'status' => 'paused' },
                      counts_over: { 'total' => 2, 'done' => 1, 'pending' => 1 },
                      stories: [a_story(status: 'pending', updated_at: iso(400 * 86_400))])
      expect(row['category']).to eq 'waiting'
    end

    it 'is waiting when a story is blocked, with the reason and discovery id surfaced' do
      row = epic_row(counts_over: { 'total' => 2, 'done' => 1, 'blocked' => 1 },
                      stories: [
                        a_story(slug: 'blocked-one', status: 'blocked', blocked_on: 'waiting on API keys',
                                blocked_on_discovery: 'disc-042', updated_at: iso(400 * 86_400))
                      ])
      expect(row['category']).to eq 'waiting'
      expect(row['waiting_reasons']).to eq ['blocked-one: waiting on API keys [disc-042]']
    end

    it 'is waiting (not stalled) for an active epic with a blocked story that is also idle' do
      row = epic_row(counts_over: { 'total' => 3, 'done' => 1, 'pending' => 1, 'blocked' => 1 },
                      stories: [
                        a_story(slug: 'p', status: 'pending', updated_at: iso(400 * 86_400)),
                        a_story(slug: 'b', status: 'blocked', blocked_on: nil, updated_at: iso(400 * 86_400))
                      ])
      expect(row['category']).to eq 'waiting'
      expect(row['waiting_reasons']).to eq ['b: no reason recorded']
    end
  end

  describe 'current_story and lanes' do
    it 'surfaces the most recently active in_progress story over an idle pending one' do
      row = epic_row(
        counts_over: { 'total' => 3, 'done' => 1, 'pending' => 1, 'in_progress' => 1 },
        stories: [
          a_story(slug: 'old-pending', status: 'pending', sequence: 1, updated_at: iso(400 * 86_400)),
          a_story(slug: 'active-one', status: 'in_progress', sequence: 2, next_action: 'finish the thing',
                   claimed_by: 'claude:34795:aaaaaaaaaaaaaaaa', updated_at: iso(400 * 86_400))
        ]
      )
      expect(row['current_story']).to eq('slug' => 'active-one', 'title' => 'Story One', 'next_action' => 'finish the thing')
    end

    it 'falls back to the earliest pending story by sequence when nothing is in_progress' do
      row = epic_row(
        counts_over: { 'total' => 3, 'done' => 1, 'pending' => 2 },
        stories: [
          a_story(slug: 'second', status: 'pending', sequence: 2, updated_at: iso(400 * 86_400)),
          a_story(slug: 'first', status: 'pending', sequence: 1, updated_at: iso(400 * 86_400))
        ]
      )
      expect(row['current_story']['slug']).to eq 'first'
    end

    it 'parses a pid only from a claude:<pid>:<stamp> token, and reports live from the snapshot row' do
      lanes_by_story = { 'st-live' => { 'story_id' => 'st-live', 'signals' => { 'process' => 'live' }, 'worktree_path' => '/repo/wt' } }
      row = epic_row(
        counts_over: { 'total' => 2, 'done' => 1, 'pending' => 1 },
        stories: [a_story(id: 'st-live', slug: 'claude-lane', status: 'in_progress',
                           claimed_by: 'claude:34795:aaaaaaaaaaaaaaaa', updated_at: iso(400 * 86_400))],
        lanes_by_story: lanes_by_story
      )
      lane = row['lanes'].first
      expect(lane).to eq('token' => 'claude:34795:aaaaaaaaaaaaaaaa', 'pid' => 34_795, 'live' => true,
                          'story_slug' => 'claude-lane', 'worktree_path' => '/repo/wt')
    end

    it 'reports a nil pid for non-claude token shapes (codex threads, dispatched placeholders)' do
      row = epic_row(
        counts_over: { 'total' => 2, 'done' => 1, 'pending' => 1 },
        stories: [
          a_story(id: 'st-codex', slug: 'codex-lane', status: 'in_progress',
                   claimed_by: 'codex:9c8b7a', updated_at: iso(400 * 86_400)),
          a_story(id: 'st-dispatched', slug: 'dispatched-lane', status: 'in_progress',
                   claimed_by: 'dispatched:some-label', updated_at: iso(400 * 86_400))
        ]
      )
      pids = row['lanes'].to_h { |l| [l['story_slug'], l['pid']] }
      expect(pids).to eq('codex-lane' => nil, 'dispatched-lane' => nil)
    end

    it 'reports live: false when no snapshot row exists for the story (dead/unprobed lane)' do
      row = epic_row(
        counts_over: { 'total' => 2, 'done' => 1, 'pending' => 1 },
        stories: [a_story(id: 'st-x', slug: 'x', status: 'in_progress',
                           claimed_by: 'claude:1:aaaaaaaaaaaaaaaa', updated_at: iso(400 * 86_400))],
        lanes_by_story: {}
      )
      expect(row['lanes'].first['live']).to eq false
      expect(row['lanes'].first['worktree_path']).to be_nil
    end

    it 'omits unclaimed in_progress stories from lanes even though the epic itself still qualifies as stalled' do
      row = epic_row(
        counts_over: { 'total' => 2, 'done' => 1, 'in_progress' => 1 },
        stories: [a_story(slug: 'unclaimed', status: 'in_progress', claimed_by: nil, updated_at: iso(400 * 86_400))]
      )
      expect(row['category']).to eq 'stalled'
      expect(row['lanes']).to eq []
    end
  end

  describe '.build -- sorting and summary' do
    def gathered_stalled(slug, mode: nil, idle_seconds:)
      gathered(epic_over: { 'id' => "ep-#{slug}", 'slug' => slug, 'mode' => mode },
               counts_over: { 'total' => 2, 'done' => 1, 'pending' => 1 },
               stories: [a_story(id: "st-#{slug}", slug: "story-#{slug}", status: 'pending', updated_at: iso(idle_seconds))])
    end

    def gathered_fine(slug)
      gathered(epic_over: { 'id' => "ep-#{slug}", 'slug' => slug },
               counts_over: { 'total' => 1, 'pending' => 1 },
               stories: [a_story(id: "st-#{slug}", slug: "story-#{slug}", status: 'pending', updated_at: iso(0))])
    end

    def gathered_waiting(slug)
      gathered(epic_over: { 'id' => "ep-#{slug}", 'slug' => slug, 'status' => 'paused' },
               counts_over: { 'total' => 1, 'pending' => 1 },
               stories: [a_story(id: "st-#{slug}", slug: "story-#{slug}", status: 'pending', updated_at: iso(0))])
    end

    it 'sorts stalled epics dark_factory-first, then longest idle first, and lists waiting after' do
      report = described_class.build(
        [
          gathered_stalled('shape-short', idle_seconds: 8 * 86_400),
          gathered_stalled('dark-long', mode: 'dark_factory', idle_seconds: 30 * 86_400),
          gathered_stalled('shape-long', idle_seconds: 20 * 86_400),
          gathered_waiting('paused-one'),
          gathered_fine('fine-one')
        ],
        now: ATTENTION_NOW
      )

      expect(report['epics'].map { |e| e['epic_slug'] })
        .to eq %w[dark-long shape-long shape-short paused-one]
      expect(report['summary']).to eq('stalled' => 3, 'waiting' => 1, 'fine' => 1)
      expect(report['stale_days']).to eq 7
      expect(report['generated_at']).to eq ATTENTION_NOW.utc.iso8601
    end

    it 'filters to one project when project_slug is given' do
      other_project = gathered_stalled('other-proj-epic', idle_seconds: 10 * 86_400)
                       .merge('project' => { 'id' => 'proj-2', 'slug' => 'otherproj', 'name' => 'Other' })
      report = described_class.build(
        [gathered_stalled('mine', idle_seconds: 10 * 86_400), other_project],
        now: ATTENTION_NOW, project_slug: 'myproj'
      )
      expect(report['epics'].map { |e| e['epic_slug'] }).to eq ['mine']
      expect(report['summary']).to eq('stalled' => 1, 'waiting' => 0, 'fine' => 0)
    end
  end
end
