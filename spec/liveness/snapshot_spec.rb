# frozen_string_literal: true

require 'spec_helper'

# The snapshot is the reason watching the fleet from three views in two browsers
# costs the same git work as watching it from one. Its bugs are silent by
# nature: the board keeps rendering, just from work done twice or from state
# nobody notices is stale, so almost everything here counts builds rather than
# inspecting output.
RSpec.describe Tyrion::Liveness::Snapshot do
  let(:ctx)     { tyrion_worktree(project_slug: 'alpha', epic_slug: 'e1') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { ctx.epic }

  before { described_class.reset! }
  after  { described_class.reset! }

  def make_lane(slug, sequence, status: 'in_progress', **attrs)
    story = store.create_story(epic_id: epic['id'], slug: slug, title: slug, sequence: sequence)
    store.update_story(story['id'], { status: status, claimed_by: "lane-#{slug}" }.merge(attrs))
    store.find_story_by_id(story['id'])
  end

  # Count resolver constructions — one per build, so this is the build counter.
  def count_builds
    counter = { n: 0, lock: Mutex.new }
    allow(Tyrion::Liveness::WorktreeResolver).to receive(:new).and_wrap_original do |orig, *args|
      counter[:lock].synchronize { counter[:n] += 1 }
      orig.call(*args)
    end
    counter
  end

  describe 'TTL reuse' do
    it 'reuses the cached snapshot within the TTL and performs no further git work' do
      make_lane('a', 1)
      builds = count_builds

      first  = described_class.current(store, ttl: 60)
      second = described_class.current(store, ttl: 60)

      expect(builds[:n]).to eq 1
      expect(second['generation']).to eq first['generation']
      expect(second).to equal first
    end

    it 'rebuilds once the TTL has expired' do
      make_lane('a', 1)
      builds = count_builds

      first = described_class.current(store, ttl: 0)
      later = described_class.current(store, ttl: 0)

      expect(builds[:n]).to eq 2
      expect(later['generation']).to eq first['generation'] + 1
    end
  end

  describe 'single flight' do
    it 'produces exactly one build when two threads call it at once, the second waiting' do
      make_lane('a', 1)
      builds = count_builds
      # Make the build slow enough that the second thread is guaranteed to
      # arrive while the first is still inside it.
      allow_any_instance_of(Tyrion::Liveness::WorktreeResolver).to receive(:probe) do
        sleep 0.3
        Tyrion::Liveness::WorktreeResolver::NO_SIGNALS.dup
      end

      results = [nil, nil]
      threads = 2.times.map { |i| Thread.new { results[i] = described_class.current(store, ttl: 60) } }
      threads.each(&:join)

      expect(builds[:n]).to eq 1
      expect(results[0]).to equal results[1]
      expect(results.map { |r| r['generation'] }.uniq.length).to eq 1
    end
  end

  describe 'generation and TTL contract' do
    it 'increases the generation monotonically across rebuilds' do
      make_lane('a', 1)
      generations = 4.times.map { described_class.current(store, ttl: 0)['generation'] }

      expect(generations).to eq generations.sort
      expect(generations.uniq.length).to eq 4
    end

    it 'defaults the TTL below the poll interval so a poll never sees a snapshot older than one interval' do
      expect(described_class::DEFAULT_TTL).to eq 10
      expect(described_class::POLL_INTERVAL_SECONDS).to eq 15
      expect(described_class::DEFAULT_TTL).to be < described_class::POLL_INTERVAL_SECONDS
    end

    it 'does not advance the generation when a stale snapshot is re-served' do
      make_lane('a', 1)
      first = described_class.current(store, ttl: 60)

      allow(store).to receive(:in_progress_stories_across_projects).and_raise('ledger exploded')
      stale = nil
      expect { stale = described_class.current(store, ttl: 0) }.to output(/ledger exploded/).to_stderr

      expect(stale['generation']).to eq first['generation']
      expect(stale['stale']).to be true
    end
  end

  describe 'the worktree budget' do
    it 'caps the whole worktree pass at 3 seconds' do
      expect(described_class::WORKTREE_BUDGET_SECONDS).to eq 3
    end

    it 'marks lanes not reached in time as partial, with nil signals on a first build' do
      3.times { |i| make_lane("s#{i}", i + 1) }
      allow_any_instance_of(Tyrion::Liveness::WorktreeResolver).to receive(:probe).and_return(
        { 'dirty_count' => 1, 'newest_dirty_mtime' => Time.now.to_i, 'commit_at' => Time.now.to_i,
          'commit_subject' => 's', 'commit_sha' => 'abc', 'partial' => false }
      )

      # A negative budget is already spent on arrival, so no probe is reached.
      # Deliberately not a tight sleep-versus-budget race, which would flake on
      # a loaded machine and prove nothing extra.
      spent = described_class.current(store, ttl: 60, budget: -1)

      expect(spent['rows'].length).to eq 3
      expect(spent['rows'].map { |r| r['partial'] }).to all(be true)
      expect(spent['partial']).to be true
      expect(spent['rows'].map { |r| r['dirty_count'] }).to all(be_nil)
      expect(spent['rows'].map { |r| r['evidence'] }).to all(eq 'ledger only')

      described_class.reset!
      ample = described_class.current(store, ttl: 60, budget: 30)
      expect(ample['rows'].map { |r| r['partial'] }).to all(be false)
      expect(ample['partial']).to be false
    end

    it 'starts the budget clock before the resolver is built, since that shells out too' do
      make_lane('a', 1)
      # Constructing the resolver is one `git worktree list` per project; if the
      # deadline started after it, a fleet with many repos could blow the budget
      # while every individual probe stayed inside it.
      allow(Tyrion::Liveness::WorktreeResolver).to receive(:new).and_wrap_original do |orig, *args|
        sleep 0.2
        orig.call(*args)
      end

      snapshot = described_class.current(store, ttl: 60, budget: 0.05)

      expect(snapshot['rows'].map { |r| r['partial'] }).to all(be true)
    end

    it 'carries the last known signals forward for a lane it could not reach this time' do
      lane = make_lane('a', 1)
      probes = 0
      allow_any_instance_of(Tyrion::Liveness::WorktreeResolver).to receive(:probe) do
        probes += 1
        { 'dirty_count' => 7, 'newest_dirty_mtime' => 1_700_000_000, 'commit_at' => 1_700_000_000,
          'commit_subject' => 'wip', 'commit_sha' => 'cafe', 'partial' => false }
      end
      allow_any_instance_of(Tyrion::Liveness::WorktreeResolver).to receive(:resolve)
        .and_return('state' => 'resolved', 'path' => '/repo/wt-a', 'paths' => ['/repo/wt-a'])

      described_class.current(store, ttl: 60, budget: 30)           # first build: real probe
      second = described_class.current(store, ttl: 0, budget: -1)   # second: budget already spent

      row = second['rows'].find { |r| r['story_id'] == lane['id'] }
      expect(row['dirty_count']).to eq 7
      expect(row['commit_sha']).to eq 'cafe'
      expect(row['partial']).to be true
      expect(row['evidence']).to eq 'ledger only'
      expect(probes).to eq 1
    end

    it 'refuses to carry signals forward onto a lane that now resolves to a different worktree' do
      # A story whose claimed_by changed between builds resolves elsewhere.
      # Carrying the old lane's dirty count and sha onto it would attribute one
      # repo's state to another: stale is tolerable, wrong is not.
      lane = make_lane('a', 1)
      allow_any_instance_of(Tyrion::Liveness::WorktreeResolver).to receive(:probe).and_return(
        { 'dirty_count' => 7, 'newest_dirty_mtime' => 1_700_000_000, 'commit_at' => 1_700_000_000,
          'commit_subject' => 'wip', 'commit_sha' => 'cafe', 'partial' => false }
      )
      allow_any_instance_of(Tyrion::Liveness::WorktreeResolver).to receive(:resolve)
        .and_return('state' => 'resolved', 'path' => '/repo/wt-a', 'paths' => ['/repo/wt-a'])
      described_class.current(store, ttl: 60, budget: 30)

      allow_any_instance_of(Tyrion::Liveness::WorktreeResolver).to receive(:resolve)
        .and_return('state' => 'resolved', 'path' => '/repo/wt-b', 'paths' => ['/repo/wt-b'])
      second = described_class.current(store, ttl: 0, budget: -1)

      row = second['rows'].find { |r| r['story_id'] == lane['id'] }
      expect(row['dirty_count']).to be_nil
      expect(row['commit_sha']).to be_nil
      expect(row['partial']).to be true
    end
  end

  describe 'failure handling' do
    it 'serves the previous snapshot marked stale and logs the error when a build raises' do
      make_lane('a', 1)
      first = described_class.current(store, ttl: 60)
      expect(first['stale']).to be false

      allow(store).to receive(:project_activity).and_raise('boom in the build')
      stale = nil
      expect { stale = described_class.current(store, ttl: 0) }.to output(/boom in the build/).to_stderr

      expect(stale['stale']).to be true
      expect(stale['rows'].map { |r| r['slug'] }).to eq first['rows'].map { |r| r['slug'] }
      expect(stale['error']).to include 'boom in the build'
    end

    it 'yields a ledger-only snapshot on a first-build failure rather than propagating' do
      make_lane('a', 1)
      allow(Tyrion::Liveness::WorktreeResolver).to receive(:new).and_raise('resolver exploded')

      snapshot = nil
      expect { snapshot = described_class.current(store, ttl: 60) }.to output(/resolver exploded/).to_stderr

      expect(snapshot['rows'].length).to eq 1
      expect(snapshot['rows'].first['evidence']).to eq 'ledger only'
      expect(snapshot['rows'].first['slug']).to eq 'a'
      expect(snapshot['stale']).to be true
    end

    it 'yields an empty snapshot, still not an exception, when even the ledger read fails' do
      allow(store).to receive(:in_progress_stories_across_projects).and_raise('db gone')

      snapshot = nil
      expect { snapshot = described_class.current(store, ttl: 60) }.to output(/db gone/).to_stderr

      expect(snapshot['rows']).to eq []
      expect(snapshot['attention']).to eq []
      expect(snapshot['stale']).to be true
    end
  end

  describe 'one snapshot for every view' do
    it 'holds the resolver result, every lane signal set and the bulk ledger rows in one build' do
      a = make_lane('a', 1)
      b = make_lane('b', 2, status: 'blocked', blocked_on: 'waiting')
      store.add_note(a['id'], 'progress', 'did a thing')
      store.add_note(a['id'], 'gate', 'pre-push: PASS',
                     metadata: JSON.dump('gate' => 'pre-push', 'result' => 'pass'))
      store.add_criteria(a['id'], [{ keyword: 'Then', semantic_kind: 'then', text: 'one' }])
      store.check_criterion(a['id'], 1, 'evidence')

      snapshot = described_class.current(store, ttl: 60)

      expect(snapshot['rows'].map { |r| r['slug'] }).to contain_exactly('a', 'b')
      expect(snapshot['resolution'].keys).to contain_exactly(a['id'], b['id'])
      expect(snapshot['worktree'].keys).to contain_exactly(a['id'], b['id'])
      expect(snapshot['project_activity'][project['id']]['total']).to eq 2

      row_a = snapshot['lanes_by_story'][a['id']]
      expect(row_a['signals']['note']).not_to be_nil
      expect(row_a['signals']['gate']).not_to be_nil
      expect(row_a['signals']['criterion']).not_to be_nil
      expect(row_a).to include('met' => 1, 'total' => 1)
      expect(snapshot['attention'].map { |i| i['kind'] }).to include 'blocked'
      expect(snapshot['built_at']).to be_a(Integer)
    end

    it 'builds one resolver for the whole snapshot, not one per lane' do
      3.times { |i| make_lane("s#{i}", i + 1) }
      builds = count_builds

      described_class.current(store, ttl: 60)

      expect(builds[:n]).to eq 1
    end

    it 'returns an empty but well-shaped snapshot when the ledger holds no lanes at all' do
      snapshot = described_class.current(store, ttl: 60)

      expect(snapshot['rows']).to eq []
      expect(snapshot['attention']).to eq []
      expect(snapshot['stale']).to be false
      expect(snapshot['generation']).to be_a(Integer)
    end
  end
end
