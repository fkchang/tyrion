# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

# Rails-style test DB safety net — prevent any spec from touching the real ledger.
ENV['TYRION_DB_PATH'] ||= File.join(Dir.tmpdir, 'tyrion-spec-fallback.db')
FileUtils.rm_f(ENV['TYRION_DB_PATH'])

require_relative '../lib/tyrion'

Dir[File.expand_path('support/**/*.rb', __dir__)].each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'spec/.rspec_status'
end
