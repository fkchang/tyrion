# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Tyrion::Commands.cmd_pocket' do
  let(:ctx) do
    tyrion_worktree(
      project_slug: 'myproj',
      project_name: 'My Project',
      epic_slug:    'auth-epic',
      epic_name:    'Auth Epic'
    )
  end
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  # Shared setup: one story with two criteria (one met, one unchecked)
  let(:story) do
    s = store.create_story(epic_id: epic['id'], slug: 'login-story', title: 'Login Story')
    store.add_criteria(s['id'], [
      { keyword: 'Given', semantic_kind: 'given', text: 'a registered user' },
      { keyword: 'Then',  semantic_kind: 'then',  text: 'the user sees the dashboard' }
    ])
    store.check_criterion(s['id'], 1, 'user exists in DB')
    s
  end

  # criterion 1 — shows epic and story slugs
  context 'criterion 1 — shows active epic and story slugs' do
    it 'prints epic: and story: lines with correct slugs' do
      story # materialise
      expect { Tyrion::Commands.cmd_pocket([], store) }
        .to output(/^epic: auth-epic$/).to_stdout
      expect { Tyrion::Commands.cmd_pocket([], store) }
        .to output(/^story: login-story$/).to_stdout
    end
  end

  # criterion 2 — shows unchecked criteria only
  context 'criterion 2 — shows unchecked criteria' do
    it 'prints unchecked criterion with [ ] prefix' do
      story # materialise
      expect { Tyrion::Commands.cmd_pocket([], store) }
        .to output(/\[\s*\]\s*Then\s+the user sees the dashboard/).to_stdout
    end
  end

  # criterion 3 — does not show met criteria
  context 'criterion 3 — omits met criteria from output' do
    it 'does not print the met Given criterion text' do
      story # materialise
      expect { Tyrion::Commands.cmd_pocket([], store) }
        .not_to output(/a registered user/).to_stdout
    end
  end

  # criterion 4 — does not show branch/worktree/dirty context
  context 'criterion 4 — omits branch/worktree/dirty git context lines' do
    it 'prints neither Branch:, Worktree:, nor Dirty: labels' do
      story # materialise
      expect { Tyrion::Commands.cmd_pocket([], store) }
        .not_to output(/Branch:|Worktree:|Dirty:/).to_stdout
    end
  end

  # criterion 5 — prefers in_progress story over pending
  context 'criterion 5 — prefers in_progress story over a later pending story' do
    it 'shows the in_progress story slug, not the second pending story' do
      store.start_story(story['id'])

      story2 = store.create_story(epic_id: epic['id'], slug: 'second-story', title: 'Second Story')
      store.add_criteria(story2['id'], [
        { keyword: 'Then', semantic_kind: 'then', text: 'second story criterion' }
      ])

      out, = capture_io { Tyrion::Commands.cmd_pocket([], store) }
      expect(out).to match(/^story: login-story$/)
      expect(out).not_to match(/second-story/)
    end
  end

  # criterion 6 — falls back to first pending when no in_progress story
  context 'criterion 6 — falls back to first pending story when none is in_progress' do
    it 'shows login-story as the selected pending story' do
      story # materialise
      expect { Tyrion::Commands.cmd_pocket([], store) }
        .to output(/^story: login-story$/).to_stdout
    end
  end

  # criterion 7 — no active or pending story prints message
  context 'criterion 7 — no active or pending story prints informational message' do
    it 'prints "No active or pending story" when the only story is abandoned' do
      store.update_story(story['id'], 'status' => 'abandoned')
      expect { Tyrion::Commands.cmd_pocket([], store) }
        .to output(/No active or pending story/).to_stdout
    end
  end
end
