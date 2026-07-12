# frozen_string_literal: true

require 'spec_helper'

# tyrion done gate-refusal enforcement: never close over a gate whose latest
# result is fail. Gate history is built with real cmd_gate calls (see gate_spec.rb).
RSpec.describe 'tyrion done gate refusal' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
    allow(Tyrion::Repo).to receive(:clear_active_story)
  end

  # Stories carry no criteria, so `tyrion done` is free to close them normally —
  # isolating the gate check as the only thing that can block the close.
  def create_story(slug)
    store.create_story(epic_id: epic['id'], slug: slug, title: slug)
    store.find_story(epic['id'], slug)
  end

  def gate(slug, name, result)
    capture_io { Tyrion::Commands.cmd_gate([slug, name, result], store) }
  end

  def status_of(slug)
    store.find_story(epic['id'], slug)['status']
  end

  describe 'criterion 1 — refuses and lists each failing gate' do
    before do
      create_story('leaky')
      gate('leaky', 'pre-push', 'fail')
      gate('leaky', 'uat', 'fail')
    end

    it 'exits 1 without closing the story' do
      expect { Tyrion::Commands.cmd_done(['leaky', 'summary'], store) }
        .to raise_error(SystemExit).and output(/Refusing to close leaky/).to_stderr
      expect(status_of('leaky')).not_to eq('done')
    end

    it 'names every gate whose latest result is fail' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_done(['leaky', 'summary'], store) }
          .to raise_error(SystemExit)
      end
      expect(err).to match(/pre-push/)
      expect(err).to match(/uat/)
    end

    it 'does not list a gate whose latest result is pass' do
      gate('leaky', 'code-review', 'pass')
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_done(['leaky', 'summary'], store) }
          .to raise_error(SystemExit)
      end
      expect(err).not_to match(/code-review/)
    end
  end

  describe 'criterion 2 — --force closes and records a traceable override' do
    before do
      create_story('forced')
      gate('forced', 'pre-push', 'fail')
    end

    it 'closes the story' do
      capture_io { Tyrion::Commands.cmd_done(['forced', 'shipped anyway', '--force'], store) }
      expect(status_of('forced')).to eq('done')
    end

    it 'records a force-close gate note naming the overridden gate' do
      capture_io { Tyrion::Commands.cmd_done(['forced', 'shipped anyway', '--force'], store) }
      note = store.gate_notes_for_story(store.find_story(epic['id'], 'forced')['id'])
                  .find { |n| n['body'].start_with?('force-close') }
      expect(note).not_to be_nil
      expect(JSON.parse(note['metadata'])).to include(
        'gate' => 'force-close', 'result' => 'pass', 'detail' => 'overrode failing: pre-push'
      )
    end

    it 'renders the force-close gate in tyrion show Gates section' do
      capture_io { Tyrion::Commands.cmd_done(['forced', 'shipped anyway', '--force'], store) }
      out, = capture_io { Tyrion::Commands.cmd_show(['forced'], store) }
      expect(out).to match(/Gates:/)
      expect(out).to match(/force-close/)
    end
  end

  describe 'criterion 3 — a fail later re-recorded as pass closes normally' do
    it 'closes without --force' do
      create_story('recovered')
      gate('recovered', 'pre-push', 'fail')
      gate('recovered', 'pre-push', 'pass')

      expect { capture_io { Tyrion::Commands.cmd_done(['recovered', 'fixed then shipped'], store) } }
        .not_to raise_error
      expect(status_of('recovered')).to eq('done')
    end
  end

  describe 'criterion 4 — a story with no gate notes closes normally' do
    it 'closes without --force' do
      create_story('clean')

      expect { capture_io { Tyrion::Commands.cmd_done(['clean', 'nothing to gate'], store) } }
        .not_to raise_error
      expect(status_of('clean')).to eq('done')
    end
  end
end

