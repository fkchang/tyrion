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
  def disc(id, question, headline: nil, finding: nil, confidence: nil, recommendation: nil, created_at: Time.now.utc.iso8601)
    { 'id' => id, 'question' => question, 'headline' => headline, 'finding' => finding,
      'confidence' => confidence, 'recommendation' => recommendation, 'created_at' => created_at }
  end

  def age_iso(days)
    (Time.now - (days * 86_400)).utc.iso8601
  end

  describe 'TyrionWeb::Data.aged?' do
    it 'is false for a fresh timestamp' do
      expect(TyrionWeb::Data.aged?(age_iso(1), 14)).to be false
    end

    it 'is true once the threshold is crossed' do
      expect(TyrionWeb::Data.aged?(age_iso(15), 14)).to be true
    end

    it 'is false for a nil timestamp' do
      expect(TyrionWeb::Data.aged?(nil, 14)).to be false
    end
  end

  describe 'TyrionWeb::Data.discoveries_token' do
    def view(spike: nil, findings_ready: [], marks: [])
      { spike: spike, findings_ready: findings_ready, marks: marks }
    end

    def token_for(v)
      TyrionWeb::Data.discoveries_token(spike: v[:spike], findings_ready: v[:findings_ready], marks: v[:marks])
    end

    it 'is stable for the same discoveries' do
      v = view(marks: [disc('disc-001', 'q')])

      expect(token_for(v)).to eq token_for(v)
    end

    it 'changes when a new mark is filed' do
      a = token_for(view(marks: [disc('disc-001', 'q')]))
      b = token_for(view(marks: [disc('disc-001', 'q'), disc('disc-002', 'q2')]))

      expect(a).not_to eq b
    end

    it 'changes when a spike closes (spike disappears, a findings_ready row appears)' do
      before_close = token_for(view(spike: { 'id' => 'disc-005', 'question' => 'q', 'hypothesis' => nil, 'exit_criteria' => nil }))
      after_close  = token_for(view(findings_ready: [disc('disc-005', 'q', finding: 'f')]))

      expect(before_close).not_to eq after_close
    end

    it 'changes when a findings_ready finding/confidence/recommendation is edited' do
      a = token_for(view(findings_ready: [disc('disc-003', 'q', finding: 'draft')]))
      b = token_for(view(findings_ready: [disc('disc-003', 'q', finding: 'final')]))

      expect(a).not_to eq b
    end

    # The bug this closes: a tab left open all day never showed a row crossing
    # its aging threshold, because aging wasn't part of the fingerprint at all.
    it 'changes when a mark crosses the aging threshold' do
      fresh = token_for(view(marks: [disc('disc-001', 'q', created_at: age_iso(1))]))
      aged  = token_for(view(marks: [disc('disc-001', 'q', created_at: age_iso(20))]))

      expect(fresh).not_to eq aged
    end

    it 'changes when a findings_ready row crosses its (shorter) aging threshold' do
      fresh = token_for(view(findings_ready: [disc('disc-003', 'q', created_at: age_iso(1))]))
      aged  = token_for(view(findings_ready: [disc('disc-003', 'q', created_at: age_iso(4))]))

      expect(fresh).not_to eq aged
    end

    it 'does not collide when the id/question boundary shifts' do
      a = token_for(view(marks: [disc('a', 'bc')]))
      b = token_for(view(marks: [disc('ab', 'c')]))

      expect(a).not_to eq b
    end
  end

  describe 'Views::DiscoveriesView poll wiring' do
    def render(project: { 'slug' => 'proj-1' }, spike: nil, findings_ready: [], marks: [], token: 'tok123')
      Views::DiscoveriesView.new(
        project: project, spike: spike, findings_ready: findings_ready, marks: marks,
        epic: nil, stories: [], disc_summary: { spike: nil, ready_count: 0, mark_count: 0 }, token: token
      ).call
    end

    it 'polls the discoveries endpoint every 30 seconds' do
      html = render

      expect(html).to include('/api/discoveries_poll?project=')
      expect(html).to match(/var INTERVAL\s+= #{Views::DiscoveriesView::POLL_INTERVAL_MS};/)
      expect(Views::DiscoveriesView::POLL_INTERVAL_MS).to eq 30_000
    end

    it 'seeds the badge with the resolved project slug and current token' do
      html = render

      expect(html).to include('data-project="proj-1"')
      expect(html).to include('data-token="tok123"')
    end

    # Locks the view's "⚠ aging" badge to the exact same predicate the token
    # fingerprints (TyrionWeb::Data.aged?) -- a divergence here means a tab can
    # show the badge on one side of the threshold while the token (and thus the
    # reload it triggers) flips on the other.
    it 'renders the aging badge in lockstep with TyrionWeb::Data.aged?' do
      just_under = disc('disc-003', 'q', created_at: age_iso(2.7))
      html = render(findings_ready: [just_under])

      expect(html.include?('dv-aging-badge')).to eq(
        TyrionWeb::Data.aged?(just_under['created_at'], TyrionWeb::Data::READY_AGING_DAYS)
      )
    end

    it 'actually shows the aging badge once a findings_ready row is past the threshold' do
      past_threshold = disc('disc-004', 'q', created_at: age_iso(5))
      html = render(findings_ready: [past_threshold])

      expect(html).to include('dv-aging-badge')
    end

    it 'reuses active_story.rb\'s #poll-badge/#poll-dot ids so shared.css\'s fade-in/pulse animations apply' do
      html = render

      expect(html).to include('id="poll-badge"')
      expect(html).to include('id="poll-dot"')
    end

    it 'reloads the page on a token change' do
      expect(render).to match(/data\.token && data\.token !== knownToken.*window\.location\.reload/m)
    end

    # A stray falsy token (the 404 branch) must never latch and disable future
    # reloads -- the poller is seeded, not bootstrapped from null.
    it 'seeds knownToken from the page render rather than a null sentinel' do
      expect(render).to include("badge.dataset.token || null")
      expect(render).not_to include('knownToken === null')
    end

    it 'renders no poller at all when no project resolved' do
      html = render(project: nil)

      expect(html).not_to include('discoveries_poll')
      expect(html).not_to include('poll-badge')
    end
  end
end
