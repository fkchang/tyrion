# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion lesson / lessons' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }

  describe 'tyrion lesson add' do
    it 'creates an active lesson scoped to the active project and epic, and prints confirmation' do
      expect {
        Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'text'], store)
      }.to output(/✓ Lesson lesson-\d+ added \[uat\]/).to_stdout

      lessons = store.list_lessons(project_id: ctx.project['id'])
      expect(lessons.length).to eq 1
      expect(lessons.first['trigger']).to eq 'uat'
      expect(lessons.first['text']).to eq 'text'
      expect(lessons.first['epic_id']).to eq ctx.epic['id']
      expect(lessons.first['status']).to eq 'active'
    end

    it 'creates a project-wide lesson (epic_id nil) when there is no active epic' do
      store # force ctx evaluation (and its Repo stubs) before overriding active_epic
      stub_repo(active_epic: nil)

      Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'project-wide text'], store)

      lessons = store.list_lessons(project_id: ctx.project['id'])
      expect(lessons.first['epic_id']).to be_nil
    end

    it 'dies when --at is missing' do
      expect {
        Tyrion::Commands.cmd_lesson(['add', 'text'], store)
      }.to raise_error(SystemExit).and output(/Missing required --at/).to_stderr
    end

    it 'joins unquoted multi-word text into a single lesson body (mirrors tyrion note)' do
      Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'do', 'not', 'offer', 'rspec'], store)

      lessons = store.list_lessons(project_id: ctx.project['id'])
      expect(lessons.first['text']).to eq 'do not offer rspec'
    end
  end

  describe 'tyrion lessons (no flags)' do
    it 'lists all active lessons for the project, grouped/labeled by trigger' do
      Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'first lesson'], store)
      Tyrion::Commands.cmd_lesson(['add', '--at', 'pre-push', 'second lesson'], store)

      out, = capture_io { Tyrion::Commands.cmd_lesson(['list'], store) }
      expect(out).to match(/\[uat\]/)
      expect(out).to match(/\[pre-push\]/)
      expect(out).to include('first lesson')
      expect(out).to include('second lesson')
    end

    it 'prints a (no lessons) message for a project with none' do
      out, = capture_io { Tyrion::Commands.cmd_lesson(['list'], store) }
      expect(out).to eq "(no lessons)\n"
    end
  end

  describe 'tyrion lessons --verbose' do
    it 'shows a global scope label, source, and age alongside the lesson text' do
      store # force ctx evaluation before overriding active_epic
      stub_repo(active_epic: nil)
      Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'global lesson'], store)
      lesson_id = store.list_lessons(project_id: ctx.project['id']).first['id']
      store.promote_lesson(lesson_id) # project-wide (epic_id already nil) -> global

      out, = capture_io { Tyrion::Commands.cmd_lesson(['list', '--verbose'], store) }
      expect(out).to match(/#{lesson_id}\s+global\s+manual\s+(just now|\S+ ago)/)
      expect(out).to include('global lesson')
    end

    it "shows the epic name as the scope label for an epic-scoped lesson" do
      Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'epic lesson'], store)
      lesson_id = store.list_lessons(project_id: ctx.project['id']).first['id']

      out, = capture_io { Tyrion::Commands.cmd_lesson(['list', '--verbose'], store) }
      expect(out).to match(/#{lesson_id}\s+#{ctx.epic['name']}\s+manual\s+(just now|\S+ ago)/)
    end

    it 'shows project-wide for a project-scoped (epic_id nil) lesson' do
      store # force ctx evaluation before overriding active_epic
      stub_repo(active_epic: nil)
      Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'project lesson'], store)
      lesson_id = store.list_lessons(project_id: ctx.project['id']).first['id']

      out, = capture_io { Tyrion::Commands.cmd_lesson(['list', '--verbose'], store) }
      expect(out).to match(/#{lesson_id}\s+project-wide\s+manual\s+(just now|\S+ ago)/)
    end

    it 'leaves plain tyrion lesson list byte-identical to the non-verbose format' do
      Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'first lesson'], store)

      out, = capture_io { Tyrion::Commands.cmd_lesson(['list'], store) }
      expect(out).to eq "[uat]\n  lesson-001  first lesson\n"
    end
  end

  describe 'tyrion lesson (no subcommand)' do
    it 'dies with usage instead of an unknown-subcommand error' do
      expect {
        Tyrion::Commands.cmd_lesson([], store)
      }.to raise_error(SystemExit).and output(/Usage: tyrion lesson add/).to_stderr
    end
  end

  describe 'tyrion lessons --at <trigger>' do
    it 'prints only matching lessons, one per line, with no extra header or count' do
      Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'uat lesson one'], store)
      Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'uat lesson two'], store)
      Tyrion::Commands.cmd_lesson(['add', '--at', 'pre-push', 'other lesson'], store)

      out, = capture_io { Tyrion::Commands.cmd_lesson(['list', '--at', 'uat'], store) }
      expect(out).to eq "uat lesson one\nuat lesson two\n"
    end

    it 'prints absolutely nothing when no lessons match the trigger' do
      Tyrion::Commands.cmd_lesson(['add', '--at', 'pre-push', 'other lesson'], store)

      out, = capture_io { Tyrion::Commands.cmd_lesson(['list', '--at', 'uat'], store) }
      expect(out).to eq ''
    end
  end

  describe 'tyrion lesson retire' do
    it "flips the lesson's status to retired and prints confirmation" do
      out, = capture_io { Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'text'], store) }
      lesson_id = out[/Lesson (lesson-\d+) added/, 1]

      expect {
        Tyrion::Commands.cmd_lesson(['retire', lesson_id], store)
      }.to output(/✓ Lesson #{lesson_id} retired/).to_stdout

      lessons = store.list_lessons(project_id: ctx.project['id'], status: 'retired')
      expect(lessons.map { |l| l['id'] }).to include(lesson_id)
    end

    it 'dies with a clean error message when the lesson id is unknown' do
      expect {
        Tyrion::Commands.cmd_lesson(['retire', 'lesson-999'], store)
      }.to raise_error(SystemExit).and output(/Lesson not found: lesson-999/).to_stderr
    end
  end

  describe 'tyrion lesson promote' do
    def add_epic_scoped_lesson(store)
      out, = capture_io { Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'text'], store) }
      out[/Lesson (lesson-\d+) added/, 1]
    end

    it 'promotes an epic-scoped lesson to project-wide, then to global, one step at a time' do
      lesson_id = add_epic_scoped_lesson(store)

      expect {
        Tyrion::Commands.cmd_lesson(['promote', lesson_id], store)
      }.to output(/✓ Lesson #{lesson_id} promoted to project-wide/).to_stdout

      lesson = store.find_lesson(lesson_id)
      expect(lesson['epic_id']).to be_nil
      expect(lesson['project_id']).to eq ctx.project['id']

      expect {
        Tyrion::Commands.cmd_lesson(['promote', lesson_id], store)
      }.to output(/✓ Lesson #{lesson_id} promoted to global/).to_stdout

      lesson = store.find_lesson(lesson_id)
      expect(lesson['project_id']).to be_nil
    end

    it 'dies when promoting an already-global lesson' do
      lesson_id = add_epic_scoped_lesson(store)
      Tyrion::Commands.cmd_lesson(['promote', lesson_id], store) # -> project-wide
      Tyrion::Commands.cmd_lesson(['promote', lesson_id], store) # -> global

      expect {
        Tyrion::Commands.cmd_lesson(['promote', lesson_id], store)
      }.to raise_error(SystemExit).and output(/already global/).to_stderr
    end

    it 'dies with a clean error message when the lesson id is unknown' do
      expect {
        Tyrion::Commands.cmd_lesson(['promote', 'lesson-999'], store)
      }.to raise_error(SystemExit).and output(/Lesson not found: lesson-999/).to_stderr
    end

    it '--to project jumps an epic-scoped lesson straight to project-wide in one call' do
      lesson_id = add_epic_scoped_lesson(store)

      Tyrion::Commands.cmd_lesson(['promote', lesson_id, '--to', 'project'], store)

      lesson = store.find_lesson(lesson_id)
      expect(lesson['epic_id']).to be_nil
      expect(lesson['project_id']).to eq ctx.project['id']
    end

    it '--to global jumps an epic-scoped lesson straight to global in one call' do
      lesson_id = add_epic_scoped_lesson(store)

      Tyrion::Commands.cmd_lesson(['promote', lesson_id, '--to', 'global'], store)

      lesson = store.find_lesson(lesson_id)
      expect(lesson['project_id']).to be_nil
    end

    it 'dies without mutating when --to epic targets a scope at or below an already project-wide lesson' do
      lesson_id = add_epic_scoped_lesson(store)
      Tyrion::Commands.cmd_lesson(['promote', lesson_id, '--to', 'project'], store)

      expect {
        Tyrion::Commands.cmd_lesson(['promote', lesson_id, '--to', 'epic'], store)
      }.to raise_error(SystemExit).and output(/already at or beyond epic scope/).to_stderr

      lesson = store.find_lesson(lesson_id)
      expect(lesson['project_id']).to eq ctx.project['id']
      expect(lesson['epic_id']).to be_nil
    end

    it 'dies without mutating on an unknown --to level' do
      lesson_id = add_epic_scoped_lesson(store)

      expect {
        Tyrion::Commands.cmd_lesson(['promote', lesson_id, '--to', 'bogus'], store)
      }.to raise_error(SystemExit).and output(/Unknown --to level: bogus/).to_stderr

      lesson = store.find_lesson(lesson_id)
      expect(lesson['epic_id']).to eq ctx.epic['id']
    end
  end

  describe 'tyrion lesson demote' do
    def add_epic_scoped_lesson(store)
      out, = capture_io { Tyrion::Commands.cmd_lesson(['add', '--at', 'uat', 'text'], store) }
      out[/Lesson (lesson-\d+) added/, 1]
    end

    it 'promotes an epic-scoped lesson to project-wide, then demotes it back to its original epic scope' do
      lesson_id = add_epic_scoped_lesson(store)
      Tyrion::Commands.cmd_lesson(['promote', lesson_id], store) # -> project-wide

      expect {
        Tyrion::Commands.cmd_lesson(['demote', lesson_id], store)
      }.to output(/✓ Lesson #{lesson_id} demoted to/).to_stdout

      lesson = store.find_lesson(lesson_id)
      expect(lesson['epic_id']).to eq ctx.epic['id']
      expect(lesson['project_id']).to eq ctx.project['id']
    end

    it 'dies with the "already at its original scope" message when demoting a never-promoted lesson' do
      lesson_id = add_epic_scoped_lesson(store)

      expect {
        Tyrion::Commands.cmd_lesson(['demote', lesson_id], store)
      }.to raise_error(SystemExit).and output(/already at its original scope/).to_stderr
    end

    it 'dies with a clean error message when the lesson id is unknown' do
      expect {
        Tyrion::Commands.cmd_lesson(['demote', 'lesson-999'], store)
      }.to raise_error(SystemExit).and output(/Lesson not found: lesson-999/).to_stderr
    end
  end
end
