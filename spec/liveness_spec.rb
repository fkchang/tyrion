# frozen_string_literal: true

require 'spec_helper'

# The ladder is the product. A false "alive" hides a crashed builder and a false
# "dead" sends someone to restart a lane that was working fine, so most of what
# is asserted here is about what the derivation refuses to claim.
LIVENESS_NOW = Time.utc(2026, 9, 1, 12, 0, 0)

RSpec.describe Tyrion::Liveness do
  def iso(seconds_ago) = (LIVENESS_NOW - seconds_ago).utc.iso8601(6)

  # A lane in the shape the snapshot hands over: ledger row + process probe +
  # resolver result + worktree signals, each source reporting nil independently.
  def lane(**over)
    {
      'story_id' => 'st-1', 'slug' => 'a-story', 'status' => 'in_progress',
      'claimed_by' => 'v0-A:1234:aaaaaaaaaaaaaaaa',
      'epic_slug' => 'e1', 'project_slug' => 'p1', 'project_id' => 'proj-1',
      'started_at' => iso(3600), 'updated_at' => iso(3600), 'last_note_at' => nil,
      'note' => nil, 'gate' => nil, 'commit' => nil, 'criterion' => nil,
      'liveness' => :unknown,
      'resolution' => { 'state' => 'resolved', 'path' => '/repo/wt', 'paths' => ['/repo/wt'] },
      'worktree' => { 'dirty_count' => 0, 'newest_dirty_mtime' => nil, 'commit_at' => (LIVENESS_NOW - 3600).to_i,
                      'commit_subject' => 'init', 'commit_sha' => 'abc', 'partial' => false }
    }.merge(over)
  end

  def row(**over) = described_class.lane_row(lane(**over), now: LIVENESS_NOW)

  describe 'process liveness' do
    it 'yields state dead at severity 1 when the process probe says :dead' do
      r = row('liveness' => :dead)

      expect(r['state']).to eq 'dead'
      expect(described_class.attention_items([r]).first['severity']).to eq 1
    end

    it 'never treats :unknown as dead — the ladder simply ignores the process source' do
      recent = row('liveness' => :unknown, 'last_note_at' => iso(30))
      old    = row('liveness' => :unknown, 'last_note_at' => iso(3600))

      expect(recent['state']).to eq 'live'
      expect(old['state']).to eq 'stalled'
      expect([recent, old].map { |r| r['signals']['process'] }).to eq %w[unknown unknown]
    end

    it 'records :live as a signal without letting it override an otherwise stalled ladder' do
      # A live process with no output for an hour is exactly the case the board
      # exists to surface: the row must not read "live" just because ps says so.
      r = row('liveness' => :live, 'last_note_at' => iso(3600))

      expect(r['state']).to eq 'stalled'
      expect(r['signals']['process']).to eq 'live'
    end
  end

  describe 'the age ladder' do
    it 'yields live under 2 minutes, working under 15, quiet under 30 and stalled at 30 or more' do
      states = { 1 => 'live', 119 => 'live', 120 => 'working', 899 => 'working',
                 900 => 'quiet', 1799 => 'quiet', 1800 => 'stalled', 86_400 => 'stalled' }

      states.each do |secs, expected|
        expect(row('last_note_at' => iso(secs))['state']).to eq(expected), "#{secs}s should be #{expected}"
      end
    end

    it 'runs the ladder over the newest signal from ANY source, not just the ledger' do
      # No notes for an hour, but the worktree was edited 10 seconds ago.
      r = row('last_note_at' => iso(3600),
              'worktree' => { 'dirty_count' => 3, 'newest_dirty_mtime' => (LIVENESS_NOW - 10).to_i,
                              'commit_at' => (LIVENESS_NOW - 3600).to_i, 'commit_subject' => 's',
                              'commit_sha' => 'abc', 'partial' => false })

      expect(r['state']).to eq 'live'
      expect(r['newest_at']).to eq((LIVENESS_NOW - 10).to_i)
    end

    it 'applies every override before the ladder, even when the lane looks live' do
      fresh = { 'last_note_at' => iso(1) }

      expect(row(**fresh, 'liveness' => :dead)['state']).to eq 'dead'
      expect(row(**fresh, 'claimed_by' => nil)['state']).to eq 'unclaimed'
      expect(row(**fresh, 'status' => 'blocked', 'blocked_on' => 'waiting')['state']).to eq 'blocked'
      expect(row(**fresh, 'resolution' => { 'state' => 'missing', 'path' => nil, 'paths' => [] })['state'])
        .to eq 'worktree_missing'
      expect(row(**fresh, 'resolution' => { 'state' => 'ambiguous', 'path' => nil,
                                            'paths' => %w[/a /b] })['state']).to eq 'worktree_ambiguous'
    end

    it 'resolves two simultaneously-true overrides by the documented precedence' do
      # These pin the order of derive_state's returns, which nothing else would
      # catch if a future edit reordered them.
      blocked_and_dead = row('status' => 'blocked', 'blocked_on' => 'waiting', 'liveness' => :dead)
      expect(blocked_and_dead['state']).to eq 'blocked'

      dead_and_lost = row('liveness' => :dead,
                          'resolution' => { 'state' => 'missing', 'path' => nil, 'paths' => [] })
      expect(dead_and_lost['state']).to eq 'dead'

      unclaimed_and_dead = row('claimed_by' => nil, 'liveness' => :dead)
      expect(unclaimed_and_dead['state']).to eq 'dead'
    end

    it 'reports repo_missing and identity_missing as resolution state without calling the lane worktree-missing' do
      # We could not look. That is not the same finding as looking and not finding.
      %w[repo_missing identity_missing].each do |state|
        r = row('resolution' => { 'state' => state, 'path' => nil, 'paths' => [] },
                'worktree' => nil, 'last_note_at' => iso(1))
        expect(r['resolution_state']).to eq state
        expect(r['state']).to eq 'live'
      end
    end
  end

  describe 'newest signal per source' do
    it 'keeps every source separately so "editing but not noting" differs from "nothing at all"' do
      busy = row('last_note_at' => iso(1200), 'note' => { 'created_at' => iso(1200), 'kind' => 'progress' },
                 'criterion' => { 'newest_checked_at' => iso(2400), 'met' => 1, 'total' => 4 },
                 'gate' => { 'created_at' => iso(2280), 'body' => 'pre-push: PASS' },
                 'commit' => { 'created_at' => iso(360), 'body' => 'abc' },
                 'worktree' => { 'dirty_count' => 7, 'newest_dirty_mtime' => (LIVENESS_NOW - 40).to_i,
                                 'commit_at' => (LIVENESS_NOW - 360).to_i, 'commit_subject' => 'wip',
                                 'commit_sha' => 'abc', 'partial' => false })

      expect(busy['signals']).to include(
        'edit' => (LIVENESS_NOW - 40).to_i,
        'commit' => (LIVENESS_NOW - 360).to_i,
        'note' => (LIVENESS_NOW - 1200).to_i,
        'gate' => (LIVENESS_NOW - 2280).to_i,
        'criterion' => (LIVENESS_NOW - 2400).to_i,
        'process' => 'unknown'
      )
      expect(busy['state']).to eq 'live'

      silent = row('last_note_at' => iso(1200), 'note' => { 'created_at' => iso(1200), 'kind' => 'progress' },
                   'worktree' => nil, 'resolution' => { 'state' => 'missing', 'path' => nil, 'paths' => [] })
      expect(silent['signals']['edit']).to be_nil
      expect(silent['signals']['note']).to eq((LIVENESS_NOW - 1200).to_i)
    end

    it 'carries the dirty count and newest commit sha the fleet token fingerprints' do
      r = row('worktree' => { 'dirty_count' => 12, 'newest_dirty_mtime' => (LIVENESS_NOW - 5).to_i,
                              'commit_at' => (LIVENESS_NOW - 90).to_i, 'commit_subject' => 'feat: x',
                              'commit_sha' => 'deadbeef', 'partial' => false })

      expect(r).to include('dirty_count' => 12, 'commit_sha' => 'deadbeef', 'commit_subject' => 'feat: x')
    end

    it 'reports a nil newest_at and no state crash for a lane with no signal from any source' do
      r = row('started_at' => nil, 'updated_at' => nil, 'last_note_at' => nil,
              'worktree' => nil, 'resolution' => { 'state' => 'repo_missing', 'path' => nil, 'paths' => [] })

      expect(r['newest_at']).to be_nil
      expect(r['age_seconds']).to be_nil
      expect(r['state']).to eq 'stalled'
      expect(r['display_state']).to eq 'stalled?'
    end
  end

  describe 'the evidence marker' do
    it 'marks a row "ledger only" when the worktree hash is absent' do
      r = row('worktree' => nil, 'last_note_at' => iso(60))
      expect(r['evidence']).to eq 'ledger only'
    end

    it 'marks a row "ledger only" when the probe timed out, even though the hash exists' do
      r = row('worktree' => { 'dirty_count' => nil, 'newest_dirty_mtime' => nil, 'commit_at' => nil,
                              'commit_subject' => nil, 'commit_sha' => nil, 'partial' => true },
              'last_note_at' => iso(60))

      expect(r['evidence']).to eq 'ledger only'
      expect(r['partial']).to be true
    end

    it 'marks a row with real worktree signals as full evidence, including a clean worktree' do
      expect(row('last_note_at' => iso(60))['evidence']).to eq 'full'
    end

    it 'renders a ledger-only stalled row as "stalled?" and a fully-evidenced one as "stalled"' do
      thin = row('worktree' => nil, 'last_note_at' => iso(3600))
      full = row('last_note_at' => iso(3600),
                 'worktree' => { 'dirty_count' => 1, 'newest_dirty_mtime' => (LIVENESS_NOW - 3600).to_i,
                                 'commit_at' => (LIVENESS_NOW - 3600).to_i, 'commit_subject' => 's',
                                 'commit_sha' => 'abc', 'partial' => false })

      expect([thin['state'], thin['display_state']]).to eq %w[stalled stalled?]
      expect([full['state'], full['display_state']]).to eq %w[stalled stalled]
    end

    it 'only qualifies stalled — a ledger-only working row is not rendered as uncertain' do
      r = row('worktree' => nil, 'last_note_at' => iso(300))
      expect(r['display_state']).to eq 'working'
    end
  end

  describe 'unclaimed and dispatched lanes' do
    it 'yields unclaimed with an attention item for an in_progress story whose claimed_by is nil' do
      r = row('claimed_by' => nil, 'last_note_at' => iso(10))

      expect(r['state']).to eq 'unclaimed'
      items = described_class.attention_items([r])
      expect(items.length).to eq 1
      expect(items.first['kind']).to eq 'unclaimed'
    end

    it 'yields dispatched, with an attention item ONLY once older than the stalled threshold' do
      young = row('claimed_by' => 'dispatched:v0-B', 'last_note_at' => iso(1799))
      old   = row('claimed_by' => 'dispatched:v0-B', 'last_note_at' => iso(1800))

      expect([young['state'], old['state']]).to eq %w[dispatched dispatched]
      expect(described_class.attention_items([young])).to be_empty
      expect(described_class.attention_items([old]).first['kind']).to eq 'dispatched'
    end

    it 'never calls an unclaimed or dispatched lane worktree_missing, which it always would be' do
      # Neither token hashes to a lane directory, so the resolver reports missing
      # for both by construction; reading that as a broken worktree is noise.
      missing = { 'state' => 'missing', 'path' => nil, 'paths' => [] }

      expect(row('claimed_by' => nil, 'resolution' => missing)['state']).to eq 'unclaimed'
      expect(row('claimed_by' => 'dispatched:x', 'resolution' => missing)['state']).to eq 'dispatched'
    end
  end

  describe 'attention items' do
    def item_row(kind)
      case kind
      when 'dead'      then row('liveness' => :dead, 'last_note_at' => iso(100), 'slug' => 'dead-one')
      when 'worktree'  then row('resolution' => { 'state' => 'missing', 'path' => nil, 'paths' => [] },
                                'last_note_at' => iso(200), 'slug' => 'wt-one')
      when 'stalled'   then row('last_note_at' => iso(5000), 'slug' => 'stalled-one')
      when 'unclaimed' then row('claimed_by' => nil, 'last_note_at' => iso(300), 'slug' => 'unclaimed-one')
      when 'blocked'   then row('status' => 'blocked', 'blocked_on' => 'waiting on disc-1',
                                'updated_at' => iso(400), 'last_note_at' => iso(10),
                                'slug' => 'blocked-one')
      end
    end

    it 'orders by severity: dead, worktree, stalled, unclaimed, blocked' do
      rows = %w[blocked unclaimed stalled worktree dead].map { |k| item_row(k) }

      expect(described_class.attention_items(rows).map { |i| i['slug'] })
        .to eq %w[dead-one wt-one stalled-one unclaimed-one blocked-one]
    end

    it 'orders equal severities by age descending, oldest first' do
      rows = [row('last_note_at' => iso(2000), 'slug' => 'newer', 'story_id' => 's1'),
              row('last_note_at' => iso(9000), 'slug' => 'oldest', 'story_id' => 's2'),
              row('last_note_at' => iso(5000), 'slug' => 'middle', 'story_id' => 's3')]

      expect(described_class.attention_items(rows).map { |i| i['slug'] }).to eq %w[oldest middle newer]
    end

    it 'carries story slug, lane label, reason and the timestamp the reason is measured from' do
      item = described_class.attention_items([item_row('dead')]).first

      expect(item['slug']).to eq 'dead-one'
      expect(item['lane']).to eq 'v0-A'
      expect(item['reason']).to be_a(String)
      expect(item['reason'].strip).not_to be_empty
      expect(item['at']).to eq((LIVENESS_NOW - 100).to_i)
      expect(item['story_id']).to eq 'st-1'
    end

    it 'measures a blocked item from when the story was blocked, and names the block reason' do
      item = described_class.attention_items([item_row('blocked')]).first

      expect(item['at']).to eq((LIVENESS_NOW - 400).to_i)
      expect(item['reason']).to include 'waiting on disc-1'
    end

    it 'sorts a blocked item by the same timestamp it displays, not by the lane newest signal' do
      # The row's own newest signal is 10s old (a note landed on the blocked
      # story); the block itself is 400s old. Displaying one age and sorting by
      # the other would float a long-stuck block down the list.
      item = described_class.attention_items([item_row('blocked')]).first

      expect(item['age_seconds']).to eq 400
      expect(item['at']).to eq((LIVENESS_NOW - 400).to_i)
    end

    it 'lists every ambiguous path in the reason rather than picking one' do
      r = row('resolution' => { 'state' => 'ambiguous', 'path' => nil, 'paths' => %w[/a/wt /b/wt] })
      item = described_class.attention_items([r]).first

      expect(item['reason']).to include('/a/wt').and include('/b/wt')
    end

    it 'raises no attention item for live, working or quiet lanes' do
      rows = [row('last_note_at' => iso(1)), row('last_note_at' => iso(300)), row('last_note_at' => iso(1000))]
      expect(described_class.attention_items(rows)).to be_empty
    end
  end

  describe 'clock skew' do
    it 'clamps a future timestamp to age zero rather than producing a negative age' do
      r = row('last_note_at' => (LIVENESS_NOW + 600).utc.iso8601(6))

      expect(r['age_seconds']).to eq 0
      expect(r['state']).to eq 'live'
    end

    it 'clamps a future worktree mtime too, since file times come from a different clock' do
      r = row('worktree' => { 'dirty_count' => 1, 'newest_dirty_mtime' => (LIVENESS_NOW + 3600).to_i,
                              'commit_at' => (LIVENESS_NOW - 60).to_i, 'commit_subject' => 's',
                              'commit_sha' => 'abc', 'partial' => false })

      expect(r['age_seconds']).to eq 0
      expect(r['state']).to eq 'live'
    end

    it 'clamps a future attention-item age as well, keeping the sort total' do
      future = row('last_note_at' => (LIVENESS_NOW + 60).utc.iso8601(6), 'liveness' => :dead, 'slug' => 'future')
      past   = row('last_note_at' => iso(50), 'liveness' => :dead, 'slug' => 'past', 'story_id' => 's2')

      items = described_class.attention_items([future, past])
      expect(items.map { |i| i['age_seconds'] }).to eq [50, 0]
    end
  end

  describe '.lane_label' do
    it 'reads the label segment off every token form, and names the absence of one' do
      expect(described_class.lane_label('v0-A')).to eq 'v0-A'
      expect(described_class.lane_label('v0-A:0198abc')).to eq 'v0-A'
      expect(described_class.lane_label('claude:82344:62bddacf7211dd01')).to eq 'claude'
      expect(described_class.lane_label('dispatched:v0-B')).to eq 'v0-B'
      expect(described_class.lane_label(nil)).to eq 'unclaimed'
      expect(described_class.lane_label('')).to eq 'unclaimed'
    end
  end
end
