# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
Dir.glob(File.expand_path('../web/lib/tyrion_web/*.rb', __dir__)).sort.each { |f| require f }
Dir.glob(File.expand_path('../web/views/*.rb', __dir__)).sort.each { |f| require f }

# discoveries-markdown-rendering: markdown in discovery prose (bold, inline code,
# lists) must be interpreted on the Discoveries index, not shown as literal syntax.
# The per-discovery show page already covers this (discovery-show-view); this spec
# is the index page's own proof, reusing the same TyrionWeb::Presenter.markdown_lite
# helper rather than a second implementation.
RSpec.describe Views::DiscoveriesView do
  def render(spike: nil, findings_ready: [], marks: [])
    Views::DiscoveriesView.new(
      project: { 'name' => 'P', 'slug' => 'p' }, spike: spike,
      findings_ready: findings_ready, marks: marks,
      epic: { 'slug' => 'e', 'name' => 'E' }, stories: [],
      disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }, project_slug: 'p'
    ).call
  end

  def disc(id, extra = {})
    { 'id' => id, 'origin' => 'human', 'created_at' => Time.now.utc.iso8601 }.merge(extra)
  end

  it 'interprets bold, inline code, and a bullet list in a findings_ready finding' do
    d = disc('disc-010', 'question' => 'q',
                          'finding' => "The **root cause** is a stale `cache_key`:\n\n- checked prod\n- checked staging")
    html = render(findings_ready: [d])
    expect(html).to include('<strong>root cause</strong>')
    expect(html).to include('<code>cache_key</code>')
    expect(html).to include('<ul><li>checked prod</li><li>checked staging</li></ul>')
    expect(html).not_to include('**root cause**')
    expect(html).not_to include('`cache_key`')
  end

  it 'interprets markdown in a mark question' do
    d = disc('disc-011', 'question' => 'watch out for `retry` storms')
    html = render(marks: [d])
    expect(html).to include('<code>retry</code>')
    expect(html).not_to include('`retry`')
  end

  it 'interprets markdown in an active spike hypothesis and exit criteria' do
    d = disc('disc-012', 'question' => 'why is this slow?', 'hypothesis' => '**N+1** query',
                          'exit_criteria' => "- repro locally\n- confirm in logs")
    html = render(spike: d)
    expect(html).to include('<strong>N+1</strong>')
    expect(html).to include('<ul><li>repro locally</li><li>confirm in logs</li></ul>')
  end

  it 'escapes HTML in discovery prose rather than rendering it' do
    d = disc('disc-013', 'question' => '<script>alert(1)</script>')
    html = render(marks: [d])
    expect(html).to include('&lt;script&gt;')
    expect(html).not_to include('<script>alert(1)')
  end
end
