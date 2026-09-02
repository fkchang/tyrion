# frozen_string_literal: true

require_relative 'worktree_resolver'

module Tyrion
  module Liveness
    # Snapshot — the single process-wide gathering of everything the fleet
    # renders, so that watching it from three views in two browsers costs the
    # same git work as watching it from one.
    #
    # `Snapshot.current(store)` is the only entry point any page render or poll
    # endpoint calls. Its bugs are silent by nature — the board keeps rendering,
    # just from work done twice or from state nobody notices is stale — which is
    # why the TTL, the single-flight mutex, the generation counter and the
    # budget are all separately observable in the returned hash rather than
    # being internal details.
    class Snapshot
      # Below POLL_INTERVAL_SECONDS on purpose: a poll arriving one interval
      # after the last one must never be answered from a snapshot older than
      # that interval, or the board would lag a full cycle behind the fleet.
      DEFAULT_TTL             = 10
      POLL_INTERVAL_SECONDS   = 15
      WORKTREE_BUDGET_SECONDS = 3

      EMPTY = {
        'generation' => 0, 'built_at' => nil, 'stale' => true, 'partial' => false, 'error' => nil,
        'rows' => [], 'attention' => [], 'lanes_by_story' => {}, 'worktree' => {},
        'resolution' => {}, 'project_activity' => {}, 'ledger' => {}
      }.freeze

      MUTEX = Mutex.new
      private_constant :MUTEX

      class << self
        # Returns the current snapshot, building one if the cached one has aged
        # out. Concurrent callers do NOT each start a build: the first through
        # the mutex builds, and everyone who waited re-checks freshness on
        # acquiring it and returns the build they waited for.
        def current(store, ttl: DEFAULT_TTL, budget: WORKTREE_BUDGET_SECONDS, now: Time.now)
          cached = @snapshot
          return cached if fresh?(cached, ttl, now)

          MUTEX.synchronize do
            return @snapshot if fresh?(@snapshot, ttl, now)

            @snapshot = build(store, budget: budget, now: now)
          end
        end

        # Drops the process-wide cache. Specs only — nothing in the running
        # system has a reason to discard a snapshot rather than let it age out.
        def reset!
          MUTEX.synchronize do
            @snapshot = nil
            @generation = 0
          end
        end

        private

        def fresh?(snapshot, ttl, now)
          return false if snapshot.nil? || snapshot['built_at'].nil?

          now.to_i - snapshot['built_at'] < ttl
        end

        # Any failure here degrades rather than propagates: a poll endpoint that
        # raises takes the whole board down, and a board that is a few seconds
        # behind is worth far more than one that is absent. The previous
        # snapshot is served with `stale` true; with no previous snapshot to
        # serve, a ledger-only build is attempted, and failing even that, the
        # empty shape — so every caller can render something true.
        def build(store, budget:, now:)
          assemble(store, budget: budget, now: now)
        rescue StandardError => e
          warn "[tyrion] liveness snapshot build failed: #{e.message}"
          degrade(store, e, now: now)
        end

        def degrade(store, error, now:)
          return @snapshot.merge('stale' => true, 'error' => error.message) if @snapshot

          begin
            assemble(store, budget: 0, now: now, worktree: false)
              .merge('stale' => true, 'error' => error.message)
          rescue StandardError => e
            warn "[tyrion] liveness ledger-only fallback failed: #{e.message}"
            EMPTY.merge('error' => e.message)
          end
        end

        # One pass over the ledger, one resolver for every project, one probe per
        # reachable lane. Nothing here is per-row: the five Store reads are bulk
        # by construction and the resolver builds its whole worktree map once.
        def assemble(store, budget:, now:, worktree: true)
          lanes    = store.in_progress_stories_across_projects
          ids      = lanes.map { |l| l['story_id'] }
          notes    = store.latest_note_per_story(ids)
          gates    = store.latest_gate_and_commit_per_story(ids)
          criteria = store.latest_criterion_check_per_story(ids)
          activity = store.project_activity

          probes = worktree ? probe_lanes(lanes, budget: budget) : ledger_only_probes(ids)
          rows   = Liveness.lane_rows(
            lanes.map { |lane| compose(lane, notes, gates, criteria, probes) }, now: now
          )

          finalize(rows, probes, activity,
                   ledger: { 'lanes' => lanes, 'notes' => notes, 'gates' => gates, 'criteria' => criteria },
                   now: now)
        end

        def compose(lane, notes, gates, criteria, probes)
          id = lane['story_id']
          lane.merge(
            'note' => notes[id],
            'gate' => gates.dig(id, 'gate'),
            'commit' => gates.dig(id, 'commit'),
            'criterion' => criteria[id],
            'liveness' => Repo.lane_liveness(lane['claimed_by']),
            'resolution' => probes.dig(id, 'resolution'),
            'worktree' => probes.dig(id, 'worktree')
          )
        end

        # Resolve every lane, then probe until the wall-clock budget is spent.
        #
        # The deadline starts BEFORE the resolver is constructed, because that
        # constructor runs one `git worktree list` per project and is part of
        # the same worktree pass. Starting the clock after it would let a fleet
        # with many repos blow the budget while every individual probe stayed
        # inside it — and the whole pass runs holding the process-wide mutex, so
        # the cost lands on every other request thread.
        #
        # Resolution itself is cheap (it reads the map the resolver already
        # built), so every lane always gets one. Probing shells out, so it is
        # what the deadline guards. A lane past it carries the PREVIOUS
        # snapshot's signals with `partial` true — safe for the ladder because
        # those signals are absolute timestamps, so a carried-forward lane can
        # only ever look older than it is, never falsely alive — and nil signals
        # when there is no previous snapshot to carry anything from.
        def probe_lanes(lanes, budget:)
          deadline = monotonic + budget
          resolver = WorktreeResolver.new(distinct_projects(lanes))

          lanes.to_h do |lane|
            id         = lane['story_id']
            resolution = resolver.resolve(lane['project_id'], lane['claimed_by'])
            signals    = if monotonic >= deadline
                           carried_forward(id, resolution['path'])
                         else
                           resolver.probe(resolution['path']).merge('path' => resolution['path'])
                         end
            [id, { 'resolution' => resolution, 'worktree' => signals }]
          end
        end

        # Only projects that actually have a lane need resolving; a project with
        # no in-progress work has nothing to locate.
        def distinct_projects(lanes)
          lanes.uniq { |l| l['project_id'] }
               .map { |l| { 'id' => l['project_id'], 'primary_repo_identity' => l['primary_repo_identity'] } }
        end

        # Carry a lane's last known signals forward ONLY when they came from the
        # same worktree it resolves to now. A story whose `claimed_by` changed
        # between builds resolves to a different path, and carrying the old
        # lane's dirty count and commit sha onto it would attribute one repo's
        # state to another — stale is tolerable here, wrong is not.
        def carried_forward(story_id, path)
          previous = @snapshot&.dig('worktree', story_id)
          previous = nil unless previous && previous['path'] == path

          (previous || WorktreeResolver::NO_SIGNALS).merge('partial' => true, 'path' => path)
        end

        def ledger_only_probes(ids)
          ids.to_h do |id|
            [id, { 'resolution' => nil, 'worktree' => nil }]
          end
        end

        # Named `finalize` rather than `snapshot` so a reader never has to work
        # out whether a bare `snapshot` means this method or the class.
        def finalize(rows, probes, activity, ledger:, now:)
          @generation = (@generation || 0) + 1
          {
            'generation' => @generation,
            'built_at' => now.to_i,
            'stale' => false,
            'partial' => rows.any? { |r| r['partial'] },
            'error' => nil,
            'rows' => rows,
            'attention' => Liveness.attention_items(rows),
            'lanes_by_story' => rows.to_h { |r| [r['story_id'], r] },
            'worktree' => probes.transform_values { |p| p['worktree'] },
            'resolution' => probes.transform_values { |p| p['resolution'] },
            'project_activity' => activity,
            'ledger' => ledger
          }
        end

        # Wall-clock budgets must not move when the system clock does.
        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
