# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'shellwords'

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
    def self.tyrion_root(path = Dir.pwd)
      cur = File.realpath(path)
      loop do
        return cur if File.exist?("#{cur}/#{MARKER}")
        parent = File.dirname(cur)
        return nil if parent == cur
        cur = parent
      end
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

    def self.active_epic(root = nil)
      root ||= worktree_root
      f = "#{root}/.tyrion/active-epic"
      File.exist?(f) ? File.read(f).strip : nil
    end

    def self.write_active_project(slug, root = nil)
      root ||= worktree_root
      FileUtils.mkdir_p("#{root}/.tyrion")
      File.write("#{root}/.tyrion/active-project", "#{slug}\n")
    end

    def self.write_active_epic(slug, root = nil)
      root ||= worktree_root
      FileUtils.mkdir_p("#{root}/.tyrion")
      File.write("#{root}/.tyrion/active-epic", "#{slug}\n")
    end

    def self.init_marker(root = Dir.pwd)
      FileUtils.mkdir_p("#{root}/.tyrion")
      File.write("#{root}/.tyrion/marker", "tyrion worktree\n")
    end

    def self.git_branch(path = nil)
      path ||= worktree_root
      `git -C #{path.shellescape} branch --show-current 2>/dev/null`.strip
    end

    def self.dirty_count(path = nil)
      path ||= worktree_root
      `git -C #{path.shellescape} status --porcelain 2>/dev/null`.lines.count
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
