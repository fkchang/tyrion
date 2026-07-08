# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'cmd_wave_next — tyrion wave next' do
  let(:ctx) do
    tyrion_worktree(
      project_slug: 'wnproj',
      epic_slug:    'wn-epic',
      git_branch:   'feature/wave-next'
    )
  end
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  def make_story(slug:, status: 'pending')
    store.create_story(epic_id: epic['id'], slug: slug, title: slug)
    s = store.find_story(epic['id'], slug)
    store.start_story(s['id'])            if status == 'in_progress'
    store.complete_story(s['id'], 'done') if status == 'done'
    s
  end

  def add_criterion(story, keyword:, text:)
    store.add_criteria(story['id'], [{ keyword: keyword, semantic_kind: keyword.downcase, text: text }])
  end

  def make_dep_story(slug:, depends_on:)
    store.create_story(epic_id: epic['id'], slug: slug, title: slug)
    s = store.find_story(epic['id'], slug)
    store.update_story_depends_on(s['id'], [depends_on])
    s
  end

  # ── criterion 3+4 — outputs newline-delimited slugs of first ready wave ──────────

  context 'criterion 3+4 — newline-delimited slugs of first dispatchable wave' do
    it 'emits each slug on its own line when all wave-1 stories are pending' do
      make_story(slug: 'alpha')
      make_story(slug: 'beta')
      out, = capture_io { Tyrion::Commands.cmd_wave_next([], store) }
      expect(out.split("\n")).to match_array(%w[alpha beta])
    end

    it 'skips wave 1 when all wave-1 stories are done and returns pending from wave 2' do
      make_story(slug: 'alpha', status: 'done')
      make_dep_story(slug: 'beta', depends_on: 'alpha')
      out, = capture_io { Tyrion::Commands.cmd_wave_next([], store) }
      expect(out.strip).to eq 'beta'
    end

    it 'returns only the pending stories from a partially-done wave (not skipping the wave)' do
      make_story(slug: 'alpha', status: 'done')
      make_story(slug: 'beta')  # same wave 1, no deps
      out, = capture_io { Tyrion::Commands.cmd_wave_next([], store) }
      expect(out.strip).to eq 'beta'
    end

    it 'returns pending wave-1 work alongside an in_progress story in the same wave' do
      make_story(slug: 'alpha', status: 'in_progress')
      make_story(slug: 'gamma')  # same wave 1, independent
      out, = capture_io { Tyrion::Commands.cmd_wave_next([], store) }
      expect(out.strip).to eq 'gamma'
    end

    it 'returns no pending stories when wave 1 has only an in_progress story and wave 2 depends on it' do
      make_story(slug: 'alpha', status: 'in_progress')
      make_dep_story(slug: 'beta', depends_on: 'alpha')
      expect { Tyrion::Commands.cmd_wave_next([], store) }
        .to output("(no pending stories)\n").to_stdout
    end
  end

  # ── criterion 5 — --with-pocket appends pocket briefing below each slug ──────────

  context 'criterion 5 — --with-pocket output' do
    it 'prints epic/story header and unchecked criteria below each slug' do
      story = make_story(slug: 'alpha')
      add_criterion(story, keyword: 'Then', text: 'it works')
      out, = capture_io { Tyrion::Commands.cmd_wave_next(['--with-pocket'], store) }
      expect(out).to include('alpha')
      expect(out).to match(/epic: wn-epic/)
      expect(out).to match(/story: alpha/)
      expect(out).to match(/\[\s*\] Then it works/)
    end

    it 'omits already-met criteria from the pocket briefing' do
      story = make_story(slug: 'alpha')
      add_criterion(story, keyword: 'Given', text: 'a user exists')
      add_criterion(story, keyword: 'Then', text: 'dashboard shown')
      given_position = 1  # "Given a user exists" was added first
      store.check_criterion(story['id'], given_position, 'user seeded')
      out, = capture_io { Tyrion::Commands.cmd_wave_next(['--with-pocket'], store) }
      expect(out).not_to include('a user exists')
      expect(out).to include('dashboard shown')
    end
  end

  # ── criterion 6 — no pending stories exits cleanly ───────────────────────────────

  context 'criterion 6 — no pending stories' do
    it 'prints "(no pending stories)" when no story is pending' do
      make_story(slug: 'alpha', status: 'done')
      expect { Tyrion::Commands.cmd_wave_next([], store) }
        .to output("(no pending stories)\n").to_stdout
    end

    it 'prints "(no pending stories)" when the epic has no stories at all' do
      expect { Tyrion::Commands.cmd_wave_next([], store) }
        .to output("(no pending stories)\n").to_stdout
    end
  end

  # ── dispatching via cmd_wave('next', ...) ────────────────────────────────────────

  context 'dispatch' do
    it 'cmd_wave routes "next" to cmd_wave_next' do
      make_story(slug: 'gamma')
      expect { Tyrion::Commands.cmd_wave(['next'], store) }
        .to output(/gamma/).to_stdout
    end

    it 'cmd_wave error message mentions "next"' do
      expect { Tyrion::Commands.cmd_wave(['unknown'], store) }
        .to raise_error(SystemExit)
        .and output(/wave next/i).to_stderr
    end
  end
end
