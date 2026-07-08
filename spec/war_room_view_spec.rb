# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
Dir.glob(File.expand_path('../web/lib/tyrion_web/*.rb', __dir__)).sort.each { |f| require f }
Dir.glob(File.expand_path('../web/views/*.rb', __dir__)).sort.each { |f| require f }

# Criterion 5 (view): War Room never auto-picks .first as THE resume point when
# more than one lane is active — the web has no process identity.
RSpec.describe Views::WarRoomView do
  def story(slug, claimed_by: 'claude:1:a', next_action: 'do x')
    { 'slug' => slug, 'claimed_by' => claimed_by, 'last_note_at' => nil, 'next_action' => next_action }
  end

  def render(active:)
    Views::WarRoomView.new(
      project: { 'name' => 'P', 'slug' => 'p' }, queue: [], active: active,
      blocked: [], done: [],
      epic: { 'slug' => 'e', 'name' => 'E' }, stories: [],
      disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }, project_slug: 'p'
    ).call
  end

  context 'with a single active lane' do
    subject(:html) { render(active: [story('only-lane')]) }

    it 'renders a single Resume Point for that lane' do
      expect(html).to include('Resume Point')
      expect(html).to include('only-lane')
    end
  end

  context 'with two active lanes' do
    subject(:html) { render(active: [story('lane-one', claimed_by: 'claude:111:a'), story('lane-two', claimed_by: 'claude:222:b')]) }

    it 'shows every active lane' do
      expect(html).to include('lane-one')
      expect(html).to include('lane-two')
    end

    it 'shows an "N active lanes" badge' do
      expect(html).to include('2 active lanes')
    end

    it 'does NOT present a single auto-picked Resume Point' do
      expect(html).not_to include('Resume Point')
    end

    it 'labels each lane by its owner token' do
      expect(html).to include('claude:111:a')
      expect(html).to include('claude:222:b')
    end
  end
end
