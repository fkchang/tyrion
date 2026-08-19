# frozen_string_literal: true

require 'spec_helper'

# These are skill instruction files, not code — these specs guard the properties that would
# silently regress if the text were edited carelessly: multi-epic commands actually appear,
# stay gated behind approval, and epic-tree mutation stays out of the per-epic skills.
RSpec.describe 'skill guidance for multi-epic decomposition' do
  let(:skills_dir) { File.expand_path('../../skills', __dir__) }
  let(:shape)          { File.read(File.join(skills_dir, 'tyrion-shape/SKILL.md')) }
  let(:orient)         { File.read(File.join(skills_dir, 'tyrion-orient/SKILL.md')) }
  let(:plan)           { File.read(File.join(skills_dir, 'tyrion-plan/SKILL.md')) }
  let(:complete_epic)  { File.read(File.join(skills_dir, 'tyrion-complete-epic/SKILL.md')) }

  describe 'tyrion-shape' do
    it 'detects multi-epic scope before drafting files' do
      detect = shape.index('### Step 3c: Multi-epic decomposition detection')
      write  = shape.index('### Step 4: Write draft files')

      expect(detect).not_to be_nil
      expect(write).not_to be_nil
      expect(detect).to be < write
    end

    it 'runs the multi-epic commands only inside the approval yes-branch' do
      yes_branch = shape[shape.index('Does this look right?')..]

      expect(yes_branch).to include('tyrion epic parent <sub-epic-1-slug> <parent-slug>')
      expect(yes_branch).to include('tyrion epic depends add <sub-epic-2-slug> <sub-epic-1-slug>')
      expect(yes_branch.index('tyrion import features/<parent-slug>.feature'))
        .to be < yes_branch.index('tyrion epic parent <sub-epic-1-slug> <parent-slug>')
    end
  end

  describe 'tyrion-orient' do
    it 'adds an epic-level rung to Next steps reporting the tree and the ready set' do
      next_steps = orient.index('## Next steps')
      expect(next_steps).not_to be_nil

      tail = orient[next_steps..]
      expect(tail).to include('tyrion epic list')
      expect(tail).to include('tyrion epic waves')
    end
  end

  describe 'tyrion-plan' do
    it 'does not cap a plan at one epic' do
      expect(plan).not_to match(/one epic per (?:major )?initiative/i)
    end

    it 'records edges at import time when a plan spans more than one epic' do
      expect(plan).to include('tyrion epic depends add <later-epic-slug> <earlier-epic-slug>')
    end
  end

  describe 'tyrion-complete-epic' do
    it 'surfaces what the seal unlocked and offers to activate it' do
      after_sealing = complete_epic.index('## After sealing')
      expect(after_sealing).not_to be_nil

      tail = complete_epic[after_sealing..]
      expect(tail).to include('Unlocked:')
      expect(tail).to include('tyrion epic activate')
      expect(tail).to match(/offer/i)
    end
  end

  describe 'out of scope' do
    # tyrion-implement and tyrion-orchestrate operate strictly inside one epic — an epic-tree
    # mutation issued from within an implementing lane would rewire the graph the orchestrator
    # is reading mid-run. Mentioning the tree (reading it) is fine; instructing a mutation isn't.
    it 'keeps epic-tree mutation commands out of the per-epic skills' do
      aggregate_failures do
        %w[tyrion-implement tyrion-orchestrate].each do |name|
          text = File.read(File.join(skills_dir, name, 'SKILL.md'))
          expect(text).not_to match(/^\s*(?:\$\s*)?tyrion epic (?:parent|depends add)\b/),
                               "#{name}/SKILL.md instructs an epic-tree mutation"
        end
      end
    end
  end
end
