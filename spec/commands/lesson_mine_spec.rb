# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'

RSpec.describe 'tyrion lesson mine' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:jsonl_dir) { Dir.mktmpdir('tyrion-lesson-mine-') }

  after { FileUtils.rm_rf(jsonl_dir) }

  def write_session(filename, lines)
    File.write(File.join(jsonl_dir, filename), lines.map(&:to_json).join("\n") + "\n")
  end

  def user_line(text)
    { type: 'user', message: { role: 'user', content: text } }
  end

  def assistant_line(text)
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: text }] } }
  end

  # Real Claude Code transcripts deliver user turns as content-block arrays too,
  # not just plain strings — exercise that shape, not only assistant_line's.
  def user_block_line(text)
    { type: 'user', message: { role: 'user', content: [{ type: 'text', text: text }] } }
  end

  describe Tyrion::LessonMiner do
    describe '.scan' do
      it 'finds a correction-signal match and proposes a candidate with a trigger' do
        write_session('session1.jsonl', [
          user_line("don't do that, run the import command instead")
        ])

        groups = described_class.scan(jsonl_dir)
        all_candidates = groups.values.flatten

        expect(all_candidates.length).to eq(1)
        expect(all_candidates.first[:text]).to include("don't do that")
        expect(all_candidates.first[:trigger]).to eq('import-existing')
      end

      it 'maps uat/rspec wording to the uat trigger' do
        write_session('session1.jsonl', [user_line("no, that's wrong — the rspec suite already covers this")])
        groups = described_class.scan(jsonl_dir)
        expect(groups.keys).to eq(['uat'])
      end

      it 'maps pre-push/stop wording to the pre-push-pass trigger' do
        write_session('session1.jsonl', [user_line('no, stop — wait for pre-push to finish first')])
        groups = described_class.scan(jsonl_dir)
        expect(groups.keys).to eq(['pre-push-pass'])
      end

      it 'maps import wording to the import-existing trigger' do
        write_session('session1.jsonl', [user_line("don't forget to import the existing feature file")])
        groups = described_class.scan(jsonl_dir)
        expect(groups.keys).to eq(['import-existing'])
      end

      it 'falls back to the start trigger for unrelated wording' do
        write_session('session1.jsonl', [user_line("don't rename that variable, I said leave it")])
        groups = described_class.scan(jsonl_dir)
        expect(groups.keys).to eq(['start'])
      end

      it 'skips malformed/non-JSON lines without crashing' do
        File.write(File.join(jsonl_dir, 'bad.jsonl'), "not json at all\n{also not json\n")
        expect { described_class.scan(jsonl_dir) }.not_to raise_error
        expect(described_class.scan(jsonl_dir)).to eq({})
      end

      it 'deduplicates the same correction text appearing in two different session files' do
        write_session('session1.jsonl', [user_line("don't do that again, import the file")])
        write_session('session2.jsonl', [user_line("don't do that again, import the file")])

        groups = described_class.scan(jsonl_dir)
        all_candidates = groups.values.flatten

        expect(all_candidates.length).to eq(1)
      end

      it 'captures assistant self-correction signals too' do
        write_session('session1.jsonl', [
          assistant_line("You're right — I deviated from my own runbook and should have run it as written.")
        ])
        groups = described_class.scan(jsonl_dir)
        all_candidates = groups.values.flatten

        expect(all_candidates.length).to eq(1)
        expect(all_candidates.first[:role]).to eq('assistant')
      end

      it 'extracts text from user messages delivered as content-block arrays' do
        write_session('session1.jsonl', [
          user_block_line("don't forget to import the existing feature file")
        ])
        groups = described_class.scan(jsonl_dir)
        all_candidates = groups.values.flatten

        expect(all_candidates.length).to eq(1)
        expect(all_candidates.first[:trigger]).to eq('import-existing')
      end

      it 'truncates candidate text to MAX_TEXT_LENGTH' do
        long_text = "don't do that again — #{'x' * 400}"
        write_session('session1.jsonl', [user_line(long_text)])

        candidate = described_class.scan(jsonl_dir).values.flatten.first

        expect(candidate[:text].length).to eq(described_class::MAX_TEXT_LENGTH)
        expect(long_text).to start_with(candidate[:text])
      end
    end
  end

  describe 'Commands.cmd_lesson_mine' do
    def run_mine(answers)
      input  = StringIO.new(Array(answers).join("\n") + "\n")
      output = StringIO.new
      Tyrion::Commands.cmd_lesson_mine(['--dir', jsonl_dir], store, input: input, output: output)
      output.string
    end

    it 'persists an approved candidate via store.create_lesson when the user answers y' do
      write_session('session1.jsonl', [user_line("don't forget to import the existing feature file")])

      out = run_mine('y')

      lessons = store.list_lessons(project_id: ctx.project['id'])
      expect(lessons.length).to eq(1)
      expect(lessons.first['trigger']).to eq('import-existing')
      expect(lessons.first['source']).to eq('auto-extracted')
      expect(lessons.first['text']).to include("don't forget to import the existing feature file")
      expect(out).to match(/1 added/)
    end

    it 'writes nothing when the user answers n' do
      write_session('session1.jsonl', [user_line("don't forget to import the existing feature file")])

      run_mine('n')

      expect(store.list_lessons(project_id: ctx.project['id'])).to be_empty
    end

    it 'writes nothing when the user answers with anything other than y' do
      write_session('session1.jsonl', [user_line("don't forget to import the existing feature file")])

      run_mine('whatever')

      expect(store.list_lessons(project_id: ctx.project['id'])).to be_empty
    end

    it 'never auto-writes even when multiple candidates are found and all are skipped' do
      write_session('session1.jsonl', [
        user_line("don't forget to import the existing feature file"),
        user_line('no, that rspec suite already covers this'),
        user_line('no, stop and wait for pre-push')
      ])

      run_mine(%w[n n n])

      expect(store.list_lessons(project_id: ctx.project['id'])).to be_empty
    end
  end
end
