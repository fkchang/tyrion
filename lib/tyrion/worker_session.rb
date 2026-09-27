# frozen_string_literal: true

require 'open3'
require 'pathname'

module Tyrion
  # The worker-session executable owns terminal creation and reconciliation.
  # Tyrion only supplies its verified story/worktree scope.
  module WorkerSession
    def self.run(*argv)
      binary = ENV['TYRION_WORKER_SESSION_BIN'] || 'worker-session'
      if ENV.key?('TYRION_WORKER_SESSION_BIN') && !Pathname.new(binary).absolute?
        raise ArgumentError, 'TYRION_WORKER_SESSION_BIN must be an absolute path'
      end

      invoke = -> { Open3.capture3(binary, *argv) }
      if defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env)
        Bundler.with_unbundled_env(&invoke)
      else
        invoke.call
      end
    end
  end
end
