# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

# Repo.main_root is the seam that makes every epic-context read and write land
# in the ONE true checkout: an agent worktree branches from origin/main and
# usually does not contain features/<epic>.context.org at all, so resolving the
# file relative to the worktree would silently fork the wiki.
RSpec.describe 'Tyrion::Repo.main_root' do
  let(:tmpdir)    { Dir.mktmpdir('tyrion-main-root-') }
  let(:main_root) { File.realpath(File.join(tmpdir, 'main')) }

  after { FileUtils.rm_rf(tmpdir) }

  def git(dir, *args)
    system('git', '-C', dir, *args, out: File::NULL, err: File::NULL)
  end

  before do
    FileUtils.mkdir_p(File.join(tmpdir, 'main'))
    git(main_root, 'init', '-q')
    git(main_root, 'config', 'user.email', 'test@example.com')
    git(main_root, 'config', 'user.name', 'Test')
    git(main_root, 'config', 'commit.gpgsign', 'false')
    File.write(File.join(main_root, 'a.txt'), 'one')
    git(main_root, 'add', '-A')
    git(main_root, 'commit', '-q', '-m', 'first commit')
  end

  it 'returns the main checkout when called from inside a linked worktree' do
    wt = File.join(tmpdir, 'wt')
    git(main_root, 'worktree', 'add', '-q', wt, '-b', 'lane-1')

    expect(Tyrion::Repo.main_root(File.realpath(wt))).to eq main_root
  end

  it 'returns the same path when called from the main checkout itself' do
    expect(Tyrion::Repo.main_root(main_root)).to eq main_root
  end

  it 'returns the main checkout from a subdirectory of a linked worktree' do
    wt = File.join(tmpdir, 'wt2')
    git(main_root, 'worktree', 'add', '-q', wt, '-b', 'lane-2')
    sub = File.join(wt, 'features')
    FileUtils.mkdir_p(sub)

    expect(Tyrion::Repo.main_root(sub)).to eq main_root
  end

  it 'returns nil for a non-git directory rather than raising' do
    Dir.mktmpdir('not-a-repo-') do |non_repo|
      expect(Tyrion::Repo.main_root(non_repo)).to be_nil
    end
  end

  it 'returns nil when the bounded git seam times out rather than raising' do
    allow(Tyrion::Repo).to receive(:git_capture).and_raise(Tyrion::Repo::GitTimeout)

    expect(Tyrion::Repo.main_root(main_root)).to be_nil
  end

  it 'returns nil when the root is empty rather than propagating ArgumentError' do
    expect(Tyrion::Repo.main_root('')).to be_nil
  end

  it 'defaults its path to the current worktree root' do
    allow(Tyrion::Repo).to receive(:worktree_root).and_return(main_root)

    expect(Tyrion::Repo.main_root).to eq main_root
  end
end
