# frozen_string_literal: true

require 'spec_helper'
require_relative '../web/lib/tyrion_web/presenter'

RSpec.describe 'TyrionWeb::Presenter.epic_state' do
  let(:epic_id) { 42 }
  let(:active_epic_id) { nil }

  def epic(status: 'active', archived_at: nil, unmet: [], child_stats: nil)
    { 'id' => epic_id, 'status' => status, 'archived_at' => archived_at, 'unmet' => unmet, 'child_stats' => child_stats }
  end

  def story(status:, last_note_at: nil)
    { 'status' => status, 'last_note_at' => last_note_at }
  end

  def fresh_ts
    (Time.now - 60).to_s   # 1 minute ago — within STALE_HOURS
  end

  def stale_ts
    (Time.now - (TyrionWeb::Presenter::STALE_HOURS + 2) * 3600).to_s  # beyond STALE_HOURS
  end

  subject { TyrionWeb::Presenter.epic_state(epic(**epic_opts), stories, active_epic_id) }
  let(:epic_opts) { {} }
  let(:stories)   { [] }

  # ── criterion 1: return shape ────────────────────────────────────────────────
  it 'returns a hash with the required keys' do
    expect(subject).to include(:state, :color_css, :glyph, :label, :action, :focus, :archived)
  end

  # ── criterion 2: empty ───────────────────────────────────────────────────────
  context 'no stories' do
    let(:stories) { [] }
    it 'state is :empty' do
      expect(subject[:state]).to eq :empty
    end
  end

  # ── criterion 3: sealed ──────────────────────────────────────────────────────
  context 'status is done' do
    let(:epic_opts) { { status: 'done' } }
    let(:stories) { [story(status: 'done')] }
    it 'state is :sealed' do
      expect(subject[:state]).to eq :sealed
    end
  end

  # ── criterion 4: ready ───────────────────────────────────────────────────────
  context 'all stories done, status is not done' do
    let(:stories) { [story(status: 'done'), story(status: 'done')] }
    it 'state is :ready' do
      expect(subject[:state]).to eq :ready
    end
  end

  # ── criterion 5: blocked ─────────────────────────────────────────────────────
  context '>= 1 blocked and 0 in_progress' do
    let(:stories) { [story(status: 'blocked'), story(status: 'pending')] }
    it 'state is :blocked' do
      expect(subject[:state]).to eq :blocked
    end
  end

  # ── criterion 6: active ──────────────────────────────────────────────────────
  context '>= 1 in_progress with fresh last_note_at' do
    let(:stories) { [story(status: 'in_progress', last_note_at: fresh_ts)] }
    it 'state is :active' do
      expect(subject[:state]).to eq :active
    end
  end

  # ── criterion 7: cold ────────────────────────────────────────────────────────
  context '>= 1 in_progress with stale last_note_at' do
    let(:stories) { [story(status: 'in_progress', last_note_at: stale_ts)] }
    it 'state is :cold' do
      expect(subject[:state]).to eq :cold
    end
  end

  # ── criterion 8: paused ──────────────────────────────────────────────────────
  context 'epic status is paused, no in_progress stories' do
    let(:epic_opts) { { status: 'paused' } }
    let(:stories) { [story(status: 'pending'), story(status: 'done')] }
    it 'state is :paused' do
      expect(subject[:state]).to eq :paused
    end
  end

  # ── criterion 9: started ─────────────────────────────────────────────────────
  context 'some done, some pending, 0 in_progress' do
    let(:stories) { [story(status: 'done'), story(status: 'pending')] }
    it 'state is :started' do
      expect(subject[:state]).to eq :started
    end
  end

  # ── criterion 10: queued ─────────────────────────────────────────────────────
  context 'all stories pending' do
    let(:stories) { [story(status: 'pending'), story(status: 'pending')] }
    it 'state is :queued' do
      expect(subject[:state]).to eq :queued
    end
  end

  # ── criterion 11: focus ──────────────────────────────────────────────────────
  context 'epic id matches active_epic_id' do
    let(:active_epic_id) { epic_id }
    let(:stories) { [story(status: 'pending')] }
    it ':focus is true' do
      expect(subject[:focus]).to be true
    end
  end

  context 'epic id does not match active_epic_id' do
    let(:active_epic_id) { epic_id + 1 }
    let(:stories) { [story(status: 'pending')] }
    it ':focus is false' do
      expect(subject[:focus]).to be false
    end
  end

  # ── criterion 12: archived ───────────────────────────────────────────────────
  context 'epic has archived_at set' do
    let(:epic_opts) { { archived_at: '2026-06-01 12:00:00' } }
    let(:stories) { [story(status: 'pending')] }
    it ':archived is true' do
      expect(subject[:archived]).to be true
    end
  end

  context 'epic has no archived_at' do
    let(:stories) { [story(status: 'pending')] }
    it ':archived is false' do
      expect(subject[:archived]).to be false
    end
  end

  # ── criterion 13: cold label includes hours-idle from time_ago ───────────────
  context 'cold state' do
    let(:stories) { [story(status: 'in_progress', last_note_at: stale_ts)] }
    it 'label includes the hours-idle string' do
      expect(subject[:label]).to match(/\dh ago|\d+h/)
    end
  end

  # ── criterion 14: container ──────────────────────────────────────────────────
  # web-epic-tree: a zero-own-story epic with descendants (child_stats set)
  # reads :container instead of :empty, showing the derived sealed roll-up.
  context 'zero own stories, child_stats present (has descendants)' do
    let(:epic_opts) { { child_stats: { done: 1, total: 3 } } }
    let(:stories) { [] }

    it 'state is :container' do
      expect(subject[:state]).to eq :container
    end

    it 'label reports the sealed-descendant roll-up' do
      expect(subject[:label]).to eq 'container · 1/3 sealed'
    end
  end

  # :sealed outranks :container -- a sealed empty container (every child
  # sealed, none of its own stories) still reads sealed, not container.
  context 'status is done, zero own stories, child_stats present' do
    let(:epic_opts) { { status: 'done', child_stats: { done: 3, total: 3 } } }
    let(:stories) { [] }

    it 'state is :sealed' do
      expect(subject[:state]).to eq :sealed
    end
  end

  context 'child_stats present but the epic has its own stories too' do
    let(:epic_opts) { { child_stats: { done: 1, total: 3 } } }
    let(:stories) { [story(status: 'pending')] }

    it 'does not read as :container' do
      expect(subject[:state]).not_to eq :container
    end
  end

  # ── criterion 15: waiting ────────────────────────────────────────────────────
  # web-epic-tree: an active epic with an unmet prerequisite and no stories
  # in flight reads :waiting.
  context 'active, unmet prerequisite, no in_progress stories' do
    let(:epic_opts) { { unmet: [{ slug: 'other-epic', reason: :active }] } }
    let(:stories) { [story(status: 'pending')] }

    it 'state is :waiting' do
      expect(subject[:state]).to eq :waiting
    end

    it 'label names the unmet prerequisite' do
      expect(subject[:label]).to include('waiting').and include('other-epic')
    end
  end

  # :active/:cold outrank :waiting -- in-progress work still reads
  # active/cold even if a prerequisite later regressed.
  context 'unmet prerequisite but a fresh in_progress story' do
    let(:epic_opts) { { unmet: [{ slug: 'other-epic', reason: :active }] } }
    let(:stories) { [story(status: 'in_progress', last_note_at: fresh_ts)] }

    it 'state is :active, not :waiting' do
      expect(subject[:state]).to eq :active
    end
  end

  context 'unmet prerequisite but a stale in_progress story' do
    let(:epic_opts) { { unmet: [{ slug: 'other-epic', reason: :active }] } }
    let(:stories) { [story(status: 'in_progress', last_note_at: stale_ts)] }

    it 'state is :cold, not :waiting' do
      expect(subject[:state]).to eq :cold
    end
  end

  context 'paused epic with an unmet prerequisite' do
    let(:epic_opts) { { status: 'paused', unmet: [{ slug: 'other-epic', reason: :active }] } }
    let(:stories) { [story(status: 'pending')] }

    it 'state is :paused, not :waiting -- its own status_tag already explains it' do
      expect(subject[:state]).to eq :paused
    end
  end
end
