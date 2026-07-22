# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'hook infra: atomic_write + shim template' do
  # ── atomic_write ─────────────────────────────────────────────────────────

  describe 'Commands.atomic_write' do
    let(:tmpdir) { Dir.mktmpdir('tyrion-atomic-write') }

    after { FileUtils.remove_entry(tmpdir) }

    it 'writes the file with the given content' do
      path = File.join(tmpdir, 'nested', 'file.txt')
      Tyrion::Commands.atomic_write(path, 'hello world')
      expect(File.read(path)).to eq('hello world')
    end

    it 'creates parent directories as needed' do
      path = File.join(tmpdir, 'a', 'b', 'c', 'file.txt')
      Tyrion::Commands.atomic_write(path, 'nested')
      expect(File).to exist(path)
    end

    it 'applies the given mode when provided' do
      path = File.join(tmpdir, 'shim')
      Tyrion::Commands.atomic_write(path, '#!/bin/sh', mode: 0o755)
      expect(File.stat(path).mode & 0o777).to eq(0o755)
    end

    it 'leaves no partial file at the target path when the write raises before rename' do
      path = File.join(tmpdir, 'target.txt')
      allow(File).to receive(:rename).and_raise(StandardError, 'boom')

      expect { Tyrion::Commands.atomic_write(path, 'content') }.to raise_error(StandardError, 'boom')
      expect(File).not_to exist(path)
      # temp file cleaned up too
      expect(Dir.glob("#{path}.tmp.*")).to be_empty
    end

    it 'does not collide between concurrent-ish callers (unique temp names)' do
      path1 = File.join(tmpdir, 'f1.txt')
      path2 = File.join(tmpdir, 'f2.txt')
      Tyrion::Commands.atomic_write(path1, 'one')
      Tyrion::Commands.atomic_write(path2, 'two')
      expect(File.read(path1)).to eq('one')
      expect(File.read(path2)).to eq('two')
    end
  end

  # ── shim_script / installed_shim_version ────────────────────────────────

  describe 'Commands.shim_script + Commands.installed_shim_version' do
    let(:tmpdir) { Dir.mktmpdir('tyrion-shim') }

    after { FileUtils.remove_entry(tmpdir) }

    it 'generates a script containing exec "$@" and a fail-open command -v check' do
      script = Tyrion::Commands.shim_script
      expect(script).to include('exec "$@"')
      expect(script).to include('command -v')
    end

    it 'round-trips: a freshly generated shim reports its own SHIM_VERSION' do
      path = File.join(tmpdir, 'tyrion-shim')
      Tyrion::Commands.atomic_write(path, Tyrion::Commands.shim_script, mode: 0o755)
      expect(Tyrion::Commands.installed_shim_version(path)).to eq(Tyrion::Commands::SHIM_VERSION)
    end

    it 'embeds an explicitly requested version' do
      path = File.join(tmpdir, 'tyrion-shim')
      Tyrion::Commands.atomic_write(path, Tyrion::Commands.shim_script(version: 7), mode: 0o755)
      expect(Tyrion::Commands.installed_shim_version(path)).to eq(7)
    end

    it 'returns nil for a non-shim file' do
      path = File.join(tmpdir, 'not-a-shim')
      File.write(path, "#!/bin/sh\necho hi\n")
      expect(Tyrion::Commands.installed_shim_version(path)).to be_nil
    end

    it 'returns nil for a file that does not exist' do
      expect(Tyrion::Commands.installed_shim_version(File.join(tmpdir, 'nope'))).to be_nil
    end
  end
end
