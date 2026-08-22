# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion discovery headline' do
  let(:ctx)   { tyrion_worktree }
  let(:store) { ctx.store }
  let(:disc)  { store.create_discovery(project_id: ctx.project['id'], status: 'mark', question: 'q') }

  describe 'happy path' do
    it 'sets the headline and prints confirmation' do
      expect {
        Tyrion::Commands.cmd_discovery_headline([disc['id'], 'a', 'sharp', 'headline'], store)
      }.to output(/Headline set: #{disc['id']}\s+a sharp headline/).to_stdout

      expect(store.find_discovery(disc['id'])['headline']).to eq 'a sharp headline'
    end
  end

  describe '--help' do
    it 'prints usage instead of storing "--help" as the headline (disc-092 class)' do
      out, = capture_io { Tyrion::Commands.cmd_discovery_headline([disc['id'], '--help'], store) }

      expect(out).to eq("#{Tyrion::Commands::DISCOVERY_HEADLINE_USAGE}\n")
      expect(store.find_discovery(disc['id'])['headline']).to be_nil
    end
  end
end
