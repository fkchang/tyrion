# frozen_string_literal: true

require_relative 'liveness'

module Tyrion
  # SessionResolver — best-effort "what Claude Code session was this lane"
  # for a `tyrion attention` lane. Prototype (fleet-visibility follow-up,
  # 2026-09-26): Forrest wants to go from "this epic is stalled" straight to
  # `claude -r <session-id>` without hunting for it by hand.
  #
  # Deliberately separate from Tyrion::Attention, which stays a pure fold —
  # this module shells out (`lsof`) and reads files, so it is the impure
  # gatherer that runs AFTER `Attention.build`, the same relationship
  # Liveness::WorktreeResolver has to Liveness's pure fold. `enrich_lanes`
  # is the one call site the CLI and the web view both use.
  #
  # The governing rule, same as Liveness's own: an unconfirmed answer must
  # never be presented as a confident one. A live lane's pid can be checked
  # against its actually-open file handle -- exact, `confirmed`. A dead
  # lane has no process left to ask, so the best this can do is a `candidate`
  # guess, and only when two independent signals (recorded here as "the
  # session's own transcript was written to around when the lane went
  # quiet" AND "that same transcript mentions the story") agree on exactly
  # one file. Any ambiguity returns nil rather than a guess that might send
  # someone into the wrong session.
  module SessionResolver
    CLAUDE_PROJECTS_ROOT = File.expand_path('~/.claude/projects')

    CONFIRMED = 'confirmed' # live pid, an exact open-file-handle match
    CANDIDATE = 'candidate' # dead pid, an unconfirmed best-effort match

    # How close a transcript file's own last-write time must be to the
    # lane's last known activity to even be considered, for a dead lane.
    # Generous on purpose: a session's final write (the note that made the
    # lane look idle) and its jsonl's own mtime are rarely more than a
    # couple of minutes apart, but clock/flush skew is real and this is a
    # candidate, not a claim of precision.
    ACTIVITY_WINDOW_SECONDS = 3600

    module_function

    # `report` is Tyrion::Attention.build's own return shape. Returns a NEW
    # report (never mutates the argument) with every lane's hash gaining a
    # `resume_hint` key: nil, or {'session_id','confidence','command'}.
    # Never raises -- a lookup failure degrades to no hint, since a broken
    # resume-hint lookup must not take down `tyrion attention` itself.
    def enrich_lanes(report)
      epics = report['epics'].map do |epic|
        near_epoch = Liveness.epoch(epic['last_activity_at'])
        lanes = epic['lanes'].map { |lane| lane.merge('resume_hint' => safe_resume_hint(lane, near_epoch)) }
        epic.merge('lanes' => lanes)
      end
      report.merge('epics' => epics)
    end

    def safe_resume_hint(lane, near_epoch)
      resume_hint(pid: lane['pid'], live: lane['live'], worktree_path: lane['worktree_path'],
                   story_slug: lane['story_slug'], last_activity_epoch: near_epoch)
    rescue StandardError
      nil
    end

    # live lanes: an exact answer via `lsof -p <pid>` finding the actually-
    # open transcript file. Falls through to the dead-lane heuristic if that
    # somehow finds nothing (a live pid with no open jsonl handle is not
    # expected, but "unknown" beats "gave up"). Dead lanes (or a failed
    # live lookup): a `candidate`, only when the time-window and slug-match
    # signals agree on exactly one transcript file.
    def resume_hint(pid:, live:, worktree_path:, story_slug:, last_activity_epoch:)
      if live && pid
        session_id = session_id_from_pid(pid)
        return hint(session_id, CONFIRMED, worktree_path) if session_id
      end

      return nil if worktree_path.to_s.strip.empty?

      dir = project_dir_for(worktree_path)
      return nil unless Dir.exist?(dir)

      candidate = dead_lane_candidate(dir, story_slug, last_activity_epoch)
      candidate && hint(candidate, CANDIDATE, worktree_path)
    end

    # Claude Code's own project-directory naming: every `/` and `.` in the
    # absolute path becomes `-` (verified against real ~/.claude/projects/
    # entries, e.g. ".../cultiv-ai/.claude/worktrees/x" -> "...-cultiv-ai--
    # claude-worktrees-x" -- the doubled dash is the "/" then "." pair).
    def project_dir_for(path)
      File.join(CLAUDE_PROJECTS_ROOT, path.to_s.gsub(/[\/.]/, '-'))
    end

    def resume_command(session_id, worktree_path)
      return "claude -r #{session_id}" if worktree_path.to_s.strip.empty?

      "cd #{worktree_path} && claude -r #{session_id}"
    end

    # -- internals ------------------------------------------------------------

    def hint(session_id, confidence, worktree_path)
      { 'session_id' => session_id, 'confidence' => confidence, 'command' => resume_command(session_id, worktree_path) }
    end

    # Runs through Repo.capture_with_timeout -- the same bounded, non-git
    # argv seam Repo's own git shell-outs use, so a wedged `lsof` can never
    # hang `tyrion attention` (GitTimeout, despite the name, is a generic
    # "subprocess exceeded its budget", not a git-specific one).
    def session_id_from_pid(pid)
      out = Repo.capture_with_timeout(['lsof', '-p', Integer(pid).to_s])
      return nil unless out

      line = out.each_line.find { |l| l.strip.end_with?('.jsonl') && l.include?(CLAUDE_PROJECTS_ROOT) }
      line && File.basename(line.split(' ').last.to_s, '.jsonl')
    rescue Repo::GitTimeout, ArgumentError, TypeError
      nil
    end

    # Both signals must narrow to the SAME single file -- an epic's worktree
    # can hold many transcripts (every session ever run there), and either
    # signal alone can cross-match a different concurrent or later session
    # (verified live: grepping by slug alone matched a session from three
    # weeks later that simply typed the slug into an unrelated command).
    def dead_lane_candidate(dir, story_slug, near_epoch)
      return nil unless story_slug && near_epoch

      by_time = jsonl_files_near(dir, near_epoch)
      return nil if by_time.empty?

      by_slug = by_time.select { |f| file_mentions?(f, story_slug) }
      return nil unless by_slug.size == 1

      File.basename(by_slug.first, '.jsonl')
    end

    def jsonl_files_near(dir, near_epoch)
      Dir.glob(File.join(dir, '*.jsonl')).select do |f|
        (File.mtime(f).to_i - near_epoch).abs <= ACTIVITY_WINDOW_SECONDS
      end
    rescue Errno::ENOENT, Errno::EACCES
      []
    end

    # Streamed line-by-line (never a whole-file read) -- a real transcript
    # can run tens of MB, and this only needs to know whether the slug
    # appears anywhere, not where.
    def file_mentions?(path, slug)
      File.foreach(path).any? { |line| line.include?(slug) }
    rescue Errno::ENOENT, Errno::EACCES
      false
    end
  end
end
