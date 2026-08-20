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

# Parallel lanes: several stories can be in_progress at once, so every sidebar
# story row must link to its exact /stories/:id — never the ambient '/' resolver,
# which showed whichever in-progress story it resolved first.
RSpec.describe Views::Layout do
  subject(:html) do
    Views::Layout.new(
      project: { 'slug' => 'tyrion', 'name' => 'Tyrion' },
      epic: { 'slug' => 'ukf-h0' },
      stories: [
        { 'id' => 11, 'slug' => 'i1', 'status' => 'in_progress' },
        { 'id' => 12, 'slug' => 'i2', 'status' => 'in_progress' },
        { 'id' => 13, 'slug' => 'i3', 'status' => 'pending' }
      ],
      disc_summary: { spike: nil, ready_count: 0, mark_count: 0 },
      project_slug: 'tyrion'
    ).call { }
  end

  it 'links each in-progress sidebar row to its own story id' do
    expect(html).to include('href="/stories/11"')
    expect(html).to include('href="/stories/12"')
  end

  it 'does not route any sidebar story row through the ambient active-story view' do
    expect(html).not_to match(%r{class="story-row[^"]*" href="/(\?|")})
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

# sidebar-epic-gating-fix: a project with no active epic (e.g. a pure-spike
# project) must still get the project name and discovery strip -- only the
# epic-scoped stories section is omitted, and only silently, not with an
# error state.
RSpec.describe Views::Layout do
  subject(:html) do
    Views::Layout.new(
      project: { 'slug' => 'crimson-maestro', 'name' => 'Crimson Maestro' },
      epic: nil, stories: [],
      disc_summary: { spike: nil, ready_count: 2, mark_count: 9 },
      project_slug: 'crimson-maestro'
    ).call { }
  end

  it 'shows the project name' do
    expect(html).to include('crimson-maestro')
  end

  it 'still shows the discovery strip' do
    expect(html).to include('disc-strip').and include('2 ready').and include('9 marks')
  end

  it 'does not render the false "No active project" message' do
    expect(html).not_to include('No active project')
  end

  it 'omits the epic-scoped stories section rather than showing an error' do
    expect(html).not_to include('Stories ·')
  end
end
