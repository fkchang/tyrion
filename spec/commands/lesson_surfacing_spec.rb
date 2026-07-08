# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'lesson surfacing in status and resume' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }

  context 'tyrion status' do
    it 'shows a LESSONS lane when an active project-wide lesson exists' do
      store.create_lesson(project_id: ctx.project['id'], trigger: 'uat', text: 'watch for flaky uploads')

      expect { Tyrion::Commands.cmd_status([], store) }
        .to output(/LESSONS/).to_stdout
    end

    it 'shows a LESSONS lane when an active lesson is scoped to the active epic' do
      store.create_lesson(project_id: ctx.project['id'], trigger: 'uat', text: 'epic-scoped lesson',
                           epic_id: ctx.epic['id'])

      expect { Tyrion::Commands.cmd_status([], store) }
        .to output(/LESSONS/).to_stdout
    end

    it 'does not show a LESSONS lane when no active lessons exist' do
      expect { Tyrion::Commands.cmd_status([], store) }
        .not_to output(/LESSONS/).to_stdout
    end

    it 'does not show a lesson scoped to a different epic' do
      other_epic = store.create_epic(project_id: ctx.project['id'], slug: 'other-epic', name: 'Other Epic')
      store.create_lesson(project_id: ctx.project['id'], trigger: 'uat', text: 'other epic lesson',
                           epic_id: other_epic['id'])

      expect { Tyrion::Commands.cmd_status([], store) }
        .not_to output(/LESSONS/).to_stdout
    end
  end

  context 'tyrion resume' do
    let(:story) do
      s = store.create_story(epic_id: ctx.epic['id'], slug: 'my-story', title: 'My Story', sequence: 1)
      store.start_story(s['id'])
      store.find_story(ctx.epic['id'], 'my-story')
    end

    before { story }

    it 'prints a Lessons section when an active project-wide lesson exists' do
      store.create_lesson(project_id: ctx.project['id'], trigger: 'uat', text: 'watch for flaky uploads')

      expect { Tyrion::Commands.cmd_resume(['my-story'], store) }
        .to output(/Lessons:/).to_stdout
    end

    it 'prints a Lessons section when an active epic-scoped lesson exists' do
      store.create_lesson(project_id: ctx.project['id'], trigger: 'uat', text: 'epic-scoped lesson',
                           epic_id: ctx.epic['id'])

      expect { Tyrion::Commands.cmd_resume(['my-story'], store) }
        .to output(/Lessons:/).to_stdout
    end

    it 'prints the lesson text and trigger, not just the section header' do
      store.create_lesson(project_id: ctx.project['id'], trigger: 'uat', text: 'watch for flaky uploads')

      expect { Tyrion::Commands.cmd_resume(['my-story'], store) }
        .to output(/\[uat\].*watch for flaky uploads/).to_stdout
    end

    it 'prints a Lessons section when a lesson is scoped to the resuming story' do
      store.create_lesson(project_id: ctx.project['id'], trigger: 'uat', text: 'story-scoped lesson',
                           epic_id: ctx.epic['id'], story_id: story['id'])

      expect { Tyrion::Commands.cmd_resume(['my-story'], store) }
        .to output(/story-scoped lesson/).to_stdout
    end

    it 'does not print a lesson scoped to a different story in the same epic' do
      other_story = store.create_story(epic_id: ctx.epic['id'], slug: 'other-story', title: 'Other Story',
                                        sequence: 2)
      store.create_lesson(project_id: ctx.project['id'], trigger: 'uat', text: 'other story lesson',
                           epic_id: ctx.epic['id'], story_id: other_story['id'])

      expect { Tyrion::Commands.cmd_resume(['my-story'], store) }
        .not_to output(/other story lesson/).to_stdout
    end

    it 'does not print a Lessons section when no active lessons apply' do
      other_epic = store.create_epic(project_id: ctx.project['id'], slug: 'other-epic', name: 'Other Epic')
      store.create_lesson(project_id: ctx.project['id'], trigger: 'uat', text: 'other epic lesson',
                           epic_id: other_epic['id'])

      expect { Tyrion::Commands.cmd_resume(['my-story'], store) }
        .not_to output(/Lessons:/).to_stdout
    end
  end
end
