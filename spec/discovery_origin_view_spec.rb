# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
Dir.glob(File.expand_path('../web/lib/tyrion_web/*.rb', __dir__)).sort.each { |f| require f }
Dir.glob(File.expand_path('../web/views/*.rb', __dir__)).sort.each { |f| require f }

# Criteria 8-10 (web surface): every discovery card carries the same [agent]/[human]
# marker the CLI prints, so origin survives the jump from terminal to browser.
RSpec.describe Views::DiscoveriesView do
  def render(spike: nil, findings_ready: [], marks: [])
    Views::DiscoveriesView.new(
      project: { 'name' => 'P', 'slug' => 'p' }, spike: spike,
      findings_ready: findings_ready, marks: marks,
      epic: { 'slug' => 'e', 'name' => 'E' }, stories: [],
      disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }, project_slug: 'p'
    ).call
  end

  def disc(id, status, question, origin)
    { 'id' => id, 'status' => status, 'question' => question, 'origin' => origin,
      'created_at' => Time.now.utc.iso8601 }
  end

  it 'tags the active spike card with its origin' do
    html = render(spike: disc('disc-001', 'active_spike', 'agent spike', 'agent'))
    expect(html).to include('[agent]')
  end

  it 'tags findings_ready cards with their origin' do
    html = render(findings_ready: [disc('disc-002', 'findings_ready', 'human finding', 'human')])
    expect(html).to include('[human]')
  end

  it 'tags mark cards with their origin' do
    html = render(marks: [disc('disc-003', 'mark', 'agent mark', 'agent'),
                          disc('disc-004', 'mark', 'human mark', 'human')])
    expect(html).to include('[agent]')
    expect(html).to include('[human]')
  end

  it 'never renders CLI colour escapes into the HTML' do
    html = render(marks: [disc('disc-005', 'mark', 'agent mark', 'agent')])
    expect(html).not_to include("\e[")
  end

  # discovery-verdict-field: the verdict axis must render distinctly from the status
  # badge, on the one card type (findings_ready) that can ever carry one.
  it 'badges a scored finding with its verdict, distinct from the status card class' do
    d = disc('disc-006', 'findings_ready', 'q', 'agent').merge('verdict' => 'falsified_alternative')
    html = render(findings_ready: [d])
    expect(html).to include('dv-verdict-falsified-alternative')
    expect(html).to include('falsified alternative')
  end

  it 'renders no verdict badge when unscored' do
    html = render(findings_ready: [disc('disc-007', 'findings_ready', 'q', 'agent')])
    expect(html).not_to include('dv-verdict')
  end
end
