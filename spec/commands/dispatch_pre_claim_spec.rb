# frozen_string_literal: true

require 'spec_helper'

# Specs for `tyrion claim <slug> --as <label>` (dispatch-pre-claim story).
# A lead pre-claims a story for a lane that does not exist yet; the placeholder
# is claimed_by="assigned:<label>" and the story stays pending. When an agent
# starts with TYRION_LANE=<label>, rung 3 of resolve_my_story adopts it and
# re-stamps claimed_by to the real lane token (rung 3 itself is covered in
# story_resolver_spec; here we prove the pre-claim → adoption path end to end).

RSpec.describe 'tyrion claim <slug> --as <label> (dispatch-pre-claim)' do
  let(:ctx) do
    tyrion_worktree(
      project_slug: 'preclaimproj',
      epic_slug:    'preclaim-epic',
      git_branch:   'feature/dispatch-pre-claim'
    )
  end
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  def make_story(slug:, title: slug)
    store.create_story(epic_id: epic['id'], slug: slug, title: title)
    store.find_story(epic['id'], slug)
  end

  describe 'cmd_claim' do
    it 'writes claimed_by="assigned:<label>" without changing status' do
      make_story(slug: 'work-me')

      expect { Tyrion::Commands.cmd_claim(['work-me', '--as', 'lane1'], store) }
        .to output(/assigned:lane1/).to_stdout

      story = store.find_story(epic['id'], 'work-me')
      expect(story['claimed_by']).to eq 'assigned:lane1'
      expect(story['status']).to eq 'pending'
    end

    it 'dies with usage when no --as label is given' do
      make_story(slug: 'work-me')
      expect { Tyrion::Commands.cmd_claim(['work-me'], store) }
        .to raise_error(SystemExit).and output(/Usage: tyrion claim/).to_stderr
    end

    it 'dies with usage when no slug is given' do
      expect { Tyrion::Commands.cmd_claim(['--as', 'lane1'], store) }
        .to raise_error(SystemExit).and output(/Usage: tyrion claim/).to_stderr
    end

    it 'dies when the story is not found' do
      expect { Tyrion::Commands.cmd_claim(['nope', '--as', 'lane1'], store) }
        .to raise_error(SystemExit).and output(/not found/).to_stderr
    end

    it 'dies when the story is not pending' do
      s = make_story(slug: 'already-going')
      store.start_story(s['id'], claimed_by: 'claude:1:x')
      expect { Tyrion::Commands.cmd_claim(['already-going', '--as', 'lane1'], store) }
        .to raise_error(SystemExit).and output(/not pending/).to_stderr
    end
  end

  describe 'pre-claim → rung-3 adoption end to end' do
    around do |ex|
      saved = ENV.delete('TYRION_LANE')
      ENV['TYRION_LANE'] = 'lane1'
      ex.run
      saved.nil? ? ENV.delete('TYRION_LANE') : (ENV['TYRION_LANE'] = saved)
    end

    let(:real_token) { 'claude:222:realstamp' }

    before do
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(real_token)
      stub_repo(active_story: nil)
    end

    it 'adopts the pre-claimed story and re-stamps to the real token, still pending' do
      make_story(slug: 'work-me')
      Tyrion::Commands.cmd_claim(['work-me', '--as', 'lane1'], store)

      resolved = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: false)

      expect(resolved['slug']).to eq 'work-me'
      reloaded = store.find_story(epic['id'], 'work-me')
      expect(reloaded['claimed_by']).to eq real_token
      expect(reloaded['status']).to eq 'pending'
    end
  end
end
