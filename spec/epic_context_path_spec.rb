# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe 'Tyrion::Commands.epic_context_path' do
  let(:root) { Dir.mktmpdir('tyrion-ctx-path-') }
  let(:org)  { File.join(root, 'features', 'my-epic.context.org') }
  let(:md)   { File.join(root, 'features', 'my-epic.context.md') }

  before { FileUtils.mkdir_p(File.join(root, 'features')) }
  after  { FileUtils.rm_rf(root) }

  it 'returns the .org path when only the .org file exists' do
    File.write(org, '* Learnings')
    expect(Tyrion::Commands.epic_context_path('my-epic', root: root)).to eq org
  end

  it 'returns the .md path when only the .md file exists' do
    File.write(md, '# Learnings')
    expect(Tyrion::Commands.epic_context_path('my-epic', root: root)).to eq md
  end

  it 'prefers .org over .md when both are present' do
    File.write(org, '* Learnings')
    File.write(md, '# Learnings')
    expect(Tyrion::Commands.epic_context_path('my-epic', root: root)).to eq org
  end

  it 'returns nil when neither file exists' do
    expect(Tyrion::Commands.epic_context_path('my-epic', root: root)).to be_nil
  end

  it 'returns nil when the root is nil' do
    expect(Tyrion::Commands.epic_context_path('my-epic', root: nil)).to be_nil
  end

  it 'defaults its root to the main checkout when one resolves' do
    File.write(org, '* Learnings')
    allow(Tyrion::Repo).to receive(:main_root).and_return(root)

    expect(Tyrion::Commands.epic_context_path('my-epic')).to eq org
  end

  it 'falls back to the worktree root when the main root cannot be resolved' do
    File.write(md, '# Learnings')
    allow(Tyrion::Repo).to receive(:main_root).and_return(nil)
    allow(Tyrion::Repo).to receive(:worktree_root).and_return(root)

    expect(Tyrion::Commands.epic_context_path('my-epic')).to eq md
  end
end
