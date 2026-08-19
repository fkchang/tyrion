# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
Dir.glob(File.expand_path('../web/lib/tyrion_web/*.rb', __dir__)).sort.each { |f| require f }
Dir.glob(File.expand_path('../web/views/*.rb', __dir__)).sort.each { |f| require f }

# discoveries-live-poll: the Discoveries index reloads on any change (new mark
# filed, spike closed) instead of needing a manual refresh -- reusing the
# reload-on-token-change pattern from active_story.rb's /api/poll rather than
# ambient's DOM-patch, since a full list page has no mid-read state to preserve.
RSpec.describe 'discoveries poll' do
  def disc(id, question, headline: nil, finding: nil, confidence: nil, recommendation: nil)
    { 'id' => id, 'question' => question, 'headline' => headline, 'finding' => finding,
      'confidence' => confidence, 'recommendation' => recommendation }
  end

  describe 'TyrionWeb::Data.discoveries_token' do
    def view(spike: nil, findings_ready: [], marks: [])
      { spike: spike, findings_ready: findings_ready, marks: marks }
    end

    it 'is stable for the same discoveries' do
      v = view(marks: [disc('disc-001', 'q')])

      expect(TyrionWeb::Data.discoveries_token(v)).to eq TyrionWeb::Data.discoveries_token(v)
    end

    it 'changes when a new mark is filed' do
      a = TyrionWeb::Data.discoveries_token(view(marks: [disc('disc-001', 'q')]))
      b = TyrionWeb::Data.discoveries_token(view(marks: [disc('disc-001', 'q'), disc('disc-002', 'q2')]))

      expect(a).not_to eq b
    end

    it 'changes when a spike closes (spike disappears, a findings_ready row appears)' do
      before_close = TyrionWeb::Data.discoveries_token(view(spike: { 'id' => 'disc-005', 'question' => 'q', 'hypothesis' => nil }))
      after_close  = TyrionWeb::Data.discoveries_token(view(findings_ready: [disc('disc-005', 'q', finding: 'f')]))

      expect(before_close).not_to eq after_close
    end

    it 'changes when a findings_ready finding/confidence/recommendation is edited' do
      a = TyrionWeb::Data.discoveries_token(view(findings_ready: [disc('disc-003', 'q', finding: 'draft')]))
      b = TyrionWeb::Data.discoveries_token(view(findings_ready: [disc('disc-003', 'q', finding: 'final')]))

      expect(a).not_to eq b
    end

    it 'is unaffected by which project the view resolved from' do
      v = view(marks: [disc('disc-001', 'q')])

      expect(TyrionWeb::Data.discoveries_token(v)).to eq TyrionWeb::Data.discoveries_token(v.merge(project: { 'slug' => 'x' }))
    end
  end

  describe 'Views::DiscoveriesView poll wiring' do
    def render(project: { 'slug' => 'proj-1' }, spike: nil, findings_ready: [], marks: [])
      Views::DiscoveriesView.new(
        project: project, spike: spike, findings_ready: findings_ready, marks: marks,
        epic: nil, stories: [], disc_summary: { spike: 0, findings_ready: 0, aging_marks: 0 }
      ).call
    end

    it 'polls the discoveries endpoint every 30 seconds' do
      html = render

      expect(html).to include('/api/discoveries_poll?project=')
      expect(html).to match(/var INTERVAL\s+= 30000;/)
    end

    it 'seeds the badge with the resolved project slug' do
      expect(render).to include('data-project="proj-1"')
    end

    it 'reloads the page on a token change' do
      expect(render).to match(/data\.token !== knownToken.*window\.location\.reload/m)
    end

    it 'renders no poller at all when no project resolved' do
      html = render(project: nil)

      expect(html).not_to include('discoveries_poll')
      expect(html).not_to include('discoveries-poll-badge')
    end
  end
end
