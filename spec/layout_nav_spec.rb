# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
Dir.glob(File.expand_path('../web/lib/tyrion_web/*.rb', __dir__)).sort.each { |f| require f }
Dir.glob(File.expand_path('../web/views/*.rb', __dir__)).sort.each { |f| require f }

# Criteria 1-6 (multitab-url-scoping): every nav tab link must carry both
# ?project= and &epic= so each browser tab stays scoped to its own epic.
RSpec.describe Views::Layout do
  subject(:html) do
    Views::Layout.new(
      project: { 'slug' => 'tyrion', 'name' => 'Tyrion' },
      epic: { 'slug' => 'scott-feedback-tier3' },
      stories: [], disc_summary: { spike: nil, ready_count: 0, mark_count: 0 },
      project_slug: 'tyrion'
    ).call { }
  end

  it 'threads project and epic into the War Room nav link' do
    expect(html).to include('href="/warroom?project=tyrion&epic=scott-feedback-tier3"')
  end

  it 'threads project and epic into the Roadmap nav link' do
    expect(html).to include('href="/roadmap?project=tyrion&epic=scott-feedback-tier3"')
  end
end

RSpec.describe Views::Layout do
  subject(:html) do
    Views::Layout.new(
      project: nil, epic: nil,
      stories: [], disc_summary: { spike: nil, ready_count: 0, mark_count: 0 },
      project_slug: nil
    ).call { }
  end

  it 'renders plain nav hrefs with no query string when there is no project or epic scope' do
    expect(html).to include('href="/warroom"')
    expect(html).to include('href="/roadmap"')
  end
end
