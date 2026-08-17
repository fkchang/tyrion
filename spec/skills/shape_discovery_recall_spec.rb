# frozen_string_literal: true

require 'spec_helper'

# The discovery recall check is skill instruction text, not code — this guards the two
# properties that would silently break it: the recall must run before scenarios are drafted,
# and the skill must never be edited into calling `discovery defer` itself.
RSpec.describe 'skills/tyrion-shape/SKILL.md discovery recall check' do
  let(:skill) { File.read(File.expand_path('../../skills/tyrion-shape/SKILL.md', __dir__)) }

  it 'recalls open discoveries before drafting scenarios' do
    recall  = skill.index('tyrion discovery list --status all')
    extract = skill.index('### Step 3: Comprehend and extract')

    expect(recall).not_to be_nil
    expect(recall).to be < extract
  end

  it 'offers the defer command as a callout the human runs' do
    expect(skill).to include('consider tyrion discovery defer disc-NNN if out of scope')
  end

  it 'never instructs the skill to run discovery defer itself' do
    invocations = skill.scan(/^\s*(?:\$\s*)?tyrion discovery defer\b/)

    expect(invocations).to be_empty
    expect(skill).to include('Never run `tyrion discovery defer`')
  end
end