# --require-gates=<names> enforces gate coverage: each named gate must have at
# least one recorded gate note, else the close refuses (exit 1). This closes the
# honor-system hole where a lane records a differently-named gate (e.g. 'rspec'
# instead of 'pre-push') and the failing-gate/zero-gate checks both pass it.
RSpec.describe 'tyrion done --require-gates coverage' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
    allow(Tyrion::Repo).to receive(:clear_active_story)
  end

  def create_story(slug)
    store.create_story(epic_id: epic['id'], slug: slug, title: slug)
    store.find_story(epic['id'], slug)
  end

  def gate(slug, name, result)
    capture_io { Tyrion::Commands.cmd_gate([slug, name, result], store) }
  end

  def status_of(slug)
    store.find_story(epic['id'], slug)['status']
  end

  describe 'refuses with exit 1 and names each missing gate' do
    before do
      create_story('partial')
      gate('partial', 'pre-push', 'pass') # uat is missing
    end

    it 'exits 1 without closing the story' do
      expect { Tyrion::Commands.cmd_done(['partial', 'summary', '--require-gates=pre-push,uat'], store) }
        .to raise_error(SystemExit).and output(/Refusing to close partial/).to_stderr
      expect(status_of('partial')).not_to eq('done')
    end

    it 'names the missing gate on stderr and not the present one' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_done(['partial', 'summary', '--require-gates=pre-push,uat'], store) }
          .to raise_error(SystemExit)
      end
      expect(err).to match(/uat/)
      expect(err).to match(/no recorded note/)
    end

    it 'names every missing gate when several are absent' do
      create_story('bare')
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_done(['bare', 'summary', '--require-gates=pre-push,uat'], store) }
          .to raise_error(SystemExit)
      end
      expect(err).to match(/pre-push/)
      expect(err).to match(/uat/)
    end

    it 'counts a mis-named gate as missing (the honor-system hole)' do
      create_story('misnamed')
      gate('misnamed', 'rspec', 'pass') # recorded a gate, just not the required name
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_done(['misnamed', 'summary', '--require-gates=pre-push,uat'], store) }
          .to raise_error(SystemExit)
      end
      expect(err).to match(/pre-push/)
      expect(err).to match(/uat/)
    end
  end

  describe 'succeeds when every named gate has at least one recorded note' do
    it 'closes when both required gates are recorded (pass)' do
      create_story('covered')
      gate('covered', 'pre-push', 'pass')
      gate('covered', 'uat', 'pass')

      expect { capture_io { Tyrion::Commands.cmd_done(['covered', 'shipped', '--require-gates=pre-push,uat'], store) } }
        .not_to raise_error
      expect(status_of('covered')).to eq('done')
    end

    it 'coverage is presence, not result — a recorded gate whose latest run recovered still counts' do
      create_story('recovered')
      gate('recovered', 'pre-push', 'fail')
      gate('recovered', 'pre-push', 'pass')
      gate('recovered', 'uat', 'pass')

      expect { capture_io { Tyrion::Commands.cmd_done(['recovered', 'fixed', '--require-gates=pre-push,uat'], store) } }
        .not_to raise_error
      expect(status_of('recovered')).to eq('done')
    end
  end

  describe 'without the flag, behavior is exactly as before' do
    it 'closes a gate-less story with no coverage complaint' do
      create_story('legacy')
      out, = capture_io { Tyrion::Commands.cmd_done(['legacy', 'shipped'], store) }
      expect(status_of('legacy')).to eq('done')
      expect(out).not_to match(/require-gates/)
    end

    it 'still surfaces the pre-existing zero-gate warning' do
      create_story('legacy2')
      out, = capture_io { Tyrion::Commands.cmd_done(['legacy2', 'shipped'], store) }
      expect(out).to match(/No gates recorded/)
    end
  end
end

# tyrion done honesty warnings: warn (never block) when the working tree is dirty
# or the story has zero recorded gates, so an autonomous close can't silently drop
# uncommitted work or leave no evidence trail (dogfood 2026-07-10 findings).
RSpec.describe 'tyrion done close warnings' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  before do
    allow(Tyrion::Commands).to receive(:current_lane_token).and_return(nil)
    allow(Tyrion::Repo).to receive(:clear_active_story)
    # Commit capture shells out to git; keep it deterministic and off the real repo.
    allow(Tyrion::Repo).to receive(:commits_since).and_return([])
  end

  def create_story(slug)
    store.create_story(epic_id: epic['id'], slug: slug, title: slug)
    store.find_story(epic['id'], slug)
  end

  def gate(slug, name, result)
    capture_io { Tyrion::Commands.cmd_gate([slug, name, result], store) }
  end

  def status_of(slug)
    store.find_story(epic['id'], slug)['status']
  end

  describe 'criterion 1 — dirty working tree warns but still closes' do
    # dirty_count is stubbed to 0 by tyrion_worktree's REPO_DEFAULTS — override it here.
    let(:ctx) { tyrion_worktree(epic_slug: 'my-epic', dirty_count: 3) }

    it 'closes the story and warns that uncommitted work will be missing from the commit record' do
      create_story('dirty')
      out, = capture_io { Tyrion::Commands.cmd_done(['dirty', 'shipped'], store) }
      expect(status_of('dirty')).to eq('done')
      expect(out).to match(/uncommitted work.*missing from the commit record/i)
    end
  end

  describe 'criterion 2 — zero gate notes warns and names the gate command' do
    # tyrion_worktree defaults dirty_count to 0 — clean tree isolates the gate warning.
    it 'prints a warning naming tyrion gate <slug> <name> pass|fail' do
      create_story('ungated')
      out, = capture_io { Tyrion::Commands.cmd_done(['ungated', 'shipped'], store) }
      expect(out).to match(/tyrion gate ungated <name> pass\|fail/)
    end

    it 'still counts as zero gates when only an auto-captured commit note exists' do
      create_story('ungated2')
      # A commit note is a kind='commit' note, not a gate — it must not suppress the warning.
      allow(Tyrion::Repo).to receive(:commits_since).and_return(['abc123 did a thing'])
      out, = capture_io { Tyrion::Commands.cmd_done(['ungated2', 'shipped'], store) }
      expect(out).to match(/No gates recorded/)
    end
  end

  describe 'criterion 3 — clean tree with a gate note prints neither warning' do
    # tyrion_worktree defaults dirty_count to 0 — a clean tree plus a gate note.
    it 'prints neither the dirty-tree nor the zero-gate warning' do
      create_story('pristine')
      gate('pristine', 'pre-push', 'pass')
      out, = capture_io { Tyrion::Commands.cmd_done(['pristine', 'shipped'], store) }
      expect(status_of('pristine')).to eq('done')
      expect(out).not_to match(/uncommitted work/i)
      expect(out).not_to match(/No gates recorded/)
    end
  end
end
