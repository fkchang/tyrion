# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
Dir.glob(File.expand_path('../web/lib/tyrion_web/*.rb', __dir__)).sort.each { |f| require f }
Dir.glob(File.expand_path('../web/views/*.rb', __dir__)).sort.each { |f| require f }

# ambient-route-and-view, criteria 3/5/6/7: standalone chrome-free render,
# escaped + truncated mark text, 14-day aging colour, nothing else on the page.
RSpec.describe Views::Ambient do
  def mark(question, age_days: 0, id: 'disc-001')
    { 'id' => id, 'question' => question, 'created_at' => (Time.now - age_days * 86_400).utc.iso8601 }
  end

  def render(marks: [], findings_ready_count: 0, project: { 'slug' => 'am-proj' })
    Views::Ambient.new(project: project, marks: marks, findings_ready_count: findings_ready_count).call
  end

  it 'renders a standalone document with no Layout chrome' do
    html = render(marks: [mark('a mark')])

    expect(html).to include('<!doctype html>')
    expect(html).to include('/ambient.css')
    %w[topbar sidebar War\ Room Roadmap Global\ View shared.css].each do |chrome|
      expect(html).not_to include(chrome)
    end
  end

  it 'shows the mark question text and its id' do
    html = render(marks: [mark('why is the poller flaky?', id: 'disc-042')])

    expect(html).to include('why is the poller flaky?')
    expect(html).to include('disc-042')
  end

  it 'HTML-escapes mark text' do
    html = render(marks: [mark('<script>alert(1)</script> & co')])

    expect(html).not_to include('<script>alert(1)</script>')
    expect(html).to include('&lt;script&gt;')
    expect(html).to include('&amp;')
  end

  it 'truncates very long mark text' do
    html = render(marks: [mark('x' * 500)])

    expect(html).to include('…')
    expect(html).not_to include('x' * 200)
  end

  describe 'aging colour' do
    it 'does not mark a 13-day-old mark as aged' do
      expect(render(marks: [mark('fresh', age_days: 13)])).not_to include('am-mark aged')
    end

    it 'marks a 14-day-old mark as aged' do
      expect(render(marks: [mark('old', age_days: 14)])).to include('am-mark aged')
    end
  end

  it 'shows the findings_ready line even with zero marks' do
    html = render(marks: [], findings_ready_count: 3)

    expect(html).to include('3 findings ready')
    expect(html).not_to include('<div class="am-mark"')
  end

  it 'renders a minimal no-project state when nothing resolves' do
    html = render(project: nil)

    expect(html).to include('no project')
    expect(html).not_to include('findings ready')
  end
end
