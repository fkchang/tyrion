# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
Dir.glob(File.expand_path('../web/lib/tyrion_web/*.rb', __dir__)).sort.each { |f| require f }
Dir.glob(File.expand_path('../web/views/*.rb', __dir__)).sort.each { |f| require f }

# discovery-verdict-field: the per-discovery show page is the other "web Discoveries
# view" the criterion names alongside the list -- it must render the verdict too.
RSpec.describe Views::DiscoveryShow do
  def render(discovery)
    Views::DiscoveryShow.new(
      project: { 'name' => 'P', 'slug' => 'p' }, epic: nil, discovery: discovery,
      epics: [], stories: [], disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }
    ).call
  end

  def disc(status, verdict: nil)
    { 'id' => 'disc-001', 'status' => status, 'question' => 'q', 'origin' => 'human',
      'created_at' => Time.now.utc.iso8601, 'verdict' => verdict }
  end

  it 'badges a scored finding with its verdict' do
    html = render(disc('findings_ready', verdict: 'confirmed'))
    expect(html).to include('dv-verdict-confirmed')
    expect(html).to include('confirmed')
  end

  it 'renders no verdict badge when unscored' do
    html = render(disc('findings_ready'))
    expect(html).not_to include('dv-verdict')
  end
end
