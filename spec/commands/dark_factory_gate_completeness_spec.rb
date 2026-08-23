# frozen_string_literal: true

require 'spec_helper'

# dark-factory-gate-completeness-guard: a dark_factory-mode epic's stories can
# never close without pre-push + uat gate coverage, even with no
# --require-gates flag on the tyrion done invocation itself. tyrion audit is
# the read-only backstop for stories that closed before this guard existed.
RSpec.describe 'dark_factory gate-completeness enforcement' do
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

  def make_dark_factory!
    store.update_epic(epic['id'], 'mode' => 'dark_factory')
  end

  describe 'criterion 1 — dark_factory default applies with no --require-gates flag' do
    before { make_dark_factory! }

    it 'refuses when pre-push is missing' do
      create_story('leaky')
      gate('leaky', 'uat', 'pass')

      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_done(['leaky', 'summary'], store) }.to raise_error(SystemExit)
      end
      expect(err).to match(/pre-push/)
      expect(status_of('leaky')).not_to eq('done')
    end

    it 'names the dark_factory mode and the shape-mode escape hatch in the refusal' do
      create_story('leaky3')

      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_done(['leaky3', 'summary'], store) }.to raise_error(SystemExit)
      end
      expect(err).to match(/dark_factory mode/)
      expect(err).to match(/tyrion epic mode my-epic shape/)
    end

    it 'refuses when uat is missing' do
      create_story('leaky2')
      gate('leaky2', 'pre-push', 'pass')

      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_done(['leaky2', 'summary'], store) }.to raise_error(SystemExit)
      end
      expect(err).to match(/uat/)
      expect(status_of('leaky2')).not_to eq('done')
    end

    it 'closes once both pre-push and uat are recorded' do
      create_story('covered')
      gate('covered', 'pre-push', 'pass')
      gate('covered', 'uat', 'pass')

      expect { capture_io { Tyrion::Commands.cmd_done(['covered', 'shipped'], store) } }.not_to raise_error
      expect(status_of('covered')).to eq('done')
    end
  end

  describe 'criterion 2 — an explicit --require-gates unions with, never replaces, the default pair' do
    before { make_dark_factory! }

    it 'still refuses over a missing default gate even when a different gate is required' do
      create_story('partial')
      gate('partial', 'uat', 'pass')
      gate('partial', 'code-review', 'pass') # named gate is covered; pre-push (default) is not

      _out, err = capture_io do
        expect do
          Tyrion::Commands.cmd_done(['partial', 'summary', '--require-gates=code-review'], store)
        end.to raise_error(SystemExit)
      end
      expect(err).to match(/pre-push/)
    end

    it 'closes only once the default pair AND the explicitly required gate are all recorded' do
      create_story('full')
      gate('full', 'pre-push', 'pass')
      gate('full', 'uat', 'pass')
      gate('full', 'code-review', 'pass')

      expect do
        capture_io { Tyrion::Commands.cmd_done(['full', 'shipped', '--require-gates=code-review'], store) }
      end.not_to raise_error
      expect(status_of('full')).to eq('done')
    end
  end

  describe 'criterion 3 — --force cannot bypass missing required-gate coverage' do
    before { make_dark_factory! }

    it 'still refuses with --force when pre-push/uat were never recorded' do
      create_story('forced')

      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_done(['forced', 'summary', '--force'], store) }.to raise_error(SystemExit)
      end
      expect(err).to match(/pre-push/)
      expect(err).to match(/uat/)
      expect(status_of('forced')).not_to eq('done')
    end

    it '--force still bypasses a genuinely failing gate result, unrelated to the coverage check' do
      create_story('fixed')
      gate('fixed', 'pre-push', 'fail')
      gate('fixed', 'uat', 'pass')

      expect do
        capture_io { Tyrion::Commands.cmd_done(['fixed', 'shipped anyway', '--force'], store) }
      end.not_to raise_error
      expect(status_of('fixed')).to eq('done')
    end
  end

  describe 'criterion 4 — a shape-mode (or NULL-mode) epic is byte-for-byte unaffected' do
    it 'closes a gate-less story with no complaint when mode is NULL (default)' do
      create_story('legacy')

      out, = capture_io { Tyrion::Commands.cmd_done(['legacy', 'shipped'], store) }
      expect(status_of('legacy')).to eq('done')
      expect(out).not_to match(/pre-push/)
      expect(out).not_to match(/uat/)
    end

    it 'closes a gate-less story with no complaint when mode is explicitly shape' do
      store.update_epic(epic['id'], 'mode' => 'shape')
      create_story('legacy2')

      out, = capture_io { Tyrion::Commands.cmd_done(['legacy2', 'shipped'], store) }
      expect(status_of('legacy2')).to eq('done')
      expect(out).not_to match(/pre-push/)
      expect(out).not_to match(/uat/)
    end
  end

  describe 'tyrion audit — backstop for gaps this guard cannot retroactively fix' do
    it 'prints a clean no-gaps line when nothing is flagged' do
      make_dark_factory!
      create_story('clean')
      gate('clean', 'pre-push', 'pass')
      gate('clean', 'uat', 'pass')
      capture_io { Tyrion::Commands.cmd_done(['clean', 'shipped'], store) }

      out, = capture_io { Tyrion::Commands.cmd_audit([], store) }
      expect(out).to match(/No gaps found/)
      expect(out).not_to match(/clean/)
    end

    it "flags a story closed under shape mode (uat present, pre-push absent) once the epic's mode later flips to dark_factory" do
      # Reconstructs the two known bug reports' shape: the story closed with
      # uat/merge-ready gates present but pre-push absent — this guard didn't
      # exist yet (epic was shape-mode at close time), so cmd_done's own
      # enforcement never ran. The mode is flipped to dark_factory afterward,
      # which is exactly what cmd_done's fix cannot retroactively catch.
      create_story('gap')
      gate('gap', 'uat', 'pass')
      capture_io { Tyrion::Commands.cmd_done(['gap', 'shipped under shape mode'], store) }
      expect(status_of('gap')).to eq('done')

      make_dark_factory!

      out, = capture_io { Tyrion::Commands.cmd_audit([], store) }
      expect(out).to match(/gap \(my-epic\): missing pre-push/)
    end

    it 'does not flag a done story in a shape-mode (or NULL-mode) epic' do
      create_story('untouched')
      capture_io { Tyrion::Commands.cmd_done(['untouched', 'shipped'], store) }

      out, = capture_io { Tyrion::Commands.cmd_audit([], store) }
      expect(out).to match(/No gaps found/)
    end

    it 'does not flag a pending or in_progress story, only done ones' do
      make_dark_factory!
      create_story('still-open') # left pending, never closed

      out, = capture_io { Tyrion::Commands.cmd_audit([], store) }
      expect(out).to match(/No gaps found/)
    end

    it '--epic naming a non-dark_factory epic says so plainly, instead of a misleading "no gaps"' do
      create_story('untouched')
      capture_io { Tyrion::Commands.cmd_done(['untouched', 'shipped'], store) }

      out, = capture_io { Tyrion::Commands.cmd_audit(['--epic', 'my-epic'], store) }
      expect(out).to match(/my-epic is not a dark_factory epic/)
      expect(out).not_to match(/No gaps found/)
    end

    it '--epic <slug> narrows the scan to one epic' do
      other_epic = store.create_epic(project_id: ctx.project['id'], slug: 'other-epic', name: 'Other Epic')
      store.update_epic(other_epic['id'], 'mode' => 'dark_factory')
      other_story = store.create_story(epic_id: other_epic['id'], slug: 'other-gap', title: 'other-gap')
      store.complete_story(other_story['id'], 'force closed', force: true)

      make_dark_factory!
      gap_story = create_story('gap')
      gate('gap', 'uat', 'pass')
      store.complete_story(gap_story['id'], 'force closed', force: true)

      out, = capture_io { Tyrion::Commands.cmd_audit(['--epic', 'other-epic'], store) }
      expect(out).to match(/other-gap \(other-epic\)/)
      expect(out).not_to match(/\bgap \(my-epic\)/)
    end

    it 'dies when --epic names an unknown slug' do
      expect { Tyrion::Commands.cmd_audit(['--epic', 'nope'], store) }
        .to raise_error(SystemExit).and output(/Epic not found: nope/).to_stderr
    end

    it 'dies on an unrecognized flag rather than silently ignoring it (e.g. the equals form)' do
      expect { Tyrion::Commands.cmd_audit(['--epic=my-epic'], store) }
        .to raise_error(SystemExit).and output(/Unknown flag --epic=my-epic/).to_stderr
    end
  end
end
