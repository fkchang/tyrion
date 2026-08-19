# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
Dir.glob(File.expand_path('../web/lib/tyrion_web/*.rb', __dir__)).sort.each { |f| require f }
Dir.glob(File.expand_path('../web/views/*.rb', __dir__)).sort.each { |f| require f }

# ambient-poll-endpoint: the poll payload carries enough to repaint both
# sections, and the token is deliberately blind to time so aging can't ride on it.
RSpec.describe 'ambient poll' do
  def mark(id, question, age_days: 0, headline: nil)
    { 'id' => id, 'question' => question, 'headline' => headline,
      'created_at' => (Time.now - age_days * 86_400).utc.iso8601 }
  end

  describe 'TyrionWeb::Data.ambient_token' do
    it 'is stable for the same marks and count' do
      a = TyrionWeb::Data.ambient_token(marks: [mark('disc-001', 'q')], findings_ready_count: 2)
      b = TyrionWeb::Data.ambient_token(marks: [mark('disc-001', 'q')], findings_ready_count: 2)

      expect(a).to eq b
    end

    it 'changes when a mark question changes' do
      a = TyrionWeb::Data.ambient_token(marks: [mark('disc-001', 'before')], findings_ready_count: 0)
      b = TyrionWeb::Data.ambient_token(marks: [mark('disc-001', 'after')], findings_ready_count: 0)

      expect(a).not_to eq b
    end

    it 'changes when a mark id changes' do
      a = TyrionWeb::Data.ambient_token(marks: [mark('disc-001', 'q')], findings_ready_count: 0)
      b = TyrionWeb::Data.ambient_token(marks: [mark('disc-002', 'q')], findings_ready_count: 0)

      expect(a).not_to eq b
    end

    # An id/question join with no unambiguous boundary would collide here.
    it 'does not collide when the id/question boundary shifts' do
      a = TyrionWeb::Data.ambient_token(marks: [mark('a', 'bc')], findings_ready_count: 0)
      b = TyrionWeb::Data.ambient_token(marks: [mark('ab', 'c')], findings_ready_count: 0)

      expect(a).not_to eq b
    end

    it 'changes when the findings_ready count changes' do
      a = TyrionWeb::Data.ambient_token(marks: [], findings_ready_count: 1)
      b = TyrionWeb::Data.ambient_token(marks: [], findings_ready_count: 2)

      expect(a).not_to eq b
    end

    # The reason criterion 6 exists: a mark crossing 14 days moves no token, so
    # aging must be recomputed client-side rather than ride on a token diff.
    it 'does not change as a mark ages' do
      fresh = TyrionWeb::Data.ambient_token(marks: [mark('disc-001', 'q', age_days: 1)], findings_ready_count: 0)
      old   = TyrionWeb::Data.ambient_token(marks: [mark('disc-001', 'q', age_days: 30)], findings_ready_count: 0)

      expect(fresh).to eq old
    end
  end

  describe 'TyrionWeb::Data.ambient_poll_payload' do
    let(:view) do
      { project: { 'slug' => 'am-proj' },
        marks: [mark('disc-007', 'why is the poller flaky?')],
        findings_ready_count: 3 }
    end

    it 'carries the marks list, not just the token' do
      payload = TyrionWeb::Data.ambient_poll_payload(view)

      # :text, not :question -- the payload carries the glance-surface fallback
      # (headline if set, else question), matching Output.discovery_glance_text.
      # headline/question also ride along separately so the inline-expanded
      # state (ambient's progressive disclosure) has full content to show.
      expect(payload[:marks]).to eq(
        [{ id: 'disc-007', text: 'why is the poller flaky?', headline: nil,
           question: 'why is the poller flaky?', created_at: view[:marks].first['created_at'] }]
      )
    end

    it 'prefers headline over question when both are set' do
      view    = { project: { 'slug' => 'am-proj' },
                  marks: [mark('disc-008', 'a long raw question nobody should see truncated',
                                headline: 'short glance summary')],
                  findings_ready_count: 0 }
      payload = TyrionWeb::Data.ambient_poll_payload(view)

      expect(payload[:marks].first[:text]).to eq 'short glance summary'
    end

    it 'carries the findings_ready count and a token' do
      payload = TyrionWeb::Data.ambient_poll_payload(view)

      expect(payload[:findings_ready_count]).to eq 3
      expect(payload[:token]).to be_a(String)
    end

    # The 404 body: same keys, so the page renders an empty pane instead of
    # choking on an error shape it has no branch for.
    it 'returns a renderable empty state for a no-project view' do
      payload = TyrionWeb::Data.ambient_poll_payload(project: nil, marks: [], findings_ready_count: 0)

      expect(payload.keys).to contain_exactly(:token, :marks, :findings_ready_count)
      expect(payload[:marks]).to eq []
      expect(payload[:findings_ready_count]).to eq 0
    end
  end

  describe 'Views::Ambient poll wiring' do
    def render(marks: [], findings_ready_count: 0, token: 'tok123', project: { 'slug' => 'am-proj' })
      Views::Ambient.new(project: project, marks: marks, findings_ready_count: findings_ready_count,
                         token: token).call
    end

    it 'seeds the pane with its project and current token' do
      html = render

      expect(html).to include('data-project="am-proj"')
      expect(html).to include('data-token="tok123"')
    end

    it 'gives both sections a stable handle to repaint into' do
      html = render(marks: [mark('disc-001', 'q')])

      expect(html).to include('id="am-marks"')
      expect(html).to include('id="am-ready"')
    end

    it 'emits created_at on each mark so aging can be recomputed without a reload' do
      html = render(marks: [mark('disc-001', 'q', age_days: 2)])

      expect(html).to include('data-created-at=')
    end

    it 'polls the ambient endpoint every 60 seconds' do
      html = render

      expect(html).to include('/api/ambient_poll?project=')
      expect(html).to match(/var INTERVAL\s+= #{Views::Ambient::POLL_INTERVAL_MS};/)
      expect(Views::Ambient::POLL_INTERVAL_MS).to eq 60_000
    end

    it 'repaints marks and the findings_ready line in the same apply()' do
      # Range-extract (not brace-matched) -- apply() now nests an `if` block for
      # the inline-expand markup, so a naive "up to the first line-leading `}`"
      # regex stops early. Bounding by the next function definition instead is
      # robust to internal nesting.
      html = render
      apply_body = html[/function apply\(data\) \{.*?(?=\n\s*function poll\(\))/m]

      expect(apply_body).to include('marksHost.textContent')
      expect(apply_body).to include('readyLine.textContent')
    end

    it 'refreshes aging outside the token-diff branch' do
      poll_body = render[/function poll\(\) \{(.*?)^\s*\}$/m, 1]

      # refreshAging() must sit after the token check, not inside it.
      expect(poll_body).to match(/if \(data\.token !== knownToken\).*\n\s*refreshAging\(\);/)
    end

    it 'derives the client aging threshold from the Ruby constant' do
      expect(render).to match(/var AGING_MS\s+= #{Views::Ambient::AGING_DAYS} \* 86400000;/)
    end

    it 'renders no poller at all when no project resolved' do
      expect(render(project: nil)).not_to include('ambient_poll')
    end
  end
end
