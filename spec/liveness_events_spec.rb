# frozen_string_literal: true

require 'spec_helper'
require 'json'

# fleet-visibility/epic-event-queries: Tyrion::Liveness.epic_events merges the
# four Store bulk reads into one derived feed per the design's derivation
# table. The load-bearing property is the double-emit guard: block, unblock
# and reopen persist real blocker/recovery notes carrying metadata.action, and
# those must surface as their own lifecycle event kind exactly once, never
# also as a generic "note" event.
RSpec.describe 'Tyrion::Liveness.epic_events' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'e1') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  def kinds(events) = events.map { |e| e[:kind] }

  it 'derives started from stories.started_at and done from stories.completed_at' do
    s = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    store.start_story(s['id'], claimed_by: 'lane-1')
    store.complete_story(s['id'], 'done', force: true)

    events = Tyrion::Liveness.epic_events(store, epic['id'])

    expect(kinds(events)).to include('started', 'done')
    expect(events.find { |e| e[:kind] == 'started' }[:story_slug]).to eq 's1'
  end

  it 'derives a criterion_checked event from criteria.checked_at with the criterion text' do
    s = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    store.add_criteria(s['id'], [{ keyword: 'Then', semantic_kind: 'then', text: 'a thing happens' }])
    c = store.criteria_for_story(s['id']).first
    store.check_criterion(s['id'], c['position'], 'evidence')

    events = Tyrion::Liveness.epic_events(store, epic['id'])
    ev = events.find { |e| e[:kind] == 'criterion_checked' }

    expect(ev).not_to be_nil
    expect(ev[:text]).to include('a thing happens')
    expect(ev[:story_slug]).to eq 's1'
  end

  it 'derives a gate event from a gate note\'s metadata gate and result' do
    s = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    store.add_note(s['id'], 'gate', 'pre-push: PASS', metadata: JSON.dump('gate' => 'pre-push', 'result' => 'pass'))

    events = Tyrion::Liveness.epic_events(store, epic['id'])
    ev = events.find { |e| e[:kind] == 'gate' }

    expect(ev).not_to be_nil
    expect(ev[:text]).to include('pre-push').and include('pass')
  end

  it 'derives a commit event from a commit note\'s metadata shas' do
    s = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    store.add_note(s['id'], 'commit', 'committed abc1234', metadata: JSON.dump('shas' => %w[abc1234], 'count' => 1))

    events = Tyrion::Liveness.epic_events(store, epic['id'])
    ev = events.find { |e| e[:kind] == 'commit' }

    expect(ev).not_to be_nil
    expect(ev[:text]).to include('abc1234')
  end

  it 'derives mark filed from a discovery whose source_story_id is in the epic' do
    s = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    store.create_discovery(project_id: ctx.project['id'], status: 'mark', source_story_id: s['id'],
                            question: 'noticed a thing', headline: 'a real headline')

    events = Tyrion::Liveness.epic_events(store, epic['id'])
    ev = events.find { |e| e[:kind] == 'mark' }

    expect(ev).not_to be_nil
    expect(ev[:text]).to include('a real headline')
    expect(ev[:story_slug]).to eq 's1'
  end

  it 'derives blocked/unblocked/reopened from metadata.action, not as generic notes, and never emits both' do
    s = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    store.start_story(s['id'], claimed_by: 'lane-1')
    store.block_story(s['id'], blocked_on: 'waiting on disc-001')
    store.add_note(s['id'], 'blocker', 'block', metadata: JSON.dump('action' => 'block', 'blocked_on' => 'waiting on disc-001'))
    store.unblock_story(s['id'])
    store.add_note(s['id'], 'blocker', 'unblock', metadata: JSON.dump('action' => 'unblock'))

    events = Tyrion::Liveness.epic_events(store, epic['id'])
    blocker_events = events.select { |e| %w[blocked unblocked].include?(e[:kind]) }

    expect(blocker_events.size).to eq 2
    expect(kinds(events)).not_to include('note') # this story's only notes were the two action rows
  end

  it 'derives reopened from a recovery note carrying metadata.action=reopen' do
    s = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    store.complete_story(s['id'], 'done', force: true)
    store.reopen_story(s['id'], claimed_by: 'lane-1')
    store.add_note(s['id'], 'recovery', 'reopened: rework needed (was done)',
                   metadata: JSON.dump('action' => 'reopen', 'reason' => 'rework needed', 'prior_status' => 'done'))

    events = Tyrion::Liveness.epic_events(store, epic['id'])
    expect(kinds(events)).to include('reopened')
    # complete_story's own 'handoff' summary note is a real, separate generic
    # note event -- only the reopen action row itself must not ALSO surface
    # as a generic note (the double-emit this story guards against).
    expect(events.count { |e| e[:kind] == 'reopened' }).to eq 1
    expect(events.select { |e| e[:kind] == 'note' }.map { |e| e[:text] }).not_to include('reopened: rework needed (was done)')
  end

  it 'excludes block/unblock/reopen rows from the generic note stream so each lifecycle event appears exactly once' do
    s = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    store.start_story(s['id'], claimed_by: 'lane-1')
    store.block_story(s['id'], blocked_on: 'reason')
    store.add_note(s['id'], 'blocker', 'blocked: reason', metadata: JSON.dump('action' => 'block', 'blocked_on' => 'reason'))

    events = Tyrion::Liveness.epic_events(store, epic['id'])
    blocked_events = events.select { |e| e[:kind] == 'blocked' }

    expect(blocked_events.size).to eq 1
    expect(events.select { |e| e[:kind] == 'note' }).to be_empty
  end

  it 'derives a generic note event for an ordinary note kind, excluded kinds aside' do
    s = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    store.add_note(s['id'], 'progress', 'made progress on the thing')

    events = Tyrion::Liveness.epic_events(store, epic['id'])
    ev = events.find { |e| e[:kind] == 'note' }

    expect(ev).not_to be_nil
    expect(ev[:text]).to include('made progress on the thing')
    expect(ev[:story_slug]).to eq 's1'
  end

  it 'omits claim events entirely -- claiming a story emits no note' do
    s = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    store.start_story(s['id'], claimed_by: 'lane-1')

    events = Tyrion::Liveness.epic_events(store, epic['id'])
    expect(kinds(events)).not_to include('claim', 'claimed')
  end

  it 'merges and re-caps the four sources to the limit, newest first' do
    s = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    10.times { |i| store.add_note(s['id'], 'progress', "note #{i}") }

    events = Tyrion::Liveness.epic_events(store, epic['id'], limit: 3)

    expect(events.size).to eq 3
    expect(events).to eq events.sort_by { |e| -(e[:at] || 0) }
  end

  it 'returns nothing for an epic with no activity' do
    expect(Tyrion::Liveness.epic_events(store, epic['id'])).to eq []
  end
end
