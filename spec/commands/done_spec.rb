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
