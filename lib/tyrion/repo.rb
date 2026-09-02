# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
require 'timeout'

module Tyrion
  # Repo — git repo identity and worktree state helpers.
  # All paths use canonical realpath to handle symlinks and $ha env expansion.
  module Repo
    MARKER = '.tyrion/marker'

    # Canonical repo identity: the realpath of the shared .git directory.
    # Returns nil if not in a git repo.
    def self.identity(path = Dir.pwd)
      result = `git -C #{path.shellescape} rev-parse --git-common-dir 2>/dev/null`.strip
      return nil if result.empty? || !$?.success?

      git_dir = result.start_with?('/') ? result : File.join(path, result)
      File.realpath(git_dir).sub(/\/\.git$/, '')
    rescue Errno::ENOENT
      nil
    end

    # Walk up from cwd to find .tyrion/marker (handles subdir invocation).
    # Returns nil if path no longer exists (e.g. a project whose repo dir was deleted).
    def self.tyrion_root(path = Dir.pwd)
      cur = File.realpath(path)
      loop do
        return cur if File.exist?("#{cur}/#{MARKER}")
        parent = File.dirname(cur)
        return nil if parent == cur
        cur = parent
      end
    rescue Errno::ENOENT
      nil
    end

    # Current worktree root — falls back to cwd if marker not found.
    def self.worktree_root(path = Dir.pwd)
      tyrion_root(path) || path
    end

    def self.active_project(root = nil)
      root ||= worktree_root
      f = "#{root}/.tyrion/active-project"
      File.exist?(f) ? File.read(f).strip : nil
    end

    # The 16-hex lane-directory name for a token (SHA256 prefix). The same
    # function that maps a lane token to its on-disk state directory, exposed so
    # callers can match an in-flight lane token against a worktree's lane dirs.
    def self.lane_hash(token)
      Digest::SHA256.hexdigest(token.to_s)[0, 16]
    end

    # Returns the lane-specific subdirectory path for a given token.
    # Does not create the directory — callers must mkdir_p as needed.
    def self.lane_dir(token, root = nil)
      root ||= worktree_root
      "#{root}/.tyrion/lanes/#{lane_hash(token)}"
    end

    # The lane-hash directory names present under <root>/.tyrion/lanes — i.e.
    # which lanes have written state in that worktree. Empty when the worktree
    # has no lane state (or the path is unreadable).
    def self.lane_hashes(root = nil)
      root ||= worktree_root
      dir = "#{root}/.tyrion/lanes"
      return [] unless File.directory?(dir)
      Dir.children(dir).select { |c| File.directory?("#{dir}/#{c}") }
    rescue SystemCallError
      []
    end

    def self.active_epic(root = nil, token: nil)
      root ||= worktree_root
      read_state('active-epic', root, token)
    end

    def self.write_active_project(slug, root = nil)
      root ||= worktree_root
      FileUtils.mkdir_p("#{root}/.tyrion")
      File.write("#{root}/.tyrion/active-project", "#{slug}\n")
    end

    def self.write_active_epic(slug, root = nil, token: nil)
      write_state('active-epic', slug, root || worktree_root, token)
    end

    def self.active_story(root = nil, token: nil)
      root ||= worktree_root
      read_state('active-story', root, token)
    end

    def self.write_active_story(slug, root = nil, token: nil)
      write_state('active-story', slug, root || worktree_root, token)
    end

    def self.clear_active_story(root = nil, token: nil)
      root ||= worktree_root
      FileUtils.rm_f(state_path('active-story', root, token))
    end

    AGENT_BINARIES = %w[claude codex gemini].freeze
    AGENT_WALK_DEPTH = 16

    # Walk the process tree from +start_pid+ upward, returning the pid of the
    # nearest ancestor whose binary basename is in AGENT_BINARIES. Returns nil
    # if no such ancestor exists or if ps is unavailable/denied (e.g. sandboxed).
    def self.agent_pid(start_pid = Process.pid)
      pid = start_pid
      AGENT_WALK_DEPTH.times do
        row = ps_ppid_comm(pid)
        return nil if row.nil?
        ppid, comm = row
        base = File.basename(comm.sub(/\A-/, ''))
        return pid if AGENT_BINARIES.include?(base)
        return nil if ppid.to_i <= 1
        pid = ppid
      end
      nil
    rescue StandardError
      nil
    end

    # Return a locale/format-stable hash of the process start time for +pid+.
    # Uses ps -o lstart= which is available on macOS (no /proc). Returns nil
    # when ps is unavailable, denied, or the pid doesn't exist.
    def self.pid_start_stamp(pid)
      raw = ps_lstart(pid)
      return nil if raw.nil? || raw.strip.empty?
      Digest::SHA256.hexdigest(raw.strip.gsub(/\s+/, ' '))[0, 16]
    end

    # -- lane liveness (tri-state) --------------------------------------------
    # A pid-based lane token: "<label>:<pid>:<16-hex-start-stamp>". The stamp is
    # a 16-hex slice of SHA256(ps -o lstart=), so a hand-set TYRION_LANE like
    # "claude:99:abc" or an explicit label never parses as a pid token.
    LANE_PID_TOKEN = /\A.+:(\d+):([0-9a-f]{16})\z/

    # Parse a lane token into [pid, stamp], or nil when it is not a pid token
    # (explicit labels, codex thread tokens — nothing to probe for liveness).
    def self.parse_lane_pid_token(token)
      m = LANE_PID_TOKEN.match(token.to_s)
      m && [m[1].to_i, m[2]]
    end

    # Can we probe process liveness in this environment at all? Uses the current
    # process as a canary: if ps yields our own start-stamp, ps works; if it is
    # denied/sandboxed (as under the Codex sandbox), it does not.
    def self.ps_available?
      !pid_start_stamp(Process.pid).nil?
    end

    # Tri-state liveness of +pid+ whose expected start-stamp is +stamp+:
    #   :live    — the pid exists and its start-stamp matches (same process)
    #   :dead    — the pid is gone, or exists but with a different start-stamp
    #              (the OS recycled the pid onto an unrelated process)
    #   :unknown — ps is unavailable/denied, so liveness cannot be determined
    # Distinguishing :dead from :unknown is the safety property: we only treat a
    # lane as reclaimable when we can positively confirm its process is gone.
    def self.pid_alive?(pid, stamp)
      return :unknown unless ps_available?
      actual = pid_start_stamp(pid)
      return :dead if actual.nil?
      actual == stamp ? :live : :dead
    end

    # Tri-state liveness of a lane +token+. Non-pid tokens (explicit labels,
    # codex threads) are :unknown — there is no pid to probe.
    def self.lane_liveness(token)
      parsed = parse_lane_pid_token(token)
      return :unknown unless parsed
      pid_alive?(*parsed)
    end

    # -- lane state file helpers (private) ------------------------------------

    # Resolve the .tyrion state file path for +name+.
    # Per-lane dir when token is given, shared .tyrion/ otherwise.
    def self.state_path(name, root, token)
      dir = token ? lane_dir(token, root) : "#{root}/.tyrion"
      "#{dir}/#{name}"
    end
    private_class_method :state_path

    # Read +name+ state: checks per-lane file first, falls back to shared file.
    def self.read_state(name, root, token)
      if token
        lane = state_path(name, root, token)
        return File.read(lane).strip if File.exist?(lane)
      end
      shared = "#{root}/.tyrion/#{name}"
      File.exist?(shared) ? File.read(shared).strip : nil
    end
    private_class_method :read_state

    # Write +value+ to the appropriate state file (per-lane or shared).
    def self.write_state(name, value, root, token)
      path = state_path(name, root, token)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{value}\n")
    end
    private_class_method :write_state

    # -- ps seams (stubbed in specs so CI never needs a real ancestor) ----------

    def self.ps_ppid_comm(pid)
      out = `ps -o ppid=,comm= -p #{Integer(pid)} 2>/dev/null`.strip
      return nil if out.empty? || !$?.success?
      parts = out.split(' ', 2)
      return nil if parts.length < 2
      [Integer(parts[0]), parts[1]]
    rescue StandardError
      nil
    end

    def self.ps_lstart(pid)
      out = `ps -o lstart= -p #{Integer(pid)} 2>/dev/null`.strip
      return nil unless $?.success? && !out.empty?
      out
    rescue StandardError
      nil
    end

    def self.init_marker(root = Dir.pwd)
      FileUtils.mkdir_p("#{root}/.tyrion")
      File.write("#{root}/.tyrion/marker", "tyrion worktree\n")
    end

    def self.git_branch(path = nil)
      path ||= worktree_root
      `git -C #{path.shellescape} branch --show-current 2>/dev/null`.strip
    end

    # Raw `git worktree list --porcelain` output (seam — stubbed in specs).
    # Empty string when git is unavailable or this isn't a repo.
    #
    # Bounded by GIT_TIMEOUT_SECONDS like the fleet seams below, because the
    # resolver calls this once per project while building a snapshot: a repo
    # with a wedged index or a stale .git/worktrees entry would otherwise stall
    # a whole page render with no cap at all. A timeout raises GitTimeout so the
    # caller can report `partial` rather than an empty worktree list, which
    # would read as "this repo has no worktrees" — a confident wrong answer.
    def self.git_worktree_list(path = nil)
      path ||= worktree_root
      capture_with_timeout(['git', '-C', path.to_s, 'worktree', 'list', '--porcelain']).to_s
    end

    # Parse `git worktree list --porcelain` into [{path:, branch:, head:}].
    # A detached worktree reports branch "(detached)". Empty array off-repo.
    def self.worktrees(path = nil)
      result = []
      cur = nil
      git_worktree_list(path).each_line do |raw|
        line = raw.chomp
        if line.start_with?('worktree ')
          cur = { path: line.sub('worktree ', ''), branch: nil, head: nil }
          result << cur
        elsif cur.nil?
          next
        elsif line.start_with?('HEAD ')
          cur[:head] = line.sub('HEAD ', '')
        elsif line.start_with?('branch ')
          cur[:branch] = line.sub(%r{\Abranch refs/heads/}, '')
        elsif line == 'detached'
          cur[:branch] = '(detached)'
        end
      end
      result
    end

    def self.dirty_count(path = nil)
      path ||= worktree_root
      `git -C #{path.shellescape} status --porcelain 2>/dev/null`.lines.count
    end

    # -- bounded, explicit-root git seams (fleet liveness) --------------------
    #
    # Everything above this line defaults its path to the current worktree,
    # which is correct for a CLI standing in the repo it is asking about. The
    # fleet is the opposite case: one process asks about many repos it is not
    # standing in (the web server runs from web/), so these seams REFUSE a nil
    # root instead of defaulting, and cap every subprocess so one wedged git
    # cannot stall a page render.

    GIT_TIMEOUT_SECONDS = 2

    # Raised when a subprocess exceeded its budget. Distinct from a nil return
    # (which means "git ran and said no") because callers must be able to mark
    # the answer `partial` rather than reporting confident absence.
    class GitTimeout < StandardError; end

    # Run +argv+ and return its stdout, or nil when it exits non-zero or could
    # not be spawned. Raises GitTimeout after +timeout+ seconds, killing the
    # child first so a hung process cannot outlive the call.
    #
    # The child's stderr goes to /dev/null rather than a pipe we read. Reading
    # stdout to EOF and only then draining stderr deadlocks whenever the child
    # fills the stderr pipe buffer first (git advice, hook warnings), and that
    # deadlock would surface as a bogus GitTimeout on a perfectly healthy repo.
    # No caller wants git's stderr, so the pipe simply should not exist.
    #
    # Output is scrubbed to valid UTF-8: a commit subject or filename authored
    # under a non-UTF-8 locale would otherwise be tagged UTF-8 without being
    # valid, and blow up much later at JSON encoding time in a poll endpoint,
    # far from the repo that caused it.
    def self.capture_with_timeout(argv, timeout: GIT_TIMEOUT_SECONDS)
      io = IO.popen(argv, err: File::NULL)
      begin
        out = Timeout.timeout(timeout) { io.read }
      rescue Timeout::Error
        kill_process(io.pid)
        raise GitTimeout
      ensure
        io.close
      end
      $?&.success? ? out.dup.force_encoding(Encoding::UTF_8).scrub : nil
    rescue SystemCallError
      nil
    end

    def self.kill_process(pid)
      Process.kill('KILL', pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    private_class_method :kill_process

    # `git -C <root> <args...>` with an explicit root — the whole point of this
    # seam. A nil root here would silently mean "the web process's own cwd",
    # which is a different repo than the one being asked about, so it raises.
    def self.git_capture(root, *args, timeout: GIT_TIMEOUT_SECONDS)
      raise ArgumentError, 'git_capture requires an explicit repo root' if root.nil? || root.to_s.strip.empty?

      capture_with_timeout(['git', '-C', root.to_s, *args], timeout: timeout)
    end

    # True only when +root+ is a directory git will actually answer about.
    def self.git_repo?(root)
      return false unless root && File.directory?(root.to_s)

      !git_capture(root, 'rev-parse', '--git-dir').nil?
    end

    # Raw `git status --porcelain -z --untracked-files=all` for +root+.
    # NUL-delimited so paths containing spaces or newlines survive intact, and
    # -z is also what makes rename records carry their original path as an
    # extra field. nil when git could not answer.
    def self.git_status_porcelain_z(root)
      git_capture(root, 'status', '--porcelain', '-z', '--untracked-files=all')
    end

    # Raw `git log -1 --format=%H%n%ct%n%s` for +root+ — sha, commit epoch and
    # subject, one per line. nil when git could not answer (including a repo
    # with no commits yet).
    def self.git_log_head(root)
      git_capture(root, 'log', '-1', '--format=%H%n%ct%n%s')
    end

    def self.last_commit(path = nil)
      path ||= worktree_root
      `git -C #{path.shellescape} rev-parse --short HEAD 2>/dev/null`.strip
    end

    # "<short-sha> <subject>" lines for commits on the current branch since
    # `timestamp`. Returns [] when the window has no commits, nil when git is
    # unavailable / not a repo (callers decide whether that's fatal).
    def self.commits_since(timestamp, root: nil)
      root ||= worktree_root
      output = `git -C #{root.shellescape} log --oneline --since=#{timestamp.to_s.shellescape} 2>/dev/null`
      return nil unless $?.success?

      output.lines.map(&:strip).reject(&:empty?)
    end

    TOUCHED_FILES_LIMIT = 10

    def self.touched_files(path = nil)
      path ||= worktree_root
      output = `git -C #{path.shellescape} status --porcelain 2>/dev/null`
      return [] unless $?.success?

      output.lines.map { |l| l[3..].to_s.strip }.reject(&:empty?).uniq.first(TOUCHED_FILES_LIMIT)
    end

    def self.git_context(path = nil)
      path ||= worktree_root
      {
        branch:        git_branch(path),
        dirty_files:   dirty_count(path),
        last_commit:   last_commit(path),
        touched_files: touched_files(path)
      }
    end

    def self.git_context_json(path = nil) = git_context(path).to_json

    def self.gitignore_has_tyrion?(root = nil)
      root ||= worktree_root
      gi = "#{root}/.gitignore"
      return false unless File.exist?(gi)
      File.readlines(gi).any? { |l| l.strip == '.tyrion' || l.strip == '.tyrion/' }
    end

    def self.add_tyrion_to_gitignore(root = nil)
      root ||= worktree_root
      gi = "#{root}/.gitignore"
      File.open(gi, 'a') { |f| f.puts "\n# tyrion worktree state\n.tyrion/" }
    end

    # Mirror ABOUT.md to disk from DB content.
    def self.about_md_path(project_slug, root = nil)
      root ||= worktree_root
      "#{root}/.tyrion/projects/#{project_slug}/ABOUT.md"
    end

    def self.write_about_md(project_slug, content, root = nil)
      path = about_md_path(project_slug, root)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      path
    end
  end
end
