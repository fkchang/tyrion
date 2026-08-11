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

# Criteria progress bar: a glanceable met/total signal per card, shown only
# when the story actually has criteria.
RSpec.describe 'Views::WarRoomView — criteria progress bar' do
  def story(slug, criteria_met:, criteria_total:)
    { 'slug' => slug, 'claimed_by' => 'claude:1:a', 'last_note_at' => nil, 'next_action' => 'do x',
      'criteria_met' => criteria_met, 'criteria_total' => criteria_total }
  end

  def render(queue:)
    Views::WarRoomView.new(
      project: { 'name' => 'P', 'slug' => 'p' }, queue: queue, active: [],
      blocked: [], done: [],
      epic: { 'slug' => 'e', 'name' => 'E' }, stories: [],
      disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }, project_slug: 'p'
    ).call
  end

  it 'renders a "met/total" progress bar for a story with criteria' do
    html = render(queue: [story('has-criteria', criteria_met: 3, criteria_total: 5)])
    expect(html).to include('3/5')
    expect(html).to include('rm-mini-track')
  end

  it 'renders no progress bar for a story with zero criteria' do
    html = render(queue: [story('no-criteria', criteria_met: 0, criteria_total: 0)])
    expect(html).not_to include('wr-card-progress')
  end
end

# Traceability: the Blocked lane card shows why a story is blocked, so a
# viewer doesn't have to click through to the story detail to see the reason.
RSpec.describe 'Views::WarRoomView — blocked card reason' do
  def story(slug, blocked_on: nil)
    { 'slug' => slug, 'claimed_by' => 'claude:1:a', 'last_note_at' => nil, 'next_action' => 'do x',
      'blocked_on' => blocked_on }
  end

  def render(blocked:)
    Views::WarRoomView.new(
      project: { 'name' => 'P', 'slug' => 'p' }, queue: [], active: [],
      blocked: blocked, done: [],
      epic: { 'slug' => 'e', 'name' => 'E' }, stories: [],
      disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }, project_slug: 'p'
    ).call
  end

  it 'shows the blocked_on reason on the blocked card' do
    html = render(blocked: [story('blocked-one', blocked_on: 'waiting on Finance approval')])
    expect(html).to include('waiting on Finance approval')
    expect(html).to include('wr-card-blocked-reason')
  end

  it 'truncates a long reason to about 80 characters' do
    long_reason = 'x' * 200
    html = render(blocked: [story('blocked-long', blocked_on: long_reason)])
    expect(html).to include('x' * 80)
    expect(html).not_to include('x' * 81)
  end

  it 'renders no reason line when blocked_on is nil' do
    html = render(blocked: [story('blocked-no-reason', blocked_on: nil)])
    expect(html).not_to include('wr-card-blocked-reason')
  end
end
