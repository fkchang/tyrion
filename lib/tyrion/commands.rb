# frozen_string_literal: true

require 'time'
require_relative 'importer'

module Tyrion
  module Commands
    STALE_HOURS = 4

    DISCOVERY_ALIASES = {
      'active'   => 'active_spike',
      'ready'    => 'findings_ready',
      'promoted' => 'promoted_to_story',
      'deferred' => 'deferred',
      'all'      => nil
    }.freeze

    def self.run(argv)
      args  = argv.dup
      store = Store.new
      cmd   = args.shift

      case cmd
      when 'init'         then cmd_init(args, store)
      when 'project'      then cmd_project(args, store)
      when 'epic'         then cmd_epic(args, store)
      when 'import'       then cmd_import(args, store)
      when 'status'       then cmd_status(args, store)
      when 'list'         then cmd_list(args, store)
      when 'show'         then cmd_show(args, store)
      when 'start'        then cmd_start(args, store)
      when 'block'        then cmd_block(args, store)
      when 'unblock'      then cmd_unblock(args, store)
      when 'claim-next'   then cmd_claim_next(args, store)
      when 'pocket'       then cmd_pocket(args, store)
      when 'mark'         then cmd_mark(args, store)
      when 'discover'     then cmd_discover(args, store)
      when 'discovery'    then cmd_discovery(args, store)
      when 'spike'        then cmd_spike(args, store)
      when 'resume'       then cmd_resume(args, store)
      when 'note'         then cmd_note(args, store)
      when 'context'      then cmd_context(args, store)
      when 'next'         then cmd_next(args, store)
      when 'criteria'     then cmd_criteria(args, store)
      when 'check'        then cmd_check(args, store)
      when 'uncheck'      then cmd_uncheck(args, store)
      when 'done'         then cmd_done(args, store)
      when 'unstart'      then cmd_unstart(args, store)
      when 'backfill'     then cmd_backfill(args, store)
      when nil, '--help', '-h', 'help' then usage
      else
        $stderr.puts "Unknown command: #{cmd}"
        usage
        exit 1
      end
    end

    # ── init ───────────────────────────────────────────────────────────────

    def self.cmd_init(args, store)
      root = Dir.pwd
      Repo.init_marker(root)

      unless Repo.gitignore_has_tyrion?(root)
        Repo.add_tyrion_to_gitignore(root)
        puts "Added .tyrion/ to .gitignore"
      end

      repo_id = Repo.identity(root)
      if repo_id
        existing = store.find_project_by_repo(repo_id)
        if existing
          puts "Tyrion worktree initialized."
          puts "Existing project: #{existing['name']} [#{existing['slug']}]"
          puts "Activate with: tyrion project activate #{existing['slug']}"
        else
          puts "Tyrion worktree initialized."
          puts "No project registered for this repo yet."
          puts "Create one: tyrion project new <slug> \"Project Name\""
          puts "Or shape one: /tyrion-shape"
        end
      else
        puts "Tyrion worktree initialized (not a git repo — no repo identity recorded)."
      end
    end

    # ── project ────────────────────────────────────────────────────────────

    def self.cmd_project(args, store)
      sub = args.shift
      case sub
      when 'list'        then cmd_project_list(args, store)
      when 'new'         then cmd_project_new(args, store)
      when 'show'        then cmd_project_show(args, store)
      when 'activate'    then cmd_project_activate(args, store)
      when 'sync'        then cmd_project_sync(args, store)
      when 'edit-about'  then cmd_project_edit_about(args, store)
      else
        $stderr.puts "Unknown project subcommand: #{sub}"
        $stderr.puts "Usage: tyrion project [list|new|show|activate|sync|edit-about]"
        exit 1
      end
    end

    def self.cmd_project_list(args, store)
      projects = store.list_projects
      if projects.empty?
        puts "No projects yet. Create one: tyrion project new <slug> \"Name\""
        return
      end
      projects.each do |p|
        active = (Repo.active_project == p['slug']) ? " #{Output.cyan('← active')}" : ''
        epics  = store.list_epics(p['id'])
        puts "#{Output.bold(p['slug'])}  #{p['name']}  [#{Output.dim(p['status'])}]#{active}"
        puts "  #{epics.length} epic(s)" unless epics.empty?
      end
    end

    def self.cmd_project_new(args, store)
      slug = args.shift
      name = args.join(' ')
      die "Usage: tyrion project new <slug> \"Project Name\"" if slug.nil? || name.empty?

      repo_id = Repo.identity
      project = store.create_project(slug: slug, name: name, repo_identity: repo_id)
      puts "Project created: #{project['name']} [#{project['slug']}]"
      puts "Activate with: tyrion project activate #{project['slug']}"
    end

    def self.cmd_project_show(args, store)
      slug = args.first || Repo.active_project
      die "No active project. Use: tyrion project activate <slug>" unless slug

      project = store.find_project_by_slug(slug)
      die "Project not found: #{slug}" unless project

      puts Output.bold("Project: #{project['name']} [#{project['slug']}]")
      puts "Status: #{Output.status_label(project['status'])}"
      puts "Repo:   #{project['primary_repo_identity'] || '(none)'}"
      puts

      if project['about_md'] && !project['about_md'].empty?
        puts Output.bold("About:")
        puts project['about_md']
        puts
      end

      epics = store.list_epics(project['id'])
      if epics.any?
        puts Output.bold("Epics (#{epics.length}):")
        epics.each do |e|
          stories = store.stories_for_epic(e['id'])
          done    = stories.count { |s| s['status'] == 'done' }
          puts "  #{e['slug']}  #{e['name']}  #{done}/#{stories.length} done  [#{e['status']}]"
        end
      else
        puts "No epics yet. Import one: tyrion import features/<epic>.feature"
      end
    end

    def self.cmd_project_activate(args, store)
      slug = args.shift
      die "Usage: tyrion project activate <slug>" unless slug

      project = store.find_project_by_slug(slug)
      die "Project not found: #{slug}" unless project

      Repo.write_active_project(slug)
      puts "Active project set to: #{project['name']} [#{slug}]"
    end

    def self.cmd_project_sync(args, store)
      slug   = Repo.active_project
      die "No active project. Use: tyrion project activate <slug>" unless slug
      project = store.find_project_by_slug(slug)
      die "Project not found: #{slug}" unless project

      accept_disk = args.include?('--accept-disk')
      accept_db   = args.include?('--accept-db')

      path        = Repo.about_md_path(slug)
      unless File.exist?(path)
        puts "No on-disk ABOUT.md found at #{path}."
        if project['about_md']
          Repo.write_about_md(slug, project['about_md'])
          puts "Written from DB to disk."
        end
        return
      end

      disk_content = File.read(path)
      db_content   = project['about_md'] || ''

      if disk_content == db_content
        puts "ABOUT.md in sync."
        return
      end

      if accept_disk
        store.update_project(project['id'], 'about_md' => disk_content)
        puts "DB updated from disk."
      elsif accept_db
        Repo.write_about_md(slug, db_content)
        puts "Disk updated from DB."
      else
        puts "ABOUT.md differs between disk and DB."
        puts "Disk path: #{path}"
        puts "Resolve with:"
        puts "  tyrion project sync --accept-disk   (disk wins)"
        puts "  tyrion project sync --accept-db     (DB wins)"
      end
    end

    def self.cmd_project_edit_about(args, store)
      slug    = Repo.active_project
      die "No active project. Use: tyrion project activate <slug>" unless slug
      project = store.find_project_by_slug(slug)
      die "Project not found: #{slug}" unless project

      path = Repo.about_md_path(slug)
      Repo.write_about_md(slug, project['about_md'] || "# #{project['name']}\n\n") unless File.exist?(path)

      editor = ENV['EDITOR'] || 'vi'
      system("#{editor} #{path.shellescape}")

      content = File.read(path)
      store.update_project(project['id'], 'about_md' => content)
      puts "ABOUT.md saved and synced to DB."
    end

    # ── epic ───────────────────────────────────────────────────────────────

    def self.cmd_epic(args, store)
      sub = args.shift
      case sub
      when 'list'     then cmd_epic_list(args, store)
      when 'show'     then cmd_epic_show(args, store)
      when 'activate' then cmd_epic_activate(args, store)
      when 'pause'    then cmd_epic_pause(args, store)
      else
        $stderr.puts "Unknown epic subcommand: #{sub}"
        $stderr.puts "Usage: tyrion epic [list|show|activate|pause]"
        exit 1
      end
    end

    def self.cmd_epic_list(args, store)
      project, _epic = resolve_project_epic(store, require_epic: false)
      epics = store.list_epics(project['id'])
      if epics.empty?
        puts "No epics for #{project['slug']}. Import one: tyrion import features/<epic>.feature"
        return
      end
      active_slug = Repo.active_epic
      epics.each do |e|
        stories = store.stories_for_epic(e['id'])
        done    = stories.count { |s| s['status'] == 'done' }
        active  = e['slug'] == active_slug ? " #{Output.cyan('← active')}" : ''
        puts "#{e['slug']}  #{e['name']}  #{done}/#{stories.length}  [#{e['status']}]#{active}"
      end
    end

    def self.cmd_epic_show(args, store)
      slug = args.first
      project, epic = if slug
        p = resolve_project(store)
        e = store.find_epic(p['id'], slug)
        die "Epic not found: #{slug}" unless e
        [p, e]
      else
        resolve_project_epic(store)
      end

      puts Output.bold("Epic: #{epic['name']} [#{epic['slug']}]")
      puts "Status: #{epic['status']}  Project: #{project['slug']}"
      puts

      if epic['intent'] && !epic['intent'].empty?
        puts Output.bold("Intent:")
        puts epic['intent']
        puts
      end

      if epic['context_md'] && !epic['context_md'].empty?
        puts Output.bold("Context:")
        puts epic['context_md'][0, 800]
        puts "(truncated — #{epic['context_md'].length} chars total)" if epic['context_md'].length > 800
        puts
      end

      stories = store.stories_for_epic(epic['id'])
      puts Output.bold("Stories (#{stories.length}):")
      stories.each do |s|
        icon = Output.story_icon(s['status'])
        puts "  #{icon} #{s['slug'].ljust(12)} #{s['title']}"
      end
    end

    def self.cmd_epic_activate(args, store)
      slug = args.shift
      die "Usage: tyrion epic activate <slug>" unless slug
      project = resolve_project(store)
      epic    = store.find_epic(project['id'], slug)
      die "Epic not found: #{slug}" unless epic

      Repo.write_active_epic(slug)
      puts "Active epic set to: #{epic['name']} [#{slug}]"
    end

    def self.cmd_epic_pause(args, store)
      slug = args.shift || Repo.active_epic
      die "Usage: tyrion epic pause <slug>" unless slug
      project = resolve_project(store)
      epic    = store.find_epic(project['id'], slug)
      die "Epic not found: #{slug}" unless epic

      store.update_epic(epic['id'], 'status' => 'paused')
      puts "Epic paused: #{epic['name']} [#{slug}]"
    end

    # ── import (stub — full implementation in phase 3) ────────────────────

    def self.cmd_import(args, store)
      die "Usage: tyrion import <file.feature> [--confirm-abandon]" if args.empty?
      Importer.run(args, store)
    end

    # ── status ─────────────────────────────────────────────────────────────

    def self.cmd_status(args, store)
      project_slug = Repo.active_project
      epic_slug    = Repo.active_epic

      unless project_slug
        puts "No active project. Run:"
        puts "  tyrion init"
        puts "  tyrion project new <slug> \"Name\""
        puts "  tyrion project activate <slug>"
        return
      end

      project = store.find_project_by_slug(project_slug)
      die "Active project '#{project_slug}' not found in DB. Run: tyrion init" unless project

      puts "#{Output.bold('Project:')} #{project['name']} [#{Output.dim(project_slug)}]"

      unless epic_slug
        epics = store.list_epics(project['id'])
        puts "No active epic."
        if epics.any?
          puts "Available epics:"
          epics.each { |e| puts "  #{e['slug']}  #{e['name']}" }
          puts "Activate with: tyrion epic activate <slug>"
        else
          puts "Import one: tyrion import features/<epic>.feature"
        end
        return
      end

      epic = store.find_epic(project['id'], epic_slug)
      unless epic
        puts "Active epic '#{epic_slug}' not found. Run: tyrion epic activate <slug>"
        return
      end

      puts "#{Output.bold('Epic:')}    #{epic['name']} [#{Output.dim(epic_slug)}]"

      if epic['intent'] && !epic['intent'].empty?
        puts "           #{Output.dim(epic['intent'][0, 80])}#{'…' if epic['intent'].length > 80}"
      end

      puts

      stories = store.stories_for_epic(epic['id'])
      done_n  = stories.count { |s| s['status'] == 'done' }
      ip_n    = stories.count { |s| s['status'] == 'in_progress' }
      pend_n  = stories.count { |s| s['status'] == 'pending' }
      blk_n   = stories.count { |s| s['status'] == 'blocked' }

      counts = []
      counts << Output.green("#{done_n} done")
      counts << Output.yellow("#{ip_n} in_progress") if ip_n > 0
      counts << "#{pend_n} pending"
      counts << Output.red("#{blk_n} blocked") if blk_n > 0
      puts "  #{counts.join(' · ')}"
      puts

      slug_w = stories.map { |s| s['slug'].length }.max.to_i
      stories.each do |s|
        icon   = Output.story_icon(s['status'])
        slug   = s['slug'].ljust(slug_w)
        title  = s['title'][0, 50]

        stale_flag = ''
        if s['status'] == 'in_progress' && Output.stale?(s['last_note_at'])
          stale_flag = " #{Output.red(Output.stale_label(s['last_note_at']))}"
        end

        puts "  #{icon} #{slug}  #{title}#{stale_flag}"

        if s['status'] == 'in_progress' && s['next_action'] && !s['next_action'].empty?
          puts "         #{Output.dim('Next →')} #{s['next_action'][0, 70]}"
        end
      end

      puts

      # ── blocked lane ─────────────────────────────────────────────────────
      blocked = stories.select { |s| s['status'] == 'blocked' }
      unless blocked.empty?
        puts "  #{Output.red('BLOCKED')}"
        blocked.each do |s|
          slug_col  = s['slug'].ljust(slug_w)
          reason    = (s['blocked_on'] || '(no reason recorded)')[0, 60]
          disc_annot = ''
          if (disc_id = s['blocked_on_discovery'])
            disc = store.find_discovery(disc_id)
            if disc && %w[promoted_to_story deferred invalidated].include?(disc['status'])
              disc_annot = " #{Output.cyan("[#{disc_id} resolved → unblock?]")}"
            else
              disc_annot = " [#{disc_id}]"
            end
          end
          puts "  #{Output.red('⊘')} #{slug_col}  #{reason}#{disc_annot}"
          puts "    #{Output.dim('→ unblock:')} tyrion unblock #{s['slug']}"
        end
        puts
      end

      # ── followups ────────────────────────────────────────────────────────
      followups = store.done_stories_with_followup_notes(project['id'])
      unless followups.empty?
        fw = followups.map { |s| s['slug'].length }.max.to_i
        puts "  NEEDS FOLLOW-UP"
        followups.each do |s|
          body = (s['followup_body'] || '(see story notes)')[0, 72]
          puts "  ★ #{s['slug'].ljust(fw)}  #{body}"
        end
        puts
      end

      # ── discoveries ──────────────────────────────────────────────────────
      active_spikes    = store.list_discoveries(project_id: project['id'], status: 'active_spike')
      findings_ready   = store.list_discoveries(project_id: project['id'], status: 'findings_ready')
      marks            = store.list_discoveries(project_id: project['id'], status: 'mark')

      unless active_spikes.empty? && findings_ready.empty? && marks.empty?
        puts "  DISCOVERIES"
        active_spikes.each do |d|
          puts "  ● #{d['id']}  #{d['question']}"
        end
        findings_ready.each do |d|
          puts "  → #{d['id']}  #{d['question']}  (tyrion spike promote #{d['id']})"
        end
        puts "  #{marks.size} unformalized mark(s)" if marks.any?
        puts
      end

      root   = Repo.worktree_root
      branch = Repo.git_branch
      dirty  = Repo.dirty_count
      dirty_s = dirty > 0 ? Output.yellow("#{dirty} dirty") : Output.green("clean")
      puts "  #{Output.dim('git:')} #{branch}  #{Output.dim(root.sub(Dir.home, '~'))}  #{dirty_s}"
    end

    # ── list ───────────────────────────────────────────────────────────────

    def self.cmd_list(args, store)
      status_filter = args.include?('--status') ? args[args.index('--status') + 1] : nil
      _project, epic = resolve_project_epic(store)
      stories = store.stories_for_epic(epic['id'])
      stories = stories.select { |s| s['status'] == status_filter } if status_filter
      stories.each do |s|
        puts "#{Output.story_icon(s['status'])} #{s['slug'].ljust(14)} #{s['title']}"
      end
    end

    # ── show ───────────────────────────────────────────────────────────────

    def self.cmd_show(args, store)
      slug = args.shift
      die "Usage: tyrion show <slug>" unless slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      stale_flag = if story['status'] == 'in_progress' && Output.stale?(story['last_note_at'])
        " #{Output.red(Output.stale_label(story['last_note_at']))}"
      else
        ''
      end

      puts "#{Output.bold(story['slug'])} — #{story['title']}"
      puts
      puts "Status:  #{Output.status_label(story['status'])}#{stale_flag}"
      puts "Started: #{story['started_at'] || '—'}"
      puts "Done:    #{story['completed_at'] || '—'}" if story['completed_at']
      puts

      if story['intent'] && !story['intent'].empty?
        puts Output.bold("Intent:") + " #{story['intent']}"
        puts
      end

      if story['current_context'] && !story['current_context'].empty?
        puts Output.bold("Current context:")
        story['current_context'].scan(/.{1,80}(?:\s|$)/).each { |l| puts "  #{l.rstrip}" }
        puts
      end

      if story['next_action'] && !story['next_action'].empty?
        puts Output.bold("Next action:") + " #{story['next_action']}"
        puts
      end

      criteria = store.criteria_for_story(story['id'])
      if criteria.any?
        puts Output.bold("Criteria (#{criteria.count { |c| c['status'] == 'met' }}/#{criteria.length} met):")
        criteria.each do |c|
          icon = Output.criterion_icon(c['status'])
          puts "  #{icon} #{c['position']}. #{c['keyword'].ljust(5)} #{c['text']}"
          puts "            #{Output.dim('evidence: ' + c['evidence'])}" if c['evidence']
        end
        puts
      end

      notes = store.notes_for_story(story['id'], limit: 10)
      if notes.any?
        puts Output.bold("Recent notes (#{notes.length}):")
        notes.each do |n|
          ts   = n['created_at'][11, 5]
          kind = n['kind'].ljust(10)
          body = n['body'][0, 70]
          puts "  #{Output.dim(ts)} [#{Output.cyan(kind)}] #{body}"
        end
      end
    end

    # ── start ──────────────────────────────────────────────────────────────

    def self.cmd_start(args, store)
      slug = args.shift
      die "Usage: tyrion start <slug>" unless slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug} in epic #{epic['slug']}" unless story

      if story['status'] == 'blocked'
        reason = story['blocked_on'] || 'unknown reason'
        die "#{slug} is blocked: #{reason}\nRun: tyrion unblock #{slug}"
      end

      story = store.start_story(story['id'])
      puts "Started: #{story['slug']} — #{story['title']}"
      puts "Status: #{Output.yellow('in_progress')}"
    rescue RuntimeError => e
      die e.message
    end

    # ── block ──────────────────────────────────────────────────────────────

    def self.cmd_block(args, store)
      slug = args.shift
      die "Usage: tyrion block <slug> \"what unblocks it\" [--discovery disc-NNN]" unless slug

      disc_idx = args.index('--discovery')
      disc_id  = disc_idx ? args[disc_idx + 1] : nil
      reason   = presence((disc_idx ? args[0...disc_idx] : args).join(' '))

      die "Usage: tyrion block <slug> \"what unblocks it\" [--discovery disc-NNN]" unless reason

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      if disc_id
        die "Discovery not found: #{disc_id}" unless store.find_discovery(disc_id)
      end

      store.block_story(story['id'], blocked_on: reason, blocked_on_discovery: disc_id)
      puts "#{Output.red('Blocked:')} #{slug} — #{story['title']}"
      puts "Blocked on: #{reason}"
      puts "Discovery:  #{disc_id}" if disc_id
    rescue RuntimeError => e
      die e.message
    end

    # ── unblock ────────────────────────────────────────────────────────────

    def self.cmd_unblock(args, store)
      slug = args.shift
      die "Usage: tyrion unblock <slug>" unless slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      store.unblock_story(story['id'])
      puts "#{Output.green('Unblocked:')} #{slug} — #{story['title']}"
      puts "Status: #{Output.dim('pending')}"
    rescue RuntimeError => e
      die e.message
    end

    # ── claim-next ─────────────────────────────────────────────────────────

    def self.cmd_claim_next(args, store)
      _project, epic = resolve_project_epic(store)
      story = store.claim_next_story(epic['id'])
      puts "Claimed: #{story['slug']} — #{story['title']}"
      puts "Status: #{Output.yellow('in_progress')}"
    rescue RuntimeError => e
      die e.message
    end

    # ── pocket ─────────────────────────────────────────────────────────────

    def self.cmd_pocket(args, store)
      _project, epic = resolve_project_epic(store)

      story = store.in_progress_story(epic['id'])
      story ||= store.stories_for_epic(epic['id']).find { |s| s['status'] == 'pending' }

      unless story
        puts "No active or pending story."
        return
      end

      criteria = store.criteria_for_story(story['id'])
      unchecked = criteria.select { |c| c['status'] != 'met' }

      puts "epic: #{epic['slug']}"
      puts "story: #{story['slug']}"
      unchecked.each do |c|
        puts "[ ] #{c['keyword']} #{c['text']}"
      end
    end

    # ── mark ──────────────────────────────────────────────────────────────

    def self.cmd_mark(args, store)
      return puts "No active project." unless Repo.active_project

      project, = resolve_project_epic(store, require_epic: false)
      disc = store.create_discovery(
        project_id:  project['id'],
        status:      'mark',
        question:    args.first,
        git_context: Repo.git_context_json
      )
      puts "[mark] #{disc['id']}"
    end

    # ── discover ──────────────────────────────────────────────────────────

    def self.cmd_discover(args, store, input: $stdin, output: $stdout)
      project, = resolve_project_epic(store, require_epic: false)

      question = prompt(input, output, "What were you trying to do? ")
      finding  = prompt(input, output, "What did you find? ")

      disc = store.create_discovery(
        project_id:  project['id'],
        status:      'findings_ready',
        question:    question,
        finding:     finding,
        git_context: Repo.git_context_json
      )
      output.puts "[findings_ready] #{disc['id']}"

      response = prompt(input, output, "Spec this out now? [y/later/no] ").downcase
      output.puts "tyrion spike promote #{disc['id']}" if response == 'y'
    end

    def self.prompt(input, output, label)
      output.print(label)
      output.flush
      input.gets.to_s.strip
    end

    def self.presence(str)
      str && !str.empty? ? str : nil
    end

    # ── discovery ─────────────────────────────────────────────────────────

    def self.cmd_discovery(args, store)
      sub = args.shift
      case sub
      when 'list' then cmd_discovery_list(args, store)
      when 'show' then cmd_discovery_show(args, store)
      else
        die "Usage: tyrion discovery [list|show]"
      end
    end

    def self.cmd_discovery_list(args, store)
      status_filter = resolve_discovery_status(args)
      project       = resolve_project(store)
      discs         = store.list_discoveries(project_id: project['id'], status: status_filter)

      return puts "(no discoveries)" if discs.empty?

      discs.each { |d| puts "#{d['id']}  [#{d['status']}]  #{d['question']}" }
    end

    def self.resolve_discovery_status(args)
      return nil unless (idx = args.index('--status'))

      alias_str = args[idx + 1]
      valid     = DISCOVERY_ALIASES.keys.join(', ')
      die "Missing alias after --status. Valid: #{valid}" if alias_str.nil?
      die "Unknown status alias '#{alias_str}'. Valid: #{valid}" unless DISCOVERY_ALIASES.key?(alias_str)

      DISCOVERY_ALIASES.fetch(alias_str)
    end

    def self.cmd_discovery_show(args, store)
      disc_id = args.shift
      die "Usage: tyrion discovery show <disc-id>" unless disc_id

      disc = store.find_discovery(disc_id)
      die "Discovery #{disc_id} not found" unless disc

      puts "#{disc['id']}  [#{disc['status']}]"
      puts "Question:       #{disc['question'] || '—'}"
      puts "Finding:        #{disc['finding'] || '—'}"
      puts "Confidence:     #{disc['confidence'] || '—'}"
      puts "Recommendation: #{disc['recommendation'] || '—'}"
      puts "Hypothesis:     #{disc['hypothesis'] || '—'}" if disc['hypothesis']
      puts "Exit criteria:  #{disc['exit_criteria'] || '—'}" if disc['exit_criteria']
    end

    # ── spike ─────────────────────────────────────────────────────────────

    def self.cmd_spike(args, store)
      sub = args.shift
      case sub
      when 'start'   then cmd_spike_start(args, store)
      when 'done'    then cmd_spike_done(args, store)
      when 'promote' then cmd_spike_promote(args, store)
      else
        $stderr.puts "Unknown spike subcommand: #{sub}"
        $stderr.puts "Usage: tyrion spike start \"your question\"\n       tyrion spike done\n       tyrion spike promote <disc-id>"
        exit 1
      end
    end

    def self.cmd_spike_start(args, store, input: $stdin, output: $stdout)
      question = args.first&.strip
      die "Usage: tyrion spike start \"your question\"" if question.nil? || question.empty?

      project, = resolve_project_epic(store, require_epic: false)

      if (existing = store.active_spike_for(project['id']))
        die "Active spike already exists: #{existing['id']} — \"#{existing['question']}\"\n" \
            "Close it first: tyrion spike done"
      end

      hypothesis    = prompt(input, output, "Hypothesis (optional, Enter to skip): ")
      exit_criteria = prompt(input, output, "Exit criteria — what does success produce? (optional, Enter to skip): ")

      disc = store.create_discovery(
        project_id:    project['id'],
        status:        'active_spike',
        question:      question,
        hypothesis:    presence(hypothesis),
        exit_criteria: presence(exit_criteria),
        git_context:   Repo.git_context_json
      )
      output.puts "[active_spike] #{disc['id']}"
    end

    def self.cmd_spike_done(args, store, input: $stdin, output: $stdout)
      project, = resolve_project_epic(store, require_epic: false)

      spike = store.active_spike_for(project['id'])
      die "No active spike. Start one: tyrion spike start \"your question\"" unless spike

      finding        = prompt(input, output, "Key finding (one paragraph max): ")
      confidence     = prompt_confidence(input, output)
      recommendation = prompt(input, output, "Recommendation: ")

      disc = store.close_spike(spike['id'], finding: presence(finding), confidence: confidence, recommendation: presence(recommendation))
      output.puts "[findings_ready] #{disc['id']}"
    end

    def self.cmd_spike_promote(args, store, input: $stdin, output: $stdout)
      disc_id = args.shift
      die "Usage: tyrion spike promote <disc-id>" unless disc_id

      disc = store.find_discovery(disc_id)
      die "Discovery #{disc_id} not found" unless disc
      die "Discovery #{disc_id} is not findings_ready (status: #{disc['status']})" unless disc['status'] == 'findings_ready'

      title = presence(prompt(input, output, "Story title [#{disc['question']}]: ")) || disc['question']
      slug  = slugify(title)

      _project, epic = resolve_project_epic(store)

      story = store.promote_discovery_to_story(
        disc_id,
        epic_id: epic['id'],
        slug:    slug,
        title:   title,
        intent:  disc['recommendation']
      )

      output.puts "[promoted] #{story['slug']} <- #{disc_id}"
      print_suggested_criteria(output, story, disc)
    end

    def self.slugify(title)
      title.downcase.gsub(/[^a-z0-9]+/, '-').delete_prefix('-').delete_suffix('-')
    end

    def self.print_suggested_criteria(output, story, disc)
      finding_text = disc['finding'] ? "Spike finding: #{disc['finding']}" : "Per recommendation: #{disc['recommendation']}"
      output.puts ""
      output.puts "Suggested criteria (run to add):"
      output.puts "  tyrion criteria add #{story['slug']} \\"
      output.puts "    --given \"#{finding_text}\" \\"
      output.puts "    --when \"<describe the action>\" \\"
      output.puts "    --then \"<describe the outcome>\""
    end

    def self.prompt_confidence(input, output)
      loop do
        value = prompt(input, output, "Confidence [high/medium/low]: ").downcase
        return value if %w[high medium low].include?(value)
        output.puts "Please enter high, medium, or low."
      end
    end

    # ── resume ─────────────────────────────────────────────────────────────

    def self.cmd_resume(args, store)
      _project, epic = resolve_project_epic(store)

      story = if args.first && !args.first.start_with?('--')
        s = store.find_story(epic['id'], args.first)
        die "Story not found: #{args.first}" unless s
        s
      else
        s = store.in_progress_story(epic['id'])
        die "No in_progress story in epic #{epic['slug']}. Use: tyrion start <slug>" unless s
        s
      end

      stale_flag = if Output.stale?(story['last_note_at'])
        " #{Output.red(Output.stale_label(story['last_note_at']))}"
      else
        ''
      end

      puts "#{Output.bold('Resuming:')} #{story['slug']} — #{story['title']} [#{Output.status_label(story['status'])}]#{stale_flag}"
      puts

      root   = Repo.worktree_root
      branch = Repo.git_branch
      dirty  = Repo.dirty_count
      puts "Branch:   #{branch}"
      puts "Worktree: #{root.sub(Dir.home, '~')}"
      puts "Dirty:    #{dirty > 0 ? Output.yellow("#{dirty} files") : Output.green('clean')}"
      puts

      if story['current_context'] && !story['current_context'].empty?
        puts Output.bold("Current context:")
        story['current_context'].scan(/.{1,80}(?:\s|$)/).each { |l| puts "  #{l.rstrip}" }
        puts
      else
        puts Output.dim("(no current_context — update with: tyrion context #{story['slug']} \"...\")")
        puts
      end

      if story['next_action'] && !story['next_action'].empty?
        puts Output.bold("Next action:") + " #{story['next_action']}"
        puts
      else
        puts Output.dim("(no next_action — update with: tyrion next #{story['slug']} \"...\")")
        puts
      end

      criteria = store.criteria_for_story(story['id'])
      pending_criteria = criteria.reject { |c| c['status'] == 'met' }
      if criteria.any?
        met_n = criteria.length - pending_criteria.length
        puts Output.bold("Criteria (#{met_n}/#{criteria.length} met):")
        criteria.each do |c|
          puts "  #{Output.criterion_icon(c['status'])} #{c['position']}. #{c['keyword'].ljust(5)} #{c['text']}"
        end
        puts
      else
        puts Output.dim("(no criteria yet — add with: tyrion criteria add #{story['slug']} --given \"...\" --then \"...\")")
        puts
      end

      notes = store.notes_for_story(story['id'], limit: 5)
      if notes.any?
        plan_notes = notes.select { |n| n['kind'] == 'plan' }
        other_notes = notes.reject { |n| n['kind'] == 'plan' }

        if plan_notes.any?
          puts Output.bold("Plan notes:")
          plan_notes.each do |n|
            ts = n['created_at'][0, 16].gsub('T', ' ')
            puts "  #{Output.dim(ts)} [plan]"
            n['body'].scan(/.{1,100}(?:\s|$)/).each { |line| puts "    #{line.rstrip}" }
          end
          puts
        end

        if other_notes.any?
          puts Output.bold("Recent notes (last #{other_notes.length}):")
          other_notes.each do |n|
            ts   = n['created_at'][0, 16].gsub('T', ' ')
            body = n['body'][0, 120]
            puts "  #{Output.dim(ts)} [#{n['kind']}] #{body}"
          end
        end
      end
    end

    # ── note ───────────────────────────────────────────────────────────────

    VALID_NOTE_KINDS = %w[plan progress decision blocker test handoff recovery session followup].freeze

    def self.cmd_note(args, store)
      slug = args.shift
      kind = args.shift
      body = args.join(' ')
      die "Usage: tyrion note <slug> <kind> \"body\"\n  kinds: #{VALID_NOTE_KINDS.join('|')}" unless slug && kind && !body.empty?
      die "Invalid kind: #{kind}. Must be one of: #{VALID_NOTE_KINDS.join(', ')}" unless VALID_NOTE_KINDS.include?(kind)

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      store.add_note(story['id'], kind, body)
      puts "Note added to #{slug} [#{kind}]"
    end

    # ── context ────────────────────────────────────────────────────────────

    def self.cmd_context(args, store)
      slug = args.shift
      text = args.join(' ')
      die "Usage: tyrion context <slug> \"fresh resume summary\"" unless slug && !text.empty?

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      store.update_context(story['id'], text)
      puts "Context updated for #{slug}"
    end

    # ── next ───────────────────────────────────────────────────────────────

    def self.cmd_next(args, store)
      slug = args.shift
      text = args.join(' ')
      die "Usage: tyrion next <slug> \"next concrete action\"" unless slug && !text.empty?

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      store.update_next_action(story['id'], text)
      puts "Next action updated for #{slug}"
    end

    # ── criteria ───────────────────────────────────────────────────────────

    def self.cmd_criteria(args, store)
      sub = args.shift
      case sub
      when 'add' then cmd_criteria_add(args, store)
      else
        $stderr.puts "Unknown criteria subcommand: #{sub}"
        $stderr.puts "Usage: tyrion criteria add <slug> [--given TEXT] [--when TEXT] [--then TEXT]"
        exit 1
      end
    end

    def self.cmd_criteria_add(args, store)
      slug = args.shift
      die "Usage: tyrion criteria add <slug> [--given TEXT] [--when TEXT] [--then TEXT]" unless slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      clauses = parse_criteria_flags(args)
      die "No criteria specified. Use --given, --when, --then" if clauses.empty?

      added = store.add_criteria(story['id'], clauses)
      puts "Added #{added.length} criteria to #{slug}:"
      added.each { |c| puts "  #{c['position']}. #{c['keyword'].ljust(5)} #{c['text']}" }
    end

    # ── check ──────────────────────────────────────────────────────────────

    def self.cmd_check(args, store)
      slug     = args.shift
      position = args.shift
      evidence = args.join(' ')
      die "Usage: tyrion check <slug> <position> \"evidence\"" unless slug && position

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      store.check_criterion(story['id'], position.to_i, evidence)
      puts "Criterion #{position} marked met for #{slug}"
      puts "Evidence: #{evidence}" unless evidence.empty?
    rescue RuntimeError => e
      die e.message
    end

    # ── uncheck ────────────────────────────────────────────────────────────

    def self.cmd_uncheck(args, store)
      slug     = args.shift
      position = args.shift
      die "Usage: tyrion uncheck <slug> <position>" unless slug && position

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      store.uncheck_criterion(story['id'], position.to_i)
      puts "Criterion #{position} reopened for #{slug}"
    end

    # ── done ───────────────────────────────────────────────────────────────

    def self.cmd_done(args, store)
      slug    = args.shift
      force   = args.delete('--force')
      summary = args.join(' ')
      die "Usage: tyrion done <slug> \"completion summary\" [--force]" unless slug && !summary.empty?

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      store.complete_story(story['id'], summary, force: force)
      puts "#{Output.green('Done:')} #{slug} — #{story['title']}"
    rescue RuntimeError => e
      die e.message
    end

    # ── unstart ────────────────────────────────────────────────────────────

    def self.cmd_unstart(args, store)
      slug = args.shift
      die "Usage: tyrion unstart <slug>" unless slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      store.unstart_story(story['id'])
      puts "#{slug} reset to pending"
    end

    # ── backfill ───────────────────────────────────────────────────────────

    def self.cmd_backfill(args, store)
      slug    = args.shift
      status  = args.shift
      summary = args.join(' ')
      die "Usage: tyrion backfill <slug> done \"summary\"" unless slug && status && !summary.empty?
      die "backfill only supports 'done' in v1" unless status == 'done'

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      store.backfill_story(story['id'], status, summary)
      puts "#{Output.green('Backfilled:')} #{slug} — #{story['title']} [#{status}]"
    end

    # ── usage ──────────────────────────────────────────────────────────────

    def self.usage
      puts <<~USAGE
        tyrion — resumability ledger for coding agents

        Worktree:
          tyrion init                              Register this repo as a tyrion worktree

        Projects:
          tyrion project list                      List all projects
          tyrion project new <slug> "Name"         Create project
          tyrion project show [slug]               Show project + ABOUT.md
          tyrion project activate <slug>           Set active project for this worktree
          tyrion project sync                      Sync ABOUT.md between disk and DB
          tyrion project edit-about                Open ABOUT.md in $EDITOR

        Epics:
          tyrion epic list                         List epics in active project
          tyrion epic show [slug]                  Show epic intent + context
          tyrion epic activate <slug>              Set active epic for this worktree
          tyrion epic pause <slug>                 Pause an epic

        Import:
          tyrion import <file.feature>             Import gherkin scenarios as stories

        Status & navigation:
          tyrion status                            Plan view (the main command)
          tyrion list [--status pending]           List stories
          tyrion show <slug>                       Full story detail

        Work:
          tyrion start <slug>                      Claim a story (transactional)
          tyrion block <slug> "reason" [--discovery disc-NNN]  Block a story with a reason
          tyrion unblock <slug>                    Unblock a story → back to pending
          tyrion claim-next                        Claim next pending story (transactional)
          tyrion resume [slug]                     Read-only context dump
          tyrion note <slug> <kind> "body"         Append note (kinds: plan|progress|decision|blocker|test|handoff|recovery|session|followup)
          tyrion context <slug> "text"             Update current_context
          tyrion next <slug> "text"                Update next_action

        Criteria:
          tyrion criteria add <slug> --given "..." --when "..." --then "..."
          tyrion check <slug> <position> "evidence"
          tyrion uncheck <slug> <position>

        Completion:
          tyrion done <slug> "summary" [--force]   Complete story
          tyrion unstart <slug>                    Reset to pending (crash recovery)
          tyrion backfill <slug> done "summary"    Mark pre-Tyrion work done

        Discovery (SDRD spike loop):
          tyrion mark "description"                Bookmark — instant breadcrumb with git context
          tyrion discover                          Organic capture — question + finding → findings_ready
          tyrion spike start "question"            Frame a known unknown → active_spike
          tyrion spike done                        Close spike with finding + confidence + recommendation
          tyrion spike promote <disc-id>           Promote findings_ready → linked story
          tyrion discovery list [--status <alias>] List discoveries (aliases: active|ready|promoted|deferred|all)
          tyrion discovery show <disc-id>          Show full discovery detail
      USAGE
    end

    private

    # ── Helpers ────────────────────────────────────────────────────────────

    def self.die(msg)
      $stderr.puts "Error: #{msg}"
      exit 1
    end

    def self.resolve_project(store)
      slug = Repo.active_project
      die "No active project. Run: tyrion project activate <slug>" unless slug
      project = store.find_project_by_slug(slug)
      die "Active project '#{slug}' not found. Run: tyrion init" unless project
      project
    end

    def self.resolve_project_epic(store, require_epic: true)
      project = resolve_project(store)

      epic_slug = Repo.active_epic
      unless epic_slug
        die "No active epic. Run: tyrion epic activate <slug>" if require_epic
        return [project, nil]
      end

      epic = store.find_epic(project['id'], epic_slug)
      die "Active epic '#{epic_slug}' not found. Run: tyrion epic activate <slug>" unless epic

      [project, epic]
    end

    def self.parse_criteria_flags(args)
      clauses = []
      i = 0
      while i < args.length
        case args[i]
        when '--given'
          die "Missing text after --given" unless args[i + 1]
          clauses << { keyword: 'Given', semantic_kind: 'given', text: args[i + 1] }
          i += 2
        when '--when'
          die "Missing text after --when" unless args[i + 1]
          clauses << { keyword: 'When', semantic_kind: 'when', text: args[i + 1] }
          i += 2
        when '--then'
          die "Missing text after --then" unless args[i + 1]
          clauses << { keyword: 'Then', semantic_kind: 'then', text: args[i + 1] }
          i += 2
        else
          $stderr.puts "Warning: ignoring unknown flag #{args[i]}"
          i += 1
        end
      end
      clauses
    end
  end
end
