# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe 'Tyrion::Repo.commits_since' do
  let(:tmpdir) { Dir.mktmpdir('tyrion-commits-since-') }
  after { FileUtils.rm_rf(tmpdir) }

  def git(*args)
    system('git', '-C', tmpdir, *args, out: File::NULL, err: File::NULL)
  end

  before do
    git('init', '-q')
    git('config', 'user.email', 'test@example.com')
    git('config', 'user.name', 'Test')
    git('config', 'commit.gpgsign', 'false')
  end

  it 'returns short-sha + subject lines for commits since the timestamp' do
    File.write(File.join(tmpdir, 'a.txt'), 'one')
    git('add', '-A'); git('commit', '-q', '-m', 'first commit')
    since = '1970-01-01T00:00:00Z'

    lines = Tyrion::Repo.commits_since(since, root: tmpdir)
    expect(lines.length).to eq(1)
    expect(lines.first).to match(/\A[0-9a-f]{7,} first commit\z/)
  end

  it 'returns an empty array when no commits match the window' do
    File.write(File.join(tmpdir, 'a.txt'), 'one')
    git('add', '-A'); git('commit', '-q', '-m', 'first commit')
    future = (Time.now.utc + 3600).strftime('%Y-%m-%dT%H:%M:%SZ')

    lines = Tyrion::Repo.commits_since(future, root: tmpdir)
    expect(lines).to eq([])
  end

  it 'returns nil when the path is not a git repo' do
    Dir.mktmpdir('not-a-repo-') do |non_repo|
      expect(Tyrion::Repo.commits_since('1970-01-01T00:00:00Z', root: non_repo)).to be_nil
    end
  end
end
