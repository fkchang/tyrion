# frozen_string_literal: true

require 'fileutils'
require 'net/http'

module Tyrion
  # WebServer — process lifecycle for the Sinatra web UI (web/app.rb).
  # PID/log files live under ~/.tyrion/ (same home as the DB). A recorded PID
  # is cross-checked with a live port scan so a crashed process never wedges
  # the next start.
  module WebServer
    DEFAULT_PORT = 4579

    def self.state_dir
      dir = File.join(Dir.home, '.tyrion')
      FileUtils.mkdir_p(dir)
      dir
    end

    def self.pid_file(port) = File.join(state_dir, "web-#{port}.pid")
    def self.log_file(port) = File.join(state_dir, "web-#{port}.log")

    # web/ is a dev-only sibling of lib/ — not packaged into the gem
    # (see tyrion.gemspec). Returns nil when unavailable.
    def self.web_root
      root = File.expand_path('../../web', __dir__)
      File.exist?(File.join(root, 'app.rb')) ? root : nil
    end

    def self.running_pid(port)
      recorded = read_pid_file(port)
      return recorded if recorded && process_alive?(recorded)

      scanned = port_pid(port)
      scanned if scanned && our_process?(scanned)
    end

    # Guards the port-scan fallback: a PID recovered from `lsof` might belong
    # to some unrelated process squatting the port, and stop() kills whatever
    # running_pid returns — so only trust it if it looks like our own server.
    def self.our_process?(pid)
      cmd = `ps -p #{pid.to_i} -o command= 2>/dev/null`
      return false unless cmd.include?('app.rb')

      cwd = `lsof -a -d cwd -p #{pid.to_i} 2>/dev/null`.lines.last.to_s
      root = web_root
      root.nil? || cwd.include?(root)
    end

    def self.read_pid_file(port)
      pid = File.read(pid_file(port)).strip.to_i
      pid.positive? ? pid : nil
    rescue Errno::ENOENT
      nil
    end

    def self.process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def self.port_pid(port)
      out = `lsof -ti tcp:#{port.to_i} 2>/dev/null`.strip
      out.empty? ? nil : out.lines.first.strip.to_i
    end

    def self.healthy?(port)
      res = Net::HTTP.get_response(URI("http://localhost:#{port}/"))
      res.is_a?(Net::HTTPSuccess) || res.is_a?(Net::HTTPRedirection)
    rescue StandardError
      false
    end

    def self.start(port:, project:)
      root = web_root
      return false unless root

      # Pin BUNDLE_GEMFILE to web/'s own Gemfile — the parent process may have
      # one set (e.g. RubyGems' Gem.use_gemdeps auto-activating the repo-root
      # Gemfile), which would otherwise leak in and resolve the wrong bundle.
      env = { 'TYRION_PORT' => port.to_s, 'TYRION_PROJECT' => project.to_s,
              'BUNDLE_GEMFILE' => File.join(root, 'Gemfile') }
      pid = Process.spawn(env, 'bundle', 'exec', 'ruby', 'app.rb',
                           chdir: root, out: log_file(port), err: log_file(port))
      File.write(pid_file(port), pid.to_s)
      Process.detach(pid)
      wait_for_health(port)
    end

    def self.wait_for_health(port, timeout: 8)
      deadline = Time.now + timeout
      ok = healthy?(port)
      until ok || Time.now > deadline
        sleep 0.3
        ok = healthy?(port)
      end
      ok
    end

    def self.stop(port)
      pid = running_pid(port)
      return false unless pid

      Process.kill('TERM', pid)
      10.times do
        break unless process_alive?(pid)
        sleep 0.2
      end
      Process.kill('KILL', pid) if process_alive?(pid)
      true
    rescue Errno::ESRCH
      true
    ensure
      File.delete(pid_file(port)) if File.exist?(pid_file(port))
    end

    def self.url(port) = "http://localhost:#{port}"

    def self.open_browser(port)
      target = url(port)
      opener = case RbConfig::CONFIG['host_os']
               when /darwin/    then 'open'
               when /linux|bsd/ then 'xdg-open'
               end
      system(opener, target, out: File::NULL, err: File::NULL) if opener
      target
    end
  end
end
