# frozen_string_literal: true

require_relative '../repo'

module Tyrion
  module Liveness
    # Maps a lane to the git worktree it is editing, and probes that worktree
    # for edit and commit signals.
    #
    # Two properties are load-bearing and everything else here follows from them.
    #
    # First, an explicit root. `Repo.identity`, `Repo.lane_hashes` and
    # `Repo.worktrees` all default their path to `Dir.pwd`, which is right for a
    # CLI standing in the repo it asks about and wrong for the fleet, where one
    # process asks about many repos and the web server's cwd is `web/`. Every
    # root here comes from `projects.primary_repo_identity` and is passed
    # explicitly; the probe seams go through `Repo.git_capture`, which refuses a
    # nil root outright, and `Repo.worktrees` is bounded by the same timeout so
    # no call in this class can either default to cwd or run unbounded.
    #
    # Second, no silent picks. A lane that cannot be located is reported as
    # `missing`, `ambiguous`, `repo_missing` or `identity_missing` — never as a
    # lane with no activity. The whole board is worthless the first time it
    # presents absence of evidence as evidence of absence, so a wrong answer is
    # strictly worse here than a named unknown.
    class WorktreeResolver
      RESOLVED         = 'resolved'
      MISSING          = 'missing'
      AMBIGUOUS        = 'ambiguous'
      REPO_MISSING     = 'repo_missing'
      IDENTITY_MISSING = 'identity_missing'

      # Signals for a lane we could not probe at all. `partial` distinguishes
      # "the budget ran out" from "we looked and there was nothing".
      NO_SIGNALS = {
        'dirty_count' => nil, 'newest_dirty_mtime' => nil,
        'commit_at' => nil, 'commit_subject' => nil, 'commit_sha' => nil,
        'partial' => false
      }.freeze

      # Builds the whole lane_hash => [worktree paths] map ONCE, per project, at
      # construction: one `git worktree list` per canonical repo for the entire
      # snapshot rather than one per lane.
      def initialize(projects)
        @repos = {}
        Array(projects).each do |project|
          @repos[project['id']] = build_repo(project['primary_repo_identity'])
        end
      end

      # => {'state' =>, 'path' =>, 'paths' =>}. `path` is non-nil only for
      # RESOLVED; AMBIGUOUS carries every candidate in `paths` so the caller can
      # show them all rather than pick one.
      def resolve(project_id, claimed_by)
        repo = @repos[project_id]
        # A project we were never given is indistinguishable from one with no
        # identity: either way there is no root to ask about.
        return failure(IDENTITY_MISSING) if repo.nil?
        return failure(repo[:state]) unless repo[:state] == RESOLVED
        # An unclaimed lane has no token to hash, so it has no worktree — that is
        # `missing`, not a reason to guess at the repo's sole worktree.
        return failure(MISSING) if claimed_by.nil? || claimed_by.to_s.empty?

        paths = repo[:lanes][Repo.lane_hash(claimed_by)] || []
        case paths.length
        when 0 then failure(MISSING)
        when 1 then { 'state' => RESOLVED, 'path' => paths.first, 'paths' => paths }
        else        { 'state' => AMBIGUOUS, 'path' => nil, 'paths' => paths }
        end
      end

      # Edit and commit signals for one worktree path. Never raises: a path that
      # is gone, is not a repo, or times out comes back as nil signals, with
      # `partial` true only for the timeout — the one case where the absence is
      # ours rather than the worktree's.
      def probe(path)
        return NO_SIGNALS.dup if path.nil? || path.to_s.empty?

        dirty = dirty_signals(path)
        NO_SIGNALS.merge(dirty).merge(commit_signals(path))
      rescue Repo::GitTimeout
        NO_SIGNALS.merge('partial' => true)
      end

      private

      def failure(state) = { 'state' => state, 'path' => nil, 'paths' => [] }

      def build_repo(identity)
        return { state: IDENTITY_MISSING } if identity.nil? || identity.to_s.strip.empty?
        return { state: REPO_MISSING } unless Repo.git_repo?(identity)

        lanes = Hash.new { |h, k| h[k] = [] }
        Repo.worktrees(identity).each do |wt|
          Repo.lane_hashes(wt[:path]).each { |hash| lanes[hash] << wt[:path] }
        end
        { state: RESOLVED, lanes: lanes }
      rescue Repo::GitTimeout
        # A repo whose `git worktree list` blew the budget is one we cannot
        # locate lanes in. Reporting repo_missing is honest; reporting `missing`
        # per lane would imply we looked and found nothing.
        { state: REPO_MISSING }
      end

      def dirty_signals(path)
        raw = Repo.git_status_porcelain_z(path)
        return {} if raw.nil?

        paths = parse_porcelain_z(raw)
        { 'dirty_count' => paths.length, 'newest_dirty_mtime' => newest_mtime(path, paths) }
      end

      # `git status --porcelain -z --untracked-files=all` emits NUL-terminated
      # records of "XY <path>". A rename or copy (R or C in either status column)
      # emits its ORIGINAL path as an extra NUL-terminated field AFTER the
      # destination, so that field must be consumed or it would be counted as a
      # second dirty record. Returns [[status, path], ...] in emission order.
      def parse_porcelain_z(raw)
        fields = raw.split("\0")
        records = []
        until fields.empty?
          field = fields.shift
          next if field.empty?

          status = field[0, 2].to_s
          records << [status, field[3..].to_s]
          fields.shift if status.include?('R') || status.include?('C')
        end
        records
      end

      # Newest mtime among the dirty paths only — bounded by the dirty count, so
      # no recursive walk of the worktree. Deletions are skipped because the file
      # is gone by definition, and any other stat failure (a race with the agent
      # still editing, a permission problem) is skipped too: one unreadable path
      # must not cost the whole signal.
      def newest_mtime(root, records)
        mtimes = records.filter_map do |status, rel|
          next if status.include?('D')

          File.mtime(File.join(root, rel)).to_i
        rescue SystemCallError
          nil
        end
        mtimes.max
      end

      def commit_signals(path)
        raw = Repo.git_log_head(path)
        return {} if raw.nil?

        sha, at, subject = raw.split("\n", 3)
        return {} if sha.nil? || at.nil?

        { 'commit_sha' => sha.strip, 'commit_at' => at.strip.to_i, 'commit_subject' => subject.to_s.chomp }
      end
    end
  end
end
