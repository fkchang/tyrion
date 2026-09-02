# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
require_relative '../web/lib/tyrion_web/data'
require_relative '../web/lib/tyrion_web/presenter'
Dir.glob(File.expand_path('../web/views/**/*.rb', __dir__)).sort.each { |f| require f }

# fleet-visibility/cockpit-changes-trail-tabs
RSpec.describe 'TyrionWeb::Presenter.age_band_css' do
  it 'bands an event under 15 minutes old as recent' do
    expect(TyrionWeb::Presenter.age_band_css(Time.now.to_i - 60)).to eq 'ck-change-recent'
  end

  it 'bands an event under an hour old (but 15m or older) as hour' do
    expect(TyrionWeb::Presenter.age_band_css(Time.now.to_i - (20 * 60))).to eq 'ck-change-hour'
  end

  it 'bands an event an hour or older as old' do
    expect(TyrionWeb::Presenter.age_band_css(Time.now.to_i - (2 * 3600))).to eq 'ck-change-old'
  end

  it 'bands a nil epoch (no evidence) as old' do
    expect(TyrionWeb::Presenter.age_band_css(nil)).to eq 'ck-change-old'
  end

  it 'clamps a future epoch (clock skew) to recent rather than negative age' do
    expect(TyrionWeb::Presenter.age_band_css(Time.now.to_i + 100)).to eq 'ck-change-recent'
  end
end

RSpec.describe 'Views::Cockpit Changes and Trail tabs' do
  def project = { 'slug' => 'ck-proj', 'name' => 'CK Test' }
  def epic    = { 'slug' => 'e1', 'name' => 'Epic One' }

  def event(kind: 'note', at: Time.now.to_i, story_slug: 'my-story', text: 'made progress', **over)
    { kind: kind, at: at, story_slug: story_slug, text: text }.merge(over)
  end

  def note(kind: 'progress', story_slug: 'my-story', body: 'a note body', created_at: Time.now.utc.iso8601)
    { 'kind' => kind, 'story_slug' => story_slug, 'body' => body, 'created_at' => created_at }
  end

  def render(tab:, events: [], trail_notes: [])
    Views::Cockpit.new(
      project: project, epic: epic, tab: tab, rows: [], attention: [],
      story_counts: { done: 0, in_progress: 0, blocked: 0, pending: 0, total: 0 },
      events: events, trail_notes: trail_notes, stories: [],
      disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }, project_slug: 'ck-proj', token: 'tok',
      built_at: Time.now.to_i, stale: false, partial: false
    ).call
  end

  describe 'Changes tab' do
    it 'renders events in the order it is given, trusting the newest-first order Liveness.epic_events already guarantees' do
      older = event(at: Time.now.to_i - 3600, text: 'older event')
      newer = event(at: Time.now.to_i - 10, text: 'newer event')
      html = render(tab: 'changes', events: [newer, older])

      expect(html.index('newer event')).to be < html.index('older event')
    end

    it 'renders no more than the events it is given (the cap is Liveness.epic_events\' job, not the view\'s)' do
      events = 5.times.map { |i| event(at: Time.now.to_i - i, text: "event #{i}") }
      html = render(tab: 'changes', events: events)
      5.times { |i| expect(html).to include("event #{i}") }
    end

    it 'dims each row by age band via TyrionWeb::Presenter.age_band_css' do
      recent = event(at: Time.now.to_i - 10, text: 'recent one')
      old    = event(at: Time.now.to_i - 7200, text: 'old one')
      html = render(tab: 'changes', events: [recent, old])

      recent_row = html[/<div class="ck-change-row[^>]*>.*?recent one.*?<\/div>/m]
      old_row    = html[/<div class="ck-change-row[^>]*>.*?old one.*?<\/div>/m]
      expect(recent_row).to include('ck-change-recent')
      expect(old_row).to include('ck-change-old')
    end

    it 'renders no "since you looked" delta anywhere' do
      html = render(tab: 'changes', events: [event])
      expect(html.downcase).not_to include('since you looked')
    end

    it 'renders each event\'s age as a leaf data-at span, never on the row container' do
      html = render(tab: 'changes', events: [event])
      expect(html).not_to match(/class="ck-change-row[^"]*" data-at=/)
      expect(html).to match(/class="ck-change-age" data-at="\d+"/)
    end

    it 'renders the story slug alongside the event text' do
      html = render(tab: 'changes', events: [event(story_slug: 'a-specific-story', text: 'did a thing')])
      expect(html).to include('a-specific-story')
      expect(html).to include('did a thing')
    end

    it 'renders something readable for an event with no story_slug (e.g. a fleet-wide item)' do
      html = render(tab: 'changes', events: [event(story_slug: nil, text: 'no story here')])
      expect(html).to include('no story here')
    end

    it 'shows an empty state when there are no events' do
      html = render(tab: 'changes', events: [])
      expect(html).not_to include('class="ck-change-row')
      expect(html).to include('No changes yet')
    end
  end

  describe 'Trail tab' do
    it 'renders every note with no cap, using the existing note-entry styling' do
      notes = (1..3).map { |i| note(body: "note #{i}") }
      html = render(tab: 'trail', trail_notes: notes)

      (1..3).each { |i| expect(html).to include("note #{i}") }
      expect(html).to include('as-note-entry')
    end

    it 'renders no poller badge on the Trail tab' do
      html = render(tab: 'trail', trail_notes: [note])
      expect(html).not_to include('poll-badge')
    end

    it 'renders no poller badge is present on Now/Changes tabs (contrast check)' do
      expect(render(tab: 'now')).to include('poll-badge')
      expect(render(tab: 'changes')).to include('poll-badge')
    end

    it 'shows an empty state when there are no notes' do
      html = render(tab: 'trail', trail_notes: [])
      expect(html).to include('No notes yet')
    end
  end
end
