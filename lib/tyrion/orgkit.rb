# frozen_string_literal: true

require 'open3'

module Tyrion
  # The ONE seam between Tyrion and the orgkit binary. Every epic-context
  # subcommand shells out through here and nowhere else, so specs stub exactly
  # one method and a future change of transport (a gem dependency, a different
  # binary name) touches exactly one file.
  #
  # `capture3` is always given an ARGUMENT ARRAY, never a shell string: a
  # heading, a file path or a learning's text is arbitrary user input, and a
  # shell string would let a quote or a `;` in any of them become syntax.
  module Orgkit
    BINARY = 'orgkit'

    # Runs `orgkit <argv...>` and returns [stdout, stderr, Process::Status].
    # Callers decide what a non-zero exit means; orgkit's own exit codes are
    # 0 ok, 1 error, 2 usage, 3 mutation refused (a refusal leaves every byte
    # of the file unchanged).
    def self.run(*argv)
      unbundled { Open3.capture3(BINARY, *argv.map(&:to_s)) }
    end

    # orgkit is a SEPARATE gem, deliberately not in Tyrion's Gemfile. Under
    # Bundler — which is how tyrion runs from a source checkout, and how the
    # web server runs — the inherited BUNDLE_*/RUBYOPT environment makes
    # rubygems refuse the binary outright:
    #
    #   can't find executable orgkit for gem orgkit. orgkit is not currently
    #   included in the bundle, perhaps you meant to add it to your Gemfile?
    #
    # so every shell-out has to leave the bundle behind first. Outside Bundler
    # (the installed-gem path) there is nothing to strip and this is a plain
    # yield.
    def self.unbundled(&block)
      return yield unless defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env)

      Bundler.with_unbundled_env(&block)
    end
    private_class_method :unbundled
  end
end
