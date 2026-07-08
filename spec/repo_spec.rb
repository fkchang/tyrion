# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Tyrion::Repo do
  let(:tmpdir) { Dir.mktmpdir('tyrion-repo-spec-') }

  after { FileUtils.rm_rf(tmpdir) }

  describe '.active_story / .write_active_story' do
    it 'returns nil when .tyrion/active-story does not exist' do
      expect(described_class.active_story(tmpdir)).to be_nil
    end

    it 'round-trips a slug through write then read' do
      described_class.write_active_story('my-story', tmpdir)
      expect(described_class.active_story(tmpdir)).to eq('my-story')
    end

    it 'creates .tyrion/ dir if absent' do
      described_class.write_active_story('slug', tmpdir)
      expect(File.exist?("#{tmpdir}/.tyrion/active-story")).to be true
    end

    it 'strips trailing whitespace/newlines on read' do
      FileUtils.mkdir_p("#{tmpdir}/.tyrion")
      File.write("#{tmpdir}/.tyrion/active-story", "my-story\n  ")
      expect(described_class.active_story(tmpdir)).to eq('my-story')
    end
  end

  describe '.lane_dir' do
    it 'returns a path under .tyrion/lanes/ keyed by the first 16 hex chars of sha256(token)' do
      token = 'claude:12345:abcdef'
      expected_hash = Digest::SHA256.hexdigest(token)[0, 16]
      expect(described_class.lane_dir(token, tmpdir)).to eq("#{tmpdir}/.tyrion/lanes/#{expected_hash}")
    end

    it 'produces different dirs for different tokens' do
      dir_a = described_class.lane_dir('claude:111:aaa', tmpdir)
      dir_b = described_class.lane_dir('claude:222:bbb', tmpdir)
      expect(dir_a).not_to eq(dir_b)
    end

    it 'produces the same dir for the same token' do
      token = 'codex:thread-abc'
      expect(described_class.lane_dir(token, tmpdir)).to eq(described_class.lane_dir(token, tmpdir))
    end
  end

  describe '.active_epic / .write_active_epic with token:' do
    let(:token_a) { 'claude:100:stampA' }
    let(:token_b) { 'claude:200:stampB' }

    it 'returns nil when no per-lane file exists' do
      expect(described_class.active_epic(tmpdir, token: token_a)).to be_nil
    end

    it 'write then read round-trips for a given token' do
      described_class.write_active_epic('epic-a', tmpdir, token: token_a)
      expect(described_class.active_epic(tmpdir, token: token_a)).to eq('epic-a')
    end

    it 'isolates lane A from lane B' do
      described_class.write_active_epic('epic-a', tmpdir, token: token_a)
      described_class.write_active_epic('epic-b', tmpdir, token: token_b)

      expect(described_class.active_epic(tmpdir, token: token_a)).to eq('epic-a')
      expect(described_class.active_epic(tmpdir, token: token_b)).to eq('epic-b')
    end

    it 'writes the per-lane file under .tyrion/lanes/<hash>/active-epic' do
      described_class.write_active_epic('epic-x', tmpdir, token: token_a)
      hash = Digest::SHA256.hexdigest(token_a)[0, 16]
      expect(File.exist?("#{tmpdir}/.tyrion/lanes/#{hash}/active-epic")).to be true
    end

    it 'shared fallback (no token) returns the shared .tyrion/active-epic' do
      FileUtils.mkdir_p("#{tmpdir}/.tyrion")
      File.write("#{tmpdir}/.tyrion/active-epic", "shared-epic\n")

      described_class.write_active_epic('epic-a', tmpdir, token: token_a)

      expect(described_class.active_epic(tmpdir)).to eq('shared-epic')
    end

    it 'falls back to shared file when per-lane file is absent' do
      FileUtils.mkdir_p("#{tmpdir}/.tyrion")
      File.write("#{tmpdir}/.tyrion/active-epic", "shared-epic\n")

      expect(described_class.active_epic(tmpdir, token: token_a)).to eq('shared-epic')
    end

    it 'nil token uses shared file (legacy behavior)' do
      FileUtils.mkdir_p("#{tmpdir}/.tyrion")
      File.write("#{tmpdir}/.tyrion/active-epic", "legacy-epic\n")

      expect(described_class.active_epic(tmpdir, token: nil)).to eq('legacy-epic')
    end
  end

  describe '.active_story / .write_active_story / .clear_active_story with token:' do
    let(:token) { 'claude:42:stamp42' }

    it 'write then read round-trips per-lane story' do
      described_class.write_active_story('my-story', tmpdir, token: token)
      expect(described_class.active_story(tmpdir, token: token)).to eq('my-story')
    end

    it 'clear_active_story removes the per-lane pin' do
      described_class.write_active_story('my-story', tmpdir, token: token)
      described_class.clear_active_story(tmpdir, token: token)
      expect(described_class.active_story(tmpdir, token: token)).to be_nil
    end

    it 'clear_active_story is idempotent when file absent' do
      expect { described_class.clear_active_story(tmpdir, token: token) }.not_to raise_error
    end

    it 'legacy no-token still round-trips through shared file' do
      described_class.write_active_story('old-story', tmpdir)
      expect(described_class.active_story(tmpdir)).to eq('old-story')
    end
  end
end
