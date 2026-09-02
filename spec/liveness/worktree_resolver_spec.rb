# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

# The resolver answers "which worktree is this lane editing?" for lanes in repos
# the current process is not standing in. Every failure mode here is a mode where
# a wrong answer would attribute another repo's edits to this lane, so the states
# are named rather than collapsed into "no signal".
RSpec.describe Tyrion::Liveness::WorktreeResolver do
  let(:tmp) { @tmp ||= Dir.mktmpdir('resolver-spec-') }

  after { FileUtils.rm_rf(@tmp) if @tmp }

  def git(dir, *args)
    out = IO.popen(['git', '-C', dir.to_s, '-c', 'user.email=t@t', '-c', 'user.name=T', *args],
                   err: %i[child out], &:read)
    raise "git #{args.join(' ')} failed in #{dir}: #{out}" unless $?.success?

    out
  end

  # A real git repo with one commit — the resolver shells out for real, so the
  # fixtures have to be real too.
  def make_repo(name)
    root = File.join(tmp, name)
    FileUtils.mkdir_p(root)
    git(root, 'init', '-q', '.')
    File.write(File.join(root, 'seed.txt'), "seed\n")
    git(root, 'add', '-A')
    git(root, 'commit', '-qm', 'init')
    root
  end

  def add_worktree(root, name, branch)
    path = File.join(tmp, name)
    git(root, 'worktree', 'add', '-q', '-b', branch, path)
    path
  end

  def write_lane_dir(worktree_path, token)
    dir = File.join(worktree_path, '.tyrion', 'lanes', Tyrion::Repo.lane_hash(token))
    FileUtils.mkdir_p(dir)
    dir
  end

  def project(id, identity)
    { 'id' => id, 'slug' => id, 'primary_repo_identity' => identity }
  end

  describe 'explicit repo root' do
    it 'never consults the process cwd — Repo.worktrees is only ever called with a real root' do
      root = make_repo('r1')
      allow(Tyrion::Repo).to receive(:worktrees) do |path|
        raise 'worktrees called with no explicit root' if path.nil?

        [{ path: root, branch: 'main', head: 'abc' }]
      end

      described_class.new([project('p1', root)])

      expect(Tyrion::Repo).to have_received(:worktrees).with(root)
    end

    it 'refuses a nil or empty root at the subprocess seam rather than defaulting to cwd' do
      expect { Tyrion::Repo.git_capture(nil, 'status') }.to raise_error(ArgumentError, /explicit repo root/)
      expect { Tyrion::Repo.git_capture('', 'status') }.to raise_error(ArgumentError, /explicit repo root/)
    end
  end

  describe 'repo-level resolution states' do
    it 'reports identity_missing for every lane in a project whose primary_repo_identity is nil' do
      resolver = described_class.new([project('p1', nil)])

      expect(resolver.resolve('p1', 'claude:1:aa')['state']).to eq 'identity_missing'
      expect(resolver.resolve('p1', 'v0-A')['state']).to eq 'identity_missing'
    end

    it 'reports repo_missing when the path is not a directory' do
      resolver = described_class.new([project('p1', File.join(tmp, 'gone'))])
      expect(resolver.resolve('p1', 'claude:1:aa')['state']).to eq 'repo_missing'
    end

    it 'reports repo_missing when the path is a directory but not a git repo' do
      plain = File.join(tmp, 'plain')
      FileUtils.mkdir_p(plain)
      resolver = described_class.new([project('p1', plain)])
      expect(resolver.resolve('p1', 'claude:1:aa')['state']).to eq 'repo_missing'
    end

    it 'reports identity_missing for a project it was never given' do
      resolver = described_class.new([])
      expect(resolver.resolve('nope', 'claude:1:aa')['state']).to eq 'identity_missing'
    end
  end

  describe 'lane-to-worktree resolution' do
    let(:root) { make_repo('r1') }
    let(:token) { 'claude:4242:deadbeefdeadbeef' }

    it 'resolves to the one worktree whose lane hashes contain the token hash' do
      wt = add_worktree(root, 'lane-a', 'feature/a')
      add_worktree(root, 'lane-b', 'feature/b')
      write_lane_dir(wt, token)

      result = described_class.new([project('p1', root)]).resolve('p1', token)

      expect(result['state']).to eq 'resolved'
      expect(File.realpath(result['path'])).to eq File.realpath(wt)
      expect(result['paths'].size).to eq 1
    end

    it 'reports missing when no worktree carries that lane hash' do
      add_worktree(root, 'lane-a', 'feature/a')
      result = described_class.new([project('p1', root)]).resolve('p1', token)

      expect(result['state']).to eq 'missing'
      expect(result['path']).to be_nil
      expect(result['paths']).to eq []
    end

    it 'reports ambiguous listing every matching path, with no silent pick' do
      a = add_worktree(root, 'lane-a', 'feature/a')
      b = add_worktree(root, 'lane-b', 'feature/b')
      write_lane_dir(a, token)
      write_lane_dir(b, token)

      result = described_class.new([project('p1', root)]).resolve('p1', token)

      expect(result['state']).to eq 'ambiguous'
      expect(result['path']).to be_nil
      expect(result['paths'].map { |p| File.realpath(p) }).to contain_exactly(File.realpath(a), File.realpath(b))
    end

    it 'reports missing for an unclaimed lane rather than guessing a worktree' do
      wt = add_worktree(root, 'lane-a', 'feature/a')
      write_lane_dir(wt, token)

      expect(described_class.new([project('p1', root)]).resolve('p1', nil)['state']).to eq 'missing'
    end

    it 'builds the lane map once per repo, not once per resolve call' do
      wt = add_worktree(root, 'lane-a', 'feature/a')
      write_lane_dir(wt, token)
      resolver = described_class.new([project('p1', root)])

      allow(Tyrion::Repo).to receive(:worktrees).and_raise('rebuilt the map on resolve')
      3.times { expect(resolver.resolve('p1', token)['state']).to eq 'resolved' }
    end
  end

  describe '#probe dirty signals' do
    let(:root) { make_repo('r1') }
    let(:resolver) { described_class.new([]) }

    it 'counts NUL-delimited records and takes the newest mtime among only those paths' do
      File.write(File.join(root, 'untracked.txt'), "new\n")
      File.write(File.join(root, 'seed.txt'), "changed\n")
      old = Time.now - 3600
      File.utime(old, old, File.join(root, 'seed.txt'))

      signals = resolver.probe(root)

      expect(signals['dirty_count']).to eq 2
      expect(signals['newest_dirty_mtime']).to eq File.mtime(File.join(root, 'untracked.txt')).to_i
      expect(signals['partial']).to be false
    end

    it 'lists untracked files individually rather than collapsing a directory' do
      FileUtils.mkdir_p(File.join(root, 'nested'))
      File.write(File.join(root, 'nested', 'a.txt'), "a\n")
      File.write(File.join(root, 'nested', 'b.txt'), "b\n")

      # --untracked-files=all is what makes this 2 rather than 1.
      expect(resolver.probe(root)['dirty_count']).to eq 2
    end

    it 'consumes the destination path of a rename and does not count the original as a record' do
      git(root, 'mv', 'seed.txt', 'renamed.txt')

      signals = resolver.probe(root)

      expect(signals['dirty_count']).to eq 1
      expect(signals['newest_dirty_mtime']).to eq File.mtime(File.join(root, 'renamed.txt')).to_i
    end

    it 'skips deleted records and paths whose stat fails without raising' do
      File.unlink(File.join(root, 'seed.txt'))

      signals = resolver.probe(root)

      expect(signals['dirty_count']).to eq 1
      expect(signals['newest_dirty_mtime']).to be_nil
      expect(signals['partial']).to be false
    end

    it 'handles paths containing spaces and newlines, which NUL delimiting exists for' do
      File.write(File.join(root, "od d na\nme.txt"), "x\n")

      expect(resolver.probe(root)['dirty_count']).to eq 1
    end

    it 'reports a zero dirty count and a nil mtime for a clean worktree' do
      signals = resolver.probe(root)
      expect(signals['dirty_count']).to eq 0
      expect(signals['newest_dirty_mtime']).to be_nil
    end
  end

  describe '#probe commit signals' do
    let(:root) { make_repo('r1') }
    let(:resolver) { described_class.new([]) }

    # The story's criterion names `git log -1 --format=%ct%n%s`. The seam uses
    # `%H%n%ct%n%s` — the same single `git log -1` call with the sha prepended,
    # because the fleet_poll token specified for the next lane carries the newest
    # commit sha and fetching it separately would mean a second subprocess inside
    # a 2s-per-call, 3s-per-snapshot budget.
    it 'reads the newest commit sha, time and subject from one git log -1 --format call' do
      File.write(File.join(root, 'seed.txt'), "again\n")
      git(root, 'add', '-A')
      git(root, 'commit', '-qm', 'feat: the newest subject line')

      allow(Tyrion::Repo).to receive(:git_capture).and_call_original
      signals = resolver.probe(root)
      expect(Tyrion::Repo).to have_received(:git_capture).with(root, 'log', '-1', '--format=%H%n%ct%n%s')

      expect(signals['commit_subject']).to eq 'feat: the newest subject line'
      expect(signals['commit_at']).to be_within(120).of(Time.now.to_i)
      expect(signals['commit_sha']).to match(/\A[0-9a-f]{7,}\z/)
    end

    it 'takes the newest commit, not the first, and keeps a subject containing colons intact' do
      git(root, 'commit', '-q', '--allow-empty', '-m', 'fix(web): a: b: c')

      expect(resolver.probe(root)['commit_subject']).to eq 'fix(web): a: b: c'
    end

    it 'returns nil commit signals for a path that is not a git repo, without raising' do
      plain = File.join(tmp, 'plain2')
      FileUtils.mkdir_p(plain)

      signals = resolver.probe(plain)

      expect(signals['commit_at']).to be_nil
      expect(signals['commit_subject']).to be_nil
      expect(signals['dirty_count']).to be_nil
    end

    it 'returns all-nil signals for a nil path rather than probing the cwd' do
      signals = resolver.probe(nil)
      expect(signals.values_at('dirty_count', 'newest_dirty_mtime', 'commit_at', 'commit_subject')).to all(be_nil)
    end
  end

  describe 'subprocess timeout' do
    let(:root) { make_repo('r1') }

    it 'caps git subprocesses at 2 seconds' do
      expect(Tyrion::Repo::GIT_TIMEOUT_SECONDS).to eq 2
    end

    it 'kills a hung subprocess and raises GitTimeout rather than blocking forever' do
      started = Time.now
      expect { Tyrion::Repo.capture_with_timeout(%w[sleep 30], timeout: 0.2) }
        .to raise_error(Tyrion::Repo::GitTimeout)
      expect(Time.now - started).to be < 5
    end

    it 'degrades a timed-out probe to nil signals with partial true, never an exception' do
      allow(Tyrion::Repo).to receive(:git_capture).and_raise(Tyrion::Repo::GitTimeout)

      signals = described_class.new([]).probe(root)

      expect(signals['partial']).to be true
      expect(signals.values_at('dirty_count', 'newest_dirty_mtime', 'commit_at', 'commit_subject')).to all(be_nil)
    end

    it 'degrades a timed-out repo build to repo_missing rather than raising' do
      allow(Tyrion::Repo).to receive(:git_capture).and_raise(Tyrion::Repo::GitTimeout)

      resolver = described_class.new([project('p1', root)])

      expect(resolver.resolve('p1', 'claude:1:aa')['state']).to eq 'repo_missing'
    end

    it 'bounds git worktree list too, so a wedged repo cannot stall the whole build' do
      # This is the call the resolver makes once per project. Left unbounded it
      # would hang a page render no matter how tight the probe budget is.
      allow(Tyrion::Repo).to receive(:capture_with_timeout).and_raise(Tyrion::Repo::GitTimeout)

      expect { described_class.new([project('p1', root)]) }.not_to raise_error
      expect(described_class.new([project('p1', root)]).resolve('p1', 'claude:1:aa')['state']).to eq 'repo_missing'
    end

    it 'does not deadlock on a child that writes more to stderr than the pipe buffer holds' do
      # Reading stdout to EOF and only then draining a stderr pipe deadlocks
      # here, surfacing as a bogus GitTimeout on a healthy repo.
      noisy = 'STDERR.write("x" * 200_000); STDOUT.write("done")'

      expect(Tyrion::Repo.capture_with_timeout(['ruby', '-e', noisy], timeout: 5)).to eq 'done'
    end

    it 'scrubs output that is not valid UTF-8 rather than letting it explode at JSON time' do
      invalid = 'STDOUT.write("bad\xC3\x28name")'
      out = Tyrion::Repo.capture_with_timeout(['ruby', '-e', invalid], timeout: 5)

      expect(out.encoding).to eq Encoding::UTF_8
      expect(out).to be_valid_encoding
      expect { out.to_json }.not_to raise_error
    end

    it 'returns nil rather than raising when the binary does not exist' do
      expect(Tyrion::Repo.capture_with_timeout(%w[definitely-not-a-real-binary])).to be_nil
    end
  end
end
