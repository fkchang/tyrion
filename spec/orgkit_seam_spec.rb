# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Tyrion::Orgkit do
  describe '.run' do
    it 'passes an argument array to capture3, never a shell string' do
      status = instance_double(Process::Status, success?: true)
      expect(Open3).to receive(:capture3)
        .with('orgkit', 'sections', '/a b/c.org', '--tag', 's1_2')
        .and_return(['', '', status])

      described_class.run('sections', '/a b/c.org', '--tag', 's1_2')
    end

    it 'stringifies its arguments' do
      status = instance_double(Process::Status, success?: true)
      expect(Open3).to receive(:capture3).with('orgkit', 'sections', '3').and_return(['', '', status])

      described_class.run('sections', 3)
    end

    it 'returns capture3 stdout, stderr and status unchanged' do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(['out', 'err', status])

      expect(described_class.run('anything')).to eq ['out', 'err', status]
    end
  end

  # This spec runs under `bundle exec`, which is exactly the environment that
  # broke the seam: orgkit is a separate gem, deliberately not in Tyrion's
  # Gemfile, and rubygems refuses a binary that is not in the current bundle.
  # If `run` ever stops leaving the bundle behind, this goes red.
  describe 'against the real binary, under Bundler' do
    before { skip 'orgkit is not on PATH' unless orgkit_supports?('sections') }

    it 'runs the binary despite orgkit not being in this Gemfile' do
      out, err, status = described_class.run('--help')

      expect(status.success?).to be true
      expect(err).not_to match(/not currently included in the bundle/)
      expect(out).to include 'orgkit'
    end
  end
end
