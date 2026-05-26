# frozen_string_literal: true

require_relative 'lib/tyrion/version'

Gem::Specification.new do |s|
  s.name        = 'tyrion'
  s.version     = Tyrion::VERSION
  s.summary     = 'Resumability ledger for coding agents'
  s.description = 'Answers one question brutally well: what exact story was I implementing, ' \
                  'what is done, what did I learn, and what should the next agent do first?'
  s.authors     = ['Forrest Chang']
  s.email       = 'fchang@hedgeye.com'
  s.files       = Dir['lib/**/*.rb', 'bin/tyrion', 'skills/**/*.md']
  s.executables = ['tyrion']
  s.required_ruby_version = '>= 3.0'
  s.add_runtime_dependency 'sqlite3'
  s.add_runtime_dependency 'ostruct'
end
