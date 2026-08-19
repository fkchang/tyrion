# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'
require 'timeout'
require_relative 'importer'
require_relative 'lesson_miner'

module Tyrion
  module Commands
    STALE_HOURS = 4

    TYRION_PERMISSIONS = [
      'Bash(ruby bin/tyrion *)',
      'Bash(tyrion *)'
    ].freeze

    VALID_EPIC_MODES = %w[dark_factory shape].freeze

    WHITELIST_SCOPES = {
      'local'   => -> { File.join(Dir.pwd, '.claude', 'settings.local.json') },
      'project' => -> { File.join(Dir.pwd, '.claude', 'settings.json') },
      'global'  => -> { File.join(Dir.home, '.claude', 'settings.json') }
    }.freeze

    # Sentinel — :unset means "not yet derived"; nil is a valid memoized result.
    # Specs reset this to :unset to re-derive between examples.
    @_lane_token = :unset

    DISCOVERY_ALIASES = {
      'active'   => 'active_spike',
      'marks'    => 'mark',
      'ready'    => 'findings_ready',
      'promoted' => 'promoted_to_story',
      'deferred' => 'deferred',
      'all'      => nil
    }.freeze

    # `tyrion hook claim-gate` payload version — printed by `--check` so a caller
    # (e.g. a future `tyrion setup claude --check`) can detect an installed shim
    # that predates the gate logic it now execs.
    GATE_VERSION = 1

    # Generic shim template version — bumped independently of GATE_VERSION
    # since the shim's own logic (not the gate's) is what changes it.
    SHIM_VERSION = 1

    # Where `tyrion setup claude` installs the shim script, relative to a
    # target repo's root. Single source of truth for both the installed
    # file's path and the `hooks[*].hooks[*].command` strings the
    # settings-merge engine writes to reference it.
    SHIM_INSTALL_PATH = '.claude/hooks/tyrion-shim.sh'

    # Where `tyrion setup claude` reads/writes the merged Claude Code settings
    # file, relative to a target repo's root. Pairs with SHIM_INSTALL_PATH.
    SETTINGS_RELATIVE_PATH = '.claude/settings.json'

    # Where `tyrion setup claude` reads/writes the managed CLAUDE.md block,
    # relative to a target repo's root.
    CLAUDE_MD_RELATIVE_PATH = 'CLAUDE.md'

    # Bumped whenever the canonical block body text changes, so `--check` can
    # tell "stale template" drift apart from a merely-hand-edited body.
    CLAUDE_MD_BLOCK_VERSION = 1

    # `tyrion setup claude --check` exit codes (priority order: PARTIAL beats
    # DRIFT beats FAIL_OPEN beats CURRENT — see cmd_setup_claude_check).
    EXIT_CURRENT   = 0
    EXIT_DRIFT     = 1
    EXIT_PARTIAL   = 2
    EXIT_FAIL_OPEN = 3

    def self.run(argv)
      args = argv.dup
      cmd  = args.shift
      return cmd_prime(args) if cmd == 'prime'

      store = Store.new

      case cmd
      when 'init'         then cmd_init(args, store)
      when 'project'      then cmd_project(args, store)
      when 'epic'         then cmd_epic(args, store)
      when 'import'       then cmd_import(args, store)
      when 'status'       then cmd_status(args, store)
      when 'statusline'   then cmd_statusline(args, store)
      when 'list'         then cmd_list(args, store)
      when 'show'         then cmd_show(args, store)
      when 'notes'        then cmd_notes(args, store)
      when 'start'        then cmd_start(args, store)
      when 'dispatch'     then cmd_dispatch(args, store)
      when 'violations'   then cmd_violations(args, store)
      when 'assign'       then cmd_assign(args, store)
      when 'claim'        then cmd_claim(args, store)
      when 'block'        then cmd_block(args, store)
      when 'unblock'      then cmd_unblock(args, store)
      when 'claim-next'   then cmd_claim_next(args, store)
      when 'unclaim'      then cmd_unclaim(args, store)
      when 'whoami'       then cmd_whoami(args, store)
      when 'worktrees'    then cmd_worktrees(args, store)
      when 'web', 'dashboard' then cmd_web(args, store)
      when 'pocket'       then cmd_pocket(args, store)
      when 'mark'         then cmd_mark(args, store)
      when 'discover'     then cmd_discover(args, store)
      when 'discovery'    then cmd_discovery(args, store)
      when 'spike'        then cmd_spike(args, store)
      when 'resume'       then cmd_resume(args, store)
      when 'note'         then cmd_note(args, store)
      when 'gate'         then cmd_gate(args, store)
      when 'commits'      then cmd_commits(args, store)
      when 'context'      then cmd_context(args, store)
      when 'next'         then cmd_next(args, store)
      when 'reconcile'    then cmd_reconcile(args, store)
      when 'criteria'     then cmd_criteria(args, store)
      when 'check'        then cmd_check(args, store)
      when 'uncheck'      then cmd_uncheck(args, store)
      when 'done'         then cmd_done(args, store)
      when 'unstart'      then cmd_unstart(args, store)
      when 'backfill'     then cmd_backfill(args, store)
      when 'drift'        then cmd_drift(args, store)
      when 'followup'     then cmd_followup(args, store)
      when 'depends'      then cmd_depends(args, store)
      when 'wave'         then cmd_wave(args, store)
      when 'whitelist'    then cmd_whitelist(args, store)
      when 'setup'        then cmd_setup(args, store)
      when 'setup-codex'  then cmd_setup_codex(args, store)
      when 'hook'         then cmd_hook(args, store)
      when 'lesson'       then cmd_lesson(args, store)
      when 'lessons'      then cmd_lesson(['list'] + args, store)
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
      when 'set-initiative' then cmd_project_set_initiative(args, store)
      else
        $stderr.puts "Unknown project subcommand: #{sub}"
        $stderr.puts "Usage: tyrion project [list|new|show|activate|sync|edit-about|set-initiative]"
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
      puts "Initiative: #{project['initiative_id']}" if presence(project['initiative_id'])
      puts

      if project['about_md'] && !project['about_md'].empty?
        puts Output.bold("About:")
        puts project['about_md']
        puts
      end

      epics = store.list_epics(project['id'])
      active_epics = epics.reject { |e| e['archived_at'] }
      if active_epics.any?
        puts Output.bold("Epics (#{active_epics.length}):")
        graph = store.epic_graph(project['id'])
        Store.epic_tree_order(active_epics, graph).each do |e, depth, parent_archived|
          indent      = '  ' * (depth + 1)
          done, total, container = epic_progress(store, e, graph)
          counts      = container ? "#{done}/#{total} sealed" : "#{done}/#{total} done"
          parent_note = parent_archived ? " #{Output.dim('(parent archived)')}" : ''
          puts "#{indent}#{e['slug']}  #{e['name']}  #{counts}  [#{e['status']}]#{parent_note}"
        end
      elsif epics.any?
        puts "No active epics (#{epics.length} archived). See: tyrion epic list"
      else
        puts "No epics yet. Import one: tyrion import features/<epic>.feature"
      end
    end

    def self.cmd_project_set_initiative(args, store)
      initiative_id = args.shift
      die "Usage: tyrion project set-initiative <id>" unless presence(initiative_id)

      slug = Repo.active_project
      die "No active project. Use: tyrion project activate <slug>" unless slug
      project = store.find_project_by_slug(slug)
      die "Project not found: #{slug}" unless project

      store.update_project(project['id'], 'initiative_id' => initiative_id)
      puts "Initiative set to: #{initiative_id}"
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
      when 'complete' then cmd_epic_complete(args, store)
      when 'archive'   then cmd_epic_archive(args, store)
      when 'unarchive' then cmd_epic_unarchive(args, store)
      when 'mode'      then cmd_epic_mode(args, store)
      when 'parent'    then cmd_epic_parent(args, store)
      when 'depends'   then cmd_epic_depends(args, store)
      when 'waves'     then cmd_epic_waves(args, store)
      else
        $stderr.puts "Unknown epic subcommand: #{sub}"
        $stderr.puts "Usage: tyrion epic [list|show|activate|pause|complete|archive|unarchive|mode|parent|depends|waves]"
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
      active_slug = Repo.active_epic(token: current_lane_token)
      graph = store.epic_graph(project['id'])
      active, archived = epics.partition { |e| e['archived_at'].nil? }

      line = lambda do |e, extra_tag = '', depth: 0, parent_archived: false|
        indent  = '  ' * depth
        done, total, container = epic_progress(store, e, graph)
        counts  = container ? "#{done}/#{total} sealed" : "#{done}/#{total}"
        # Only show status bracket for non-default statuses — avoids every epic
        # looking [active] when that's just the DB default, not the active pointer.
        status_tag  = e['status'] == 'active' ? '' : " [#{e['status']}]"
        badge       = Output.epic_mode_badge(e)
        mode_tag    = badge.empty? ? '' : " #{badge}"
        pointer     = e['slug'] == active_slug ? " #{Output.cyan('← active')}" : ''
        # Waiting only means something for an epic that would otherwise be
        # workable — an already-archived/paused/abandoned/done epic has its
        # own status_tag explaining why, so this stays quiet for those.
        unmet       = e['status'] == 'active' && e['archived_at'].nil? ? store.unmet_prereqs(e, graph) : []
        waiting_tag = unmet.empty? ? '' : " #{Output.yellow("waiting — requires: #{Output.unmet_prereqs_text(unmet)}")}"
        parent_note = parent_archived ? " #{Output.dim('(parent archived)')}" : ''
        puts "#{indent}#{e['slug']}  #{e['name']}  #{counts}#{status_tag}#{mode_tag}#{waiting_tag}#{parent_note}#{extra_tag}#{pointer}"
      end

      Store.epic_tree_order(active, graph).each { |e, depth, parent_archived| line.call(e, depth: depth, parent_archived: parent_archived) }

      unless archived.empty?
        puts
        puts Output.dim("Archived:")
        Store.epic_tree_order(archived, graph).each do |e, depth, parent_archived|
          line.call(e, " #{Output.dim('[archived]')}", depth: depth, parent_archived: parent_archived)
        end
      end
    end

    # Derived progress for one epic-list/epic-show line: a leaf (no
    # descendants) shows its own story done/total, unchanged from before this
    # story. A container (has descendants) shows sealed/total *epics*
    # (itself + every descendant) instead — its own story fraction would
    # under-report what a campaign actually contains. `container` tells the
    # caller which wording ("sealed" vs bare fraction) applies.
    def self.epic_progress(store, epic, graph)
      stats = store.epic_seal_stats(epic['id'], graph)
      if stats
        [stats[:done], stats[:total], true]
      else
        stories = store.stories_for_epic(epic['id'])
        [stories.count { |s| s['status'] == 'done' }, stories.length, false]
      end
    end
    private_class_method :epic_progress

    # Ancestor breadcrumb ("campaign › sub-campaign › ") for a nested epic,
    # root-first — empty string for a top-level epic. Shared by cmd_status and
    # cmd_prime's two tiers so the crumb reads the same everywhere it appears;
    # cmd_prime is the surface that survives /clear, which is why this exists
    # at all — the graph must not live only in the reader's head.
    def self.epic_ancestor_crumb(store, epic, graph)
      ancestors = store.epic_ancestors(epic['id'], graph) # nearest-first ids
      return '' if ancestors.empty?

      slugs = ancestors.reverse.map { |aid| graph[:epics][aid]['slug'] }
      "#{Output.dim("#{slugs.join(' › ')} ›")} "
    end
    private_class_method :epic_ancestor_crumb

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

      graph = store.epic_graph(epic['project_id'])
      if epic['parent_epic_id']
        parent = graph[:epics][epic['parent_epic_id']]
        puts "Parent: #{parent ? parent['slug'] : '(unknown)'}"
      end

      deps = JSON.parse(epic['depends_on'] || '[]')
      if deps.any?
        unmet_by_slug = store.unmet_prereqs(epic, graph).each_with_object({}) { |u, h| h[u[:slug]] = u[:reason] }
        deps_text = deps.map { |d| (r = unmet_by_slug[d]) ? "#{d} (#{Output.prereq_reason_text(r) || 'not sealed yet'})" : d }.join(', ')
        puts "Requires: #{deps_text}"
      end

      children_ids = graph[:children][epic['id']] || []
      puts "Children: #{children_ids.map { |cid| graph[:epics][cid]['slug'] }.join(', ')}" if children_ids.any?

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

      warn_if_epic_waiting(store, epic)

      token = current_lane_token
      if token
        set_active_epic_for_lane(slug, token: token)
      else
        Repo.write_active_epic(slug)
      end
      puts "Active epic set to: #{epic['name']} [#{slug}]"
    end

    def self.cmd_epic_pause(args, store)
      slug = args.shift || Repo.active_epic(token: current_lane_token)
      die "Usage: tyrion epic pause <slug>" unless slug
      project = resolve_project(store)
      epic    = store.find_epic(project['id'], slug)
      die "Epic not found: #{slug}" unless epic

      store.update_epic(epic['id'], 'status' => 'paused')
      puts "Epic paused: #{epic['name']} [#{slug}]"
    end

    def self.cmd_epic_complete(args, store)
      force = args.delete('--force')
      slug  = args.shift || Repo.active_epic(token: current_lane_token)
      die "Usage: tyrion epic complete <slug> [--force]" unless slug
      project = resolve_project(store)
      epic    = store.find_epic(project['id'], slug)
      die "Epic not found: #{slug}" unless epic

      unlocked = seal_epic_and_report_unlocks(store, epic, force: !!force)
      puts "Epic #{slug} sealed as done."
      puts Output.dim("Tip: /tyrion-changelog #{slug} — add a changelog entry for this epic.")
      print_unlocked_epics(unlocked)
    rescue RuntimeError => e
      die e.message
    end

    def self.cmd_epic_archive(args, store)
      slug = args.shift || Repo.active_epic(token: current_lane_token)
      die "Usage: tyrion epic archive <slug>" unless slug
      project = resolve_project(store)
      epic    = store.find_epic(project['id'], slug)
      die "Epic not found: #{slug}" unless epic

      store.archive_epic(epic['id'])
      puts "Epic archived: #{epic['name']} [#{slug}]. Restore with: tyrion epic unarchive #{slug}"
    end

    def self.cmd_epic_unarchive(args, store)
      slug = args.shift
      die "Usage: tyrion epic unarchive <slug>" unless slug
      project = resolve_project(store)
      epic    = store.find_epic(project['id'], slug)
      die "Epic not found: #{slug}" unless epic

      store.unarchive_epic(epic['id'])
      puts "Epic unarchived: #{epic['name']} [#{slug}]"
    end

    def self.cmd_epic_mode(args, store)
      slug  = args.shift
      value = args.shift
      die "Usage: tyrion epic mode <slug> [dark_factory|shape]" unless slug

      project = resolve_project(store)
      epic    = store.find_epic(project['id'], slug)
      die "Epic not found: #{slug}" unless epic

      unless value # bare word — orchestrate/implement parse this, never mutate here
        puts(Output.dark_factory?(epic) ? 'dark_factory' : 'shape')
        return
      end

      die "Invalid mode: #{value}. Must be one of: #{VALID_EPIC_MODES.join(', ')}" unless VALID_EPIC_MODES.include?(value)

      stored_mode = value == 'shape' ? nil : value # shape is the canonical NULL
      store.update_epic(epic['id'], 'mode' => stored_mode)
      puts "Epic mode set: #{epic['name']} [#{slug}] -> #{value}"
    end

    def self.cmd_epic_parent(args, store)
      slug       = args.shift
      parent_arg = args.shift
      die "Usage: tyrion epic parent <slug> <parent-slug> | tyrion epic parent <slug> --none" unless slug && parent_arg

      project = resolve_project(store)
      epic    = store.find_epic(project['id'], slug)
      die "Epic not found: #{slug}" unless epic

      if parent_arg == '--none'
        store.set_epic_parent(epic['id'], nil)
        puts "Epic #{slug} parent cleared."
      else
        parent_epic = store.find_epic(project['id'], parent_arg)
        die "Epic not found: #{parent_arg}" unless parent_epic
        store.set_epic_parent(epic['id'], parent_epic['id'])
        puts "Epic #{slug} parent set to #{parent_arg}."
      end
    rescue RuntimeError => e
      die e.message
    end

    def self.cmd_epic_depends(args, store)
      subcmd = args.shift
      case subcmd
      when 'add' then cmd_epic_depends_add(args, store)
      when 'rm'  then cmd_epic_depends_rm(args, store)
      else
        die "Usage: tyrion epic depends add <slug> <dep-slug> | tyrion epic depends rm <slug> <dep-slug>"
      end
    end

    def self.cmd_epic_depends_add(args, store)
      slug, dep_slug = args
      die "Usage: tyrion epic depends add <slug> <dep-slug>" unless slug && dep_slug

      project = resolve_project(store)
      epic    = store.find_epic(project['id'], slug)
      die "Epic not found: #{slug}" unless epic

      current = JSON.parse(epic['depends_on'] || '[]')
      if current.include?(dep_slug)
        puts "#{slug} already depends on #{dep_slug}"
      else
        store.add_epic_dependency(epic['id'], dep_slug)
        puts "#{Output.green('+')} #{slug} now depends on #{dep_slug}"
      end
    rescue RuntimeError => e
      die e.message
    end

    def self.cmd_epic_depends_rm(args, store)
      slug, dep_slug = args
      die "Usage: tyrion epic depends rm <slug> <dep-slug>" unless slug && dep_slug

      project = resolve_project(store)
      epic    = store.find_epic(project['id'], slug)
      die "Epic not found: #{slug}" unless epic

      current = JSON.parse(epic['depends_on'] || '[]')
      if current.include?(dep_slug)
        store.remove_epic_dependency(epic['id'], dep_slug)
        puts "#{Output.red('-')} #{slug} no longer depends on #{dep_slug}"
      else
        puts "#{slug} does not depend on #{dep_slug}"
      end
    rescue RuntimeError => e
      die e.message
    end

    def self.cmd_epic_waves(_args, store)
      project = resolve_project(store)
      graph   = store.epic_graph(project['id'])
      waves   = store.epic_wave_plan(graph)
      if waves.empty?
        puts Output.dim("No runnable epics in this project.")
        return
      end
      waves.each do |wave_num, slugs|
        if wave_num == :cycle
          puts "#{Output.red('Cycle')}: #{slugs.join(', ')} (circular dependency — fix with tyrion epic depends rm)"
        else
          puts "#{Output.bold("Wave #{wave_num}")}: #{slugs.join(', ')}"
        end
      end
    end

    def self.cmd_import(args, store)
      die "Usage: tyrion import <file.feature> [--confirm-abandon] [--force] [--criteria=then]" if args.empty?
      Importer.run(args, store)
    end

    # ── status ─────────────────────────────────────────────────────────────

    # How many of the newest marks the DISCOVERIES lane spells out before collapsing
    # the rest into a "(N more)" pointer, and how much of each one fits on its single
    # line — a mark filed as a paragraph would otherwise wrap over the whole screen.
    # 72 matches the NEEDS FOLLOW-UP rows just above it.
    STATUS_MARKS_LIMIT     = 3
    STATUS_MARK_TEXT_WIDTH = 72

    def self.cmd_status(args, store)
      project_slug = Repo.active_project
      epic_slug    = Repo.active_epic(token: current_lane_token)

      unless project_slug
        puts "No active project. Run:"
        puts "  tyrion init"
        puts "  tyrion project new <slug> \"Name\""
        puts "  tyrion project activate <slug>"
        return
      end

      project = store.find_project_by_slug(project_slug)
      die "Active project '#{project_slug}' not found in DB. Run: tyrion init" unless project

      north_star = project['about_md']&.lines&.first&.strip&.sub(/^#+\s*/, '')
      puts "#{Output.bold('Project:')} #{project['name']} [#{Output.dim(project_slug)}]"
      puts "  #{Output.dim(north_star)}" if presence(north_star)

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

      graph      = store.epic_graph(project['id'])
      crumb      = epic_ancestor_crumb(store, epic, graph)
      badge      = Output.epic_mode_badge(epic)
      mode_badge = badge.empty? ? '' : "  #{badge}"
      puts "#{Output.bold('Epic:')}    #{crumb}#{epic['name']} [#{Output.dim(epic_slug)}]#{mode_badge}"

      if epic['intent'] && !epic['intent'].empty?
        puts "           #{Output.dim(epic['intent'][0, 80])}#{'…' if epic['intent'].length > 80}"
      end

      if (drift_path = drift_changed_path(epic, Repo.worktree_root))
        print_drift_warning(drift_path, indent: '  ')
      end

      # Same "otherwise it would explain itself" quiet-default as cmd_epic_list.
      unmet = epic['status'] == 'active' && epic['archived_at'].nil? ? store.unmet_prereqs(epic, graph) : []
      puts "  #{Output.yellow('⚠ waiting on:')} #{Output.unmet_prereqs_text(unmet)}" unless unmet.empty?

      puts

      stories = store.stories_for_epic(epic['id'])
      done_n  = stories.count { |s| s['status'] == 'done' }
      ip_n    = stories.count { |s| s['status'] == 'in_progress' }
      pend_n  = stories.count { |s| s['status'] == 'pending' }
      blk_n   = stories.count { |s| s['status'] == 'blocked' }
      claimed_n = stories.count { |s| s['status'] == 'pending' && s['claimed_by'].to_s.start_with?('assigned:') }

      counts = []
      counts << Output.green("#{done_n} done")
      counts << Output.yellow("#{ip_n} in_progress")
      counts << "#{pend_n} pending"
      counts << Output.yellow("#{claimed_n} pre-claimed") if claimed_n > 0
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

      # ── lanes ────────────────────────────────────────────────────────────
      # One row per in_progress story — an epic can have several, one per active
      # lane. Surfaces owner token + liveness so a story silently held by a dead
      # lane is visible instead of hidden behind a single-row query.
      lanes = store.in_progress_stories(epic['id'])
      unless lanes.empty?
        my_token = current_lane_token
        puts "  #{Output.bold('LANES')} (#{lanes.size} active)"
        lanes.each do |s|
          owner   = s['claimed_by']
          owner_s = owner || Output.dim('(unclaimed)')
          # An unclaimed lane has no pid to probe, so liveness reads "unknown".
          live    = case Repo.lane_liveness(owner)
                    when :live  then Output.green('live')
                    when :dead  then Output.red('dead')
                    else             Output.dim('unknown')
                    end
          age     = Output.time_ago(s['last_note_at'])
          you     = owner && my_token && owner == my_token ? " #{Output.cyan('← you')}" : ''
          puts "  #{s['slug'].ljust(slug_w)}  #{owner_s}  #{live}  #{Output.dim(age)}#{you}"
        end
        puts
      end

      # ── next-epic suggestion ─────────────────────────────────────────────
      if epic_drained?(store, epic['id'])
        print_next_epic_suggestion(store, epic)
        puts
      end

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

      # ── stale lane (dead owning process) ─────────────────────────────────
      stale_lanes = stories.select do |s|
        s['status'] == 'in_progress' && presence(s['claimed_by']) &&
          Repo.lane_liveness(s['claimed_by']) == :dead
      end
      unless stale_lanes.empty?
        puts "  #{Output.red('STALE')}"
        stale_lanes.each do |s|
          slug_col = s['slug'].ljust(slug_w)
          puts "  #{Output.red('✗')} #{slug_col}  lane dead (#{s['claimed_by']})"
          puts "    #{Output.dim('→ unclaim:')} tyrion unclaim #{s['slug']}"
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
          puts "  ● #{d['id']}  #{Output.origin_tag(d['origin'])}  #{Output.discovery_glance_text(d)}"
        end
        findings_ready.each do |d|
          puts "  → #{d['id']}  #{Output.origin_tag(d['origin'])}  #{Output.discovery_glance_text(d)}  (tyrion spike promote #{d['id']})"
        end
        # Marks render as rows now, newest first — a count told you something was filed
        # but never what, so the origin split rides each row instead of a summary line.
        # list_discoveries is oldest-first with no tiebreak; marks filed in the same second
        # would order arbitrarily, so fall back to the id, which counts up per project.
        newest_marks = marks.sort_by { |d| [d['created_at'].to_s, d['id'].to_s] }.reverse
        newest_marks.first(STATUS_MARKS_LIMIT).each do |d|
          text = Output.discovery_glance_text(d)
          text = "#{text[0, STATUS_MARK_TEXT_WIDTH - 1]}…" if text.length > STATUS_MARK_TEXT_WIDTH
          puts "  ○ #{d['id']}  #{Output.origin_tag(d['origin'])}  #{text}"
        end
        remaining = marks.size - STATUS_MARKS_LIMIT
        puts Output.dim("  (#{remaining} more — tyrion discovery list --status marks)") if remaining > 0
        puts
      end

      # ── lessons ──────────────────────────────────────────────────────────
      lessons = lessons_for_scope(store, project_id: project['id'], epic_id: epic['id'])
      unless lessons.empty?
        puts "  LESSONS"
        lessons.each { |l| puts "  📎 #{l['id']}  [#{l['trigger']}]  #{l['text']}" }
        puts
      end

      root   = Repo.worktree_root
      branch = Repo.git_branch
      dirty  = Repo.dirty_count
      dirty_s = dirty > 0 ? Output.yellow("#{dirty} dirty") : Output.green("clean")
      puts "  #{Output.dim('git:')} #{branch}  #{Output.dim(root.sub(Dir.home, '~'))}  #{dirty_s}"
    end

    # ── statusline ───────────────────────────────────────────────────────────

    # One-line lane surface for the Claude Code statusline: "<epic>/<story> (done/total)".
    # Resolves the lane via current_lane_token so each terminal sees its own epic/story.
    # Prints nothing (exit 0) when this lane has no active epic. The in-progress story is
    # the one claimed by this lane, falling back to any in_progress story in the epic.
    def self.cmd_statusline(_args, store)
      project_slug = Repo.active_project
      return unless project_slug
      project = store.find_project_by_slug(project_slug)
      return unless project

      token     = current_lane_token
      epic_slug = Repo.active_epic(token: token)
      return unless epic_slug
      epic = store.find_epic(project['id'], epic_slug)
      return unless epic

      story   = token && store.story_in_progress_for_token(epic['id'], token)
      story ||= store.in_progress_story(epic['id'])

      stories = store.stories_for_epic(epic['id'])
      done    = stories.count { |s| s['status'] == 'done' }
      total   = stories.count { |s| s['status'] != 'abandoned' }

      label = story ? "#{epic_slug}/#{story['slug']}" : epic_slug
      puts "#{label} (#{done}/#{total})"
    end

    # ── list ───────────────────────────────────────────────────────────────

    def self.cmd_list(args, store)
      status_idx = args.index('--status')
      status_filter = status_idx ? args[status_idx + 1] : nil
      # First positional arg (not a flag, not the --status value) names an epic to list.
      epic_slug = args.each_with_index.find { |a, i|
        !a.start_with?('--') && !(status_idx && i == status_idx + 1)
      }&.first

      epic =
        if epic_slug
          project = resolve_project(store)
          store.find_epic(project['id'], epic_slug) || die("Epic not found: #{epic_slug}")
        else
          resolve_project_epic(store).last
        end

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
      puts "Completed by: #{story['completed_by']}" if story['status'] == 'done' && presence(story['completed_by'])
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

      print_gates_section(store, story['id'])

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

    # ── notes ──────────────────────────────────────────────────────────────
    # Full untruncated note dump — the "deep view" complement to the 70/120-char
    # summary shown in tyrion show / tyrion resume.

    def self.cmd_notes(args, store)
      kind_filter = extract_flag_value(args, '--kind')
      slug        = args.reject { |a| a.start_with?('--') }.first
      die "Usage: tyrion notes <slug> [--kind <kind>]" unless slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      notes = store.notes_for_story(story['id'], limit: 100)
      notes = notes.select { |n| n['kind'] == kind_filter } if kind_filter

      if notes.empty?
        puts kind_filter ? "No #{kind_filter} notes for #{slug}." : "No notes for #{slug}."
        return
      end

      puts Output.bold("Notes for #{slug}") + (kind_filter ? " [#{kind_filter}]" : "")
      puts
      notes.each do |n|
        ts = n['created_at'][0, 16].gsub('T', ' ')
        puts "#{Output.dim(ts)} [#{Output.cyan(n['kind'])}]"
        puts n['body']
        puts
      end
    end

    # ── start ──────────────────────────────────────────────────────────────

    def self.cmd_start(args, store)
      steal = !!args.delete('--steal')
      slug  = args.shift
      die "Usage: tyrion start <slug> [--steal]" unless slug

      _project, epic = resolve_project_epic(store)
      warn_if_epic_waiting(store, epic)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug} in epic #{epic['slug']}" unless story

      if story['status'] == 'blocked'
        reason = story['blocked_on'] || 'unknown reason'
        die "#{slug} is blocked: #{reason}\nRun: tyrion unblock #{slug}"
      end

      # Adoption path: a story dispatched to this lane (claimed_by starts with
      # "dispatched:") is ours to take over — no steal required. The dispatch
      # command already started it; we just re-stamp claimed_by to our token.
      owner = presence(story['claimed_by'])
      is_dispatched_to_us = story['status'] == 'in_progress' && owner&.start_with?('dispatched:')

      # Hijack guard: an in_progress story owned by a *different* lane may be live
      # work. Never silently re-stamp it to us — require explicit --steal, even
      # when the owning lane is dead (the gentle path is `tyrion unclaim`).
      if story['status'] == 'in_progress' && owner && owner != current_lane_token && !is_dispatched_to_us
        unless steal
          liveness = Repo.lane_liveness(owner)
          die "#{slug} is already in_progress, claimed by #{owner} (lane #{liveness}).\n" \
              "Release it:        tyrion unclaim #{slug}\n" \
              "Or force takeover: tyrion start #{slug} --steal"
        end
        store.unstart_story(story['id'], note: "Stolen via tyrion start --steal (prior owner: #{owner})")
        Repo.clear_active_story(token: owner)
      end

      story = store.start_story(story['id'], claimed_by: current_lane_token)
      Repo.write_active_story(story['slug'], token: current_lane_token) if current_lane_token
      if is_dispatched_to_us
        puts "Adopted: #{story['slug']} — #{story['title']} (was #{owner})"
      else
        puts "Started: #{story['slug']} — #{story['title']}"
      end
      puts "Status: #{Output.yellow('in_progress')}"
    rescue RuntimeError => e
      die e.message
    end

    # ── unclaim ────────────────────────────────────────────────────────────
    # Release a lane's claim on a story: NULL claimed_by/claimed_at + reset to
    # pending. A dead owning lane (pid gone/recycled) is free to release — this
    # is the recovery path the STALE lane in `tyrion status` points at. A live
    # or unverifiable OTHER lane requires --steal so we never yank active work.

    def self.cmd_unclaim(args, store)
      steal = !!args.delete('--steal')
      slug  = args.shift
      die "Usage: tyrion unclaim <slug> [--steal]" unless slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      owner = presence(story['claimed_by'])
      if owner && owner != current_lane_token
        liveness = Repo.lane_liveness(owner)
        if liveness != :dead && !steal
          label = liveness == :live ? 'a LIVE lane' : "a lane whose liveness can't be verified (#{liveness})"
          die "#{slug} is claimed by #{label}: #{owner}\n" \
              "Another agent may be working on it. Use --steal to force release."
        end
      end

      Repo.clear_active_story(token: owner) if owner
      store.unstart_story(story['id'], note: "Lane released via tyrion unclaim (prior owner: #{owner || 'none'})")
      puts "#{Output.green('Unclaimed:')} #{slug} — reset to pending"
      puts "Prior owner: #{owner}" if owner
    rescue RuntimeError => e
      die e.message
    end

    # ── whoami ─────────────────────────────────────────────────────────────
    # Print the resolved lane token, its liveness, and the story this lane owns
    # in the active epic. The zero-friction "which lane am I?" check.

    def self.cmd_whoami(args, store)
      token = current_lane_token
      puts "Lane:  #{token || Output.dim('(none — legacy single-session)')}"
      puts "State: #{Repo.lane_liveness(token)}" if token

      story = nil
      if (project_slug = Repo.active_project) &&
         (project = store.find_project_by_slug(project_slug)) &&
         (epic_slug = Repo.active_epic(token: token)) &&
         (epic = store.find_epic(project['id'], epic_slug))
        story = token ? store.story_in_progress_for_token(epic['id'], token)
                      : store.story_in_progress_unclaimed(epic['id'])
      end

      if story
        puts "Story: #{story['slug']} [#{Output.yellow(story['status'])}]"
      else
        puts "Story: #{Output.dim('(none claimed by this lane)')}"
      end
    end

    # ── worktrees ──────────────────────────────────────────────────────────
    # Cross-lane dashboard: one block per git worktree, one line per active lane
    # (in_progress story with an owner token) mapped into it, plus a trailing
    # section for orphan lanes whose worktree isn't in `git worktree list`.
    # A lane maps to a worktree when SHA256(token)[0,16] matches a lane dir under
    # that worktree's .tyrion/lanes. Read-only — no state mutation.

    def self.cmd_worktrees(args, store)
      project  = resolve_project(store)
      my_token = current_lane_token

      # Every active lane across the project: one per in_progress owned story.
      lanes = store.list_epics(project['id']).flat_map do |e|
        store.in_progress_stories(e['id']).filter_map do |st|
          tok = presence(st['claimed_by'])
          tok && { token: tok, hash: Repo.lane_hash(tok),
                   epic: e['slug'], story: st['slug'], age: st['last_note_at'] }
        end
      end

      worktrees = Repo.worktrees
      matched   = {}

      puts "#{Output.bold('WORKTREES')} — #{project['slug']}  " \
           "#{Output.dim("(#{pluralize(worktrees.size, 'worktree')} · #{pluralize(lanes.size, 'active lane')})")}"
      puts

      worktrees.each do |wt|
        wt_hashes = Repo.lane_hashes(wt[:path])
        wt_lanes  = lanes.select { |l| wt_hashes.include?(l[:hash]) }
        wt_lanes.each { |l| matched[l[:token]] = true }

        header = "#{Output.cyan(abbr_path(wt[:path]))}  [#{wt[:branch] || Output.dim('(detached)')}]"
        header += "  #{Output.yellow("⚠ #{wt_lanes.size} lanes share this working tree")}" if wt_lanes.size >= 2
        puts header

        if wt_lanes.empty?
          shared = Repo.active_epic(wt[:path])
          puts "  #{Output.dim("○ no active lane  (#{shared ? "active epic: #{shared}" : 'no active epic'})")}"
        else
          wt_lanes.each { |l| puts worktree_lane_line(l, my_token) }
        end
        puts
      end

      orphans = lanes.reject { |l| matched[l[:token]] }
      return if orphans.empty?

      puts Output.dim('Orphan lanes (no matching git worktree):')
      orphans.each { |l| puts worktree_lane_line(l, my_token) }
      puts
    end

    # One lane row: live/dead glyph, epic/story, owner token, age, ← current.
    def self.worktree_lane_line(lane, my_token)
      live = case Repo.lane_liveness(lane[:token])
             when :live then Output.green('● live')
             when :dead then Output.red('✗ dead')
             else            Output.dim('? unknown')
             end
      you = lane[:token] == my_token ? "  #{Output.cyan('← current')}" : ''
      "  #{live}  #{lane[:epic]} / #{lane[:story]}  #{Output.dim(lane[:token])}  " \
        "#{Output.dim(Output.time_ago(lane[:age]))}#{you}"
    end

    def self.abbr_path(path)
      path.sub(/\A#{Regexp.escape(Dir.home)}(?=\/)/, '~')
    end

    def self.pluralize(n, word)
      "#{n} #{word}#{'s' unless n == 1}"
    end

    # ── web ────────────────────────────────────────────────────────────────
    # `tyrion web` / `tyrion dashboard` — launch the Sinatra field-ops UI.
    # Default action is idempotent ("make sure it's up, take me there") so
    # running it twice never interrupts a session in progress; `restart`
    # is the explicit, deliberate action for picking up code changes.

    def self.cmd_web(args, store)
      sub     = args.first && !args.first.start_with?('--') ? args.shift : 'open'
      port    = (extract_flag_value(args, '--port') || WebServer::DEFAULT_PORT).to_i
      open    = !args.delete('--no-open')
      project = Repo.active_project || 'tyrion'

      case sub
      when 'open', 'start' then web_ensure_running(port, project, open: open)
      when 'ambient'       then web_ambient(port, project, open: open)
      when 'restart'       then web_restart(port, project, open: open)
      when 'stop'          then web_stop(port)
      when 'status'        then web_print_status(port)
      else
        die "Usage: tyrion web [open|ambient|restart|stop|status] [--port N] [--no-open]"
      end
    end

    def self.web_ensure_running(port, project, open:)
      unless WebServer.web_root
        die "Web UI not found — web/app.rb isn't packaged in this install. " \
            "Run from a tyrion source checkout."
      end

      if WebServer.running_pid(port) && WebServer.healthy?(port)
        puts "#{Output.green('✓')} tyrion web already running  #{Output.dim(WebServer.url(port))}"
      else
        WebServer.stop(port) if WebServer.running_pid(port)  # reap unresponsive instance first
        web_boot(port, project)
      end
      WebServer.open_browser(port) if open
    end

    # `tyrion web ambient` — same server, opened straight to the project-scoped
    # ambient page in a narrow app-mode window meant to sit in a split pane.
    # App mode is pure convenience: the URL is always printed, so pinning any
    # browser tab to it by hand works just as well. Unlike the rest of `web`,
    # this one isn't idempotent on the window — running it twice opens a second
    # app window (the server side is still reused).
    def self.web_ambient(port, project, open:)
      web_ensure_running(port, project, open: false)
      target = WebServer.ambient_url(port, project)
      puts "  ambient: #{target}"
      puts Output.dim('  (pin any browser tab to this URL in a split pane)')
      return unless open

      return if WebServer.open_app_window(target)

      puts Output.dim('  no Chrome-family browser for app mode — opening a normal window')
      WebServer.open_url(target)
    end

    def self.web_restart(port, project, open:)
      puts Output.dim("Restarting tyrion web…")
      WebServer.stop(port)
      web_boot(port, project)
      WebServer.open_browser(port) if open
    end

    def self.web_boot(port, project)
      print "Starting tyrion web (project=#{project}, port=#{port})… "
      if WebServer.start(port: port, project: project)
        puts Output.green('ready')
        puts "  #{WebServer.url(port)}"
      else
        puts Output.red('failed')
        die "tyrion web did not come up — check #{WebServer.log_file(port)}"
      end
    end

    def self.web_stop(port)
      if WebServer.stop(port)
        puts "#{Output.green('✓')} stopped tyrion web (port #{port})"
      else
        puts Output.dim("tyrion web is not running (port #{port})")
      end
    end

    def self.web_print_status(port)
      pid = WebServer.running_pid(port)
      if pid && WebServer.healthy?(port)
        puts "#{Output.green('●')} running   pid=#{pid}  #{WebServer.url(port)}"
      elsif pid
        puts "#{Output.yellow('●')} unresponsive  pid=#{pid}  #{WebServer.url(port)}  " \
             "(log: #{WebServer.log_file(port)})"
      else
        puts "#{Output.dim('○')} not running  (port #{port})"
      end
    end

    # ── assign ─────────────────────────────────────────────────────────────

    def self.cmd_assign(args, store)
      slug = args.shift
      lane = args.shift
      die "Usage: tyrion assign <slug> <lane>" unless slug && lane

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug} in epic #{epic['slug']}" unless story
      die "Story is not pending (status: #{story['status']})" unless story['status'] == 'pending'

      store.assign_story(story['id'], lane)
      puts "Assigned: #{slug} → assigned:#{lane}"
      puts "Status: #{Output.dim('pending')} (agent running tyrion start #{slug} will adopt it)"
    rescue RuntimeError => e
      die e.message
    end

    # ── claim ──────────────────────────────────────────────────────────────
    # Lead pre-claims a story for a lane that does not exist yet.
    # tyrion claim <slug> --as <label> writes claimed_by="assigned:<label>";
    # the story stays pending until the adopting lane (TYRION_LANE=<label>) starts it.

    def self.cmd_claim(args, store)
      label = extract_flag_value(args, '--as')
      slug  = args.shift
      die "Usage: tyrion claim <slug> --as <label>" unless slug && presence(label)

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug} in epic #{epic['slug']}" unless story
      die "Story is not pending (status: #{story['status']})" unless story['status'] == 'pending'

      store.assign_story(story['id'], label)
      puts "Claimed: #{slug} → assigned:#{label}"
      puts "Status: #{Output.dim('pending')} (agent running with TYRION_LANE=#{label} will adopt it)"
    rescue RuntimeError => e
      die e.message
    end

    # ── dispatch ───────────────────────────────────────────────────────────
    # Mechanically claims a story on behalf of a named lane by starting it
    # immediately (in_progress) and recording an initial context event. The
    # subagent that later runs `tyrion start <slug>` adopts ownership by
    # re-stamping claimed_by to its real lane token — no story is ever
    # "started" without a ledger entry at the moment of dispatch.

    def self.cmd_dispatch(args, store)
      label   = extract_flag_value(args, '--to')
      slug    = args.shift
      context = args.join(' ')
      die "Usage: tyrion dispatch <slug> --to <label> [initial context]" unless slug && presence(label)
      context = "dispatched for implementation" if context.empty?

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug} in epic #{epic['slug']}" unless story

      store.dispatch_story(story['id'], label, context)
      puts "Dispatched: #{slug} → dispatched:#{label}"
      puts "Status: #{Output.yellow('in_progress')} (subagent on TYRION_LANE=#{label} adopts on start)"
      puts "Context: #{context}"
    rescue RuntimeError => e
      die e.message
    end

    # ── violations ─────────────────────────────────────────────────────────
    # Lists in_progress stories with no claimed_by — unclaimed-but-in-flight,
    # which is a protocol violation when dispatch is the expected path.

    def self.cmd_violations(args, store)
      _project, epic = resolve_project_epic(store)
      stories = store.violations_in_progress(epic['id'])
      if stories.empty?
        puts Output.green("No dispatch violations — all in_progress stories are claimed.")
        return
      end
      puts Output.red("#{stories.length} unclaimed in_progress #{stories.length == 1 ? 'story' : 'stories'} (protocol violation):")
      stories.each do |s|
        age = Output.stale_label(s['started_at'])
        puts "  #{Output.red('⊘')} #{s['slug'].ljust(30)}  started #{age}"
        puts "    Fix: tyrion dispatch #{s['slug']} --to <lane>  (if mid-flight)"
        puts "    Fix: tyrion unstart #{s['slug']}               (if not actually started)"
      end
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

      prior_status = story['status']
      store.block_story(story['id'], blocked_on: reason, blocked_on_discovery: disc_id)

      body = "blocked: #{reason}"
      body += " [#{disc_id}]" if disc_id
      metadata = { 'action' => 'block', 'blocked_on' => reason, 'blocked_on_discovery' => disc_id, 'prior_status' => prior_status }.compact
      store.add_note(story['id'], 'blocker', body, metadata: JSON.dump(metadata))

      puts "#{Output.red('Blocked:')} #{slug} — #{story['title']}"
      puts "Blocked on: #{reason}"
      puts "Discovery:  #{disc_id}" if disc_id
    rescue RuntimeError => e
      die e.message
    end

    # ── unblock ────────────────────────────────────────────────────────────

    def self.cmd_unblock(args, store)
      resume_idx = args.index('--resume')
      resume = !resume_idx.nil?
      args.delete_at(resume_idx) if resume_idx

      slug = args.shift
      die "Usage: tyrion unblock <slug> [--resume]" unless slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      prior_reason = story['blocked_on']
      updated = store.unblock_story(story['id'], resume: resume)

      body = presence(prior_reason) ? "unblocked (was: #{prior_reason})" : 'unblocked'
      metadata = { 'action' => 'unblock', 'blocked_on' => prior_reason, 'restored_status' => updated['status'] }.compact
      store.add_note(story['id'], 'blocker', body, metadata: JSON.dump(metadata))

      puts "#{Output.green('Unblocked:')} #{slug} — #{story['title']}"
      puts "Status: #{Output.dim(updated['status'])}"
    rescue RuntimeError => e
      die e.message
    end

    # ── claim-next ─────────────────────────────────────────────────────────

    def self.cmd_claim_next(args, store)
      _project, epic = resolve_project_epic(store)
      warn_if_epic_waiting(store, epic)
      if epic_drained?(store, epic['id'])
        print_next_epic_suggestion(store, epic)
        return
      end
      story = resolve_my_story(store, epic, explicit_slug: nil, claim_if_none: true)
      die "No pending stories in this epic" unless story
      puts "Claimed: #{story['slug']} — #{story['title']}"
      puts "Status: #{Output.yellow('in_progress')}"
    rescue RuntimeError => e
      die e.message
    end

    # ── pocket ─────────────────────────────────────────────────────────────

    def self.cmd_pocket(args, store)
      _project, epic = resolve_project_epic(store)

      story = resolve_my_story(store, epic, explicit_slug: nil, claim_if_none: false)
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

    # ── prime ─────────────────────────────────────────────────────────────
    # Tiered, lane-aware briefing for SessionStart/PreCompact hooks. No flag
    # distinguishes the two — the tier matrix is state-driven. Read-only and
    # fail-open: any error, missing/corrupt DB, or timeout exits 0 with a
    # stderr warning rather than blocking session start or compaction.

    def self.cmd_prime(_args)
      root = Repo.worktree_root
      return unless File.exist?(File.join(root, Repo::MARKER))

      begin
        Timeout.timeout(2) { prime_render }
      rescue StandardError => e
        $stderr.puts "tyrion prime: warning: #{e.message}"
      end
    end

    def self.prime_render
      # Re-read ENV at call time (not Store::DB_PATH, frozen at class-load) so a
      # runtime-set TYRION_DB_PATH — tests, hooks — wins.
      store = Store.new(db_path: ENV.fetch('TYRION_DB_PATH', Store::DB_PATH))

      project_slug = Repo.active_project
      return unless project_slug
      project = store.find_project_by_slug(project_slug)
      return unless project

      token     = current_lane_token
      epic_slug = Repo.active_epic(token: token)
      return unless epic_slug
      epic = store.find_epic(project['id'], epic_slug)
      return unless epic

      # Counted up front, before any line is printed: if this read is the thing
      # that raises or blows the 2s budget, the whole briefing is suppressed
      # (fail-open as everywhere else here) rather than truncated mid-render
      # with its Rules block missing.
      open_marks = store.count_open_marks(project['id'])

      story = prime_story_for(store, epic, token)
      story ? print_prime_tier2(epic, story, store, open_marks) : print_prime_tier1(project, epic, store, open_marks)
    end
    private_class_method :prime_render

    # Read-only story lookup for prime — deliberately NOT resolve_my_story,
    # which can write (pre-claim adopt, claim-next). Rung 2 (own lane) or the
    # legacy sole-unclaimed lookup only; never consults the .tyrion/active-story
    # pin and never counts an "assigned:<lane>" placeholder (status != in_progress).
    def self.prime_story_for(store, epic, token)
      token ? store.in_progress_story_for(epic['id'], token) : store.story_in_progress_unclaimed(epic['id'])
    end
    private_class_method :prime_story_for

    def self.print_prime_tier1(project, epic, store, open_marks)
      north_star   = project['about_md']&.lines&.first&.strip&.sub(/^#+\s*/, '')
      epic_stories = store.stories_for_epic(epic['id'])
      done_n       = epic_stories.count { |s| s['status'] == 'done' }
      graph        = store.epic_graph(epic['project_id'])
      waiting      = store.unmet_prereqs(epic, graph)

      puts north_star if presence(north_star)
      # Parent crumb here (not just in Tier 2) because a lane can land on
      # Tier 1 with no story claimed yet — this is the surface most likely to
      # be the very first thing an agent reads after /clear.
      puts "epic: #{epic_ancestor_crumb(store, epic, graph)}#{epic['slug']} (#{done_n}/#{epic_stories.length})"
      if waiting.empty?
        puts "next: tyrion claim-next"
      else
        puts "epic waiting on: #{waiting.map { |u| "#{u[:slug]} (#{u[:reason]})" }.join(', ')}"
      end
      puts "full context: tyrion resume"
      print_prime_marks_line(open_marks)
      puts
      puts "Rules:"
      puts "  - claim before code (tyrion claim-next)"
      puts "  - evidence via tyrion note/check, not ad hoc"
      puts PRIME_FILING_RULE
    end
    private_class_method :print_prime_tier1

    def self.print_prime_tier2(epic, story, store, open_marks)
      stale_suffix = Output.stale?(story['last_note_at']) ? " #{Output.stale_label(story['last_note_at'])}" : ''
      crumb        = epic_ancestor_crumb(store, epic, store.epic_graph(epic['project_id']))

      puts "epic: #{crumb}#{epic['slug']}"
      puts "story: #{story['slug']}#{stale_suffix}"
      puts "next: #{story['next_action']}" if presence(story['next_action'])
      puts "mode: dark_factory — orchestrate auto-advances waves; implement continues past done" if Output.dark_factory?(epic)

      print_prime_marks_line(open_marks)

      unmet = store.criteria_for_story(story['id']).reject { |c| c['status'] == 'met' }
      unmet.each { |c| puts "[ ] #{c['keyword']} #{c['text']}" }

      puts
      puts "Rules:"
      puts "  - claim before code"
      puts "  - evidence via tyrion note/check, not ad hoc"
      puts PRIME_FILING_RULE
      puts "  - tyrion resume #{story['slug']} · /tyrion-implement #{story['slug']}"
    end
    private_class_method :print_prime_tier2

    # Same rule line in both tiers — the nudge must not drift between them.
    PRIME_FILING_RULE = '  - file what you notice (tyrion mark --auto); search before filing'

    # One status line, only when there is something to dedupe against.
    def self.print_prime_marks_line(open_marks)
      return if open_marks.zero?

      puts %(marks: #{open_marks} open — check first: tyrion discovery search "<terms>")
    end
    private_class_method :print_prime_marks_line

    # ── mark ──────────────────────────────────────────────────────────────

    # Who filed this discovery. Explicit flag, never inferred: an in-progress story does
    # not mean an agent is the one at the keyboard, and a silent misclassification defeats
    # the whole point of the origin column. Mutates args — the flag is consumed so it can
    # never be mistaken for a positional argument (a mark's description, a spike's question).
    # `default:` is what an omitted flag means: 'human' when the command *creates* the row,
    # nil when it *updates* one (nil preserves the stored origin — see Store#close_spike).
    def self.consume_auto_flag(args, default: 'human')
      args.delete('--auto') ? 'agent' : default
    end

    def self.cmd_mark(args, store)
      return puts "No active project." unless Repo.active_project

      origin        = consume_auto_flag(args)
      headline      = extract_flag_value(args, '--headline')
      project, epic = resolve_project_epic(store, require_epic: false)
      # Read-only lane lookup, never resolve_my_story: filing a mark must not
      # claim, adopt, or pin a story as a side effect of noticing something.
      # No epic (or no story on this lane) is a normal outcome, not an error —
      # the mark files with the provenance left nil rather than guessing.
      story = epic && prime_story_for(store, epic, current_lane_token)

      disc = store.create_discovery(
        project_id:      project['id'],
        epic_id:         epic && epic['id'],
        source_story_id: story && story['id'],
        status:          'mark',
        question:        args.first,
        origin:          origin,
        headline:        headline,
        git_context:     Repo.git_context_json
      )
      puts "[mark] #{disc['id']}#{mark_budget_suffix(store, story)}"
    end

    # The running per-story count is how an implementing agent self-enforces its
    # mark budget — the implementing-agent skill forbids it from querying SQLite
    # directly, so if this line doesn't say it, the agent cannot know it.
    def self.mark_budget_suffix(store, story)
      return '' unless story

      " (#{ordinal(store.count_marks_from_story(story['id']))} mark filed this story)"
    end

    def self.ordinal(num)
      suffix = if (11..13).cover?(num % 100)
                 'th'
               else
                 { 1 => 'st', 2 => 'nd', 3 => 'rd' }.fetch(num % 10, 'th')
               end
      "#{num}#{suffix}"
    end

    # ── discover ──────────────────────────────────────────────────────────

    # Two forms sharing one verb, because they answer the same question at
    # different times: with a mark-id it upgrades that mark non-interactively
    # (an agent that already did the investigating and must not hang on a
    # prompt); bare, it runs the original three-prompt organic capture.
    # The positional id is the only discriminator — flags without an id fall
    # through to the interactive path exactly as they did before.
    def self.cmd_discover(args, store, input: $stdin, output: $stdout)
      # Consumed first so the flag can never be read as the positional mark-id.
      # nil (flag absent) means "create as human" below and "leave origin alone"
      # on the upgrade path — the two defaults consume_auto_flag documents.
      origin   = consume_auto_flag(args, default: nil)
      question = extract_flag_value(args, '--question')
      finding  = extract_flag_value(args, '--finding')
      headline = extract_flag_value(args, '--headline')

      if (disc_id = args.first)
        return cmd_discover_upgrade(disc_id, store, question: question, finding: finding,
                                                    origin: origin, headline: headline, output: output)
      end

      origin ||= 'human'
      project, = resolve_project_epic(store, require_epic: false)

      question = prompt(input, output, "What were you trying to do? ")
      finding  = prompt(input, output, "What did you find? ")

      disc = store.create_discovery(
        project_id:  project['id'],
        status:      'findings_ready',
        question:    question,
        finding:     finding,
        origin:      origin,
        headline:    headline,
        git_context: Repo.git_context_json
      )
      output.puts "[findings_ready] #{disc['id']}"

      response = prompt(input, output, "Spec this out now? [y/later/no] ").downcase
      output.puts "tyrion spike promote #{disc['id']}" if response == 'y'
    end

    # Non-interactive: no prompts, no fallback question. --finding is what makes
    # a mark a finding, so its absence is a usage error rather than a prompt.
    def self.cmd_discover_upgrade(disc_id, store, question:, finding:, origin:, output: $stdout, headline: nil)
      die "Usage: tyrion discover <disc-id> --finding \"...\" [--question \"...\"] [--headline \"...\"] [--auto]" unless presence(finding)

      project = resolve_project(store)
      disc    = store.find_discovery(disc_id)
      # A mark belonging to another project is "not found" from here — project
      # scope is the boundary, and leaking its existence would be a false lead.
      die "Discovery #{disc_id} not found" unless disc && disc['project_id'] == project['id']

      disc = store.upgrade_mark(disc_id, finding: finding, question: presence(question), origin: origin,
                                          headline: presence(headline))
      output.puts "[findings_ready] #{disc['id']}"
    rescue RuntimeError => e
      die e.message
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
      when 'list'     then cmd_discovery_list(args, store)
      when 'show'     then cmd_discovery_show(args, store)
      when 'defer'    then cmd_discovery_defer(args, store)
      when 'search'   then cmd_discovery_search(args, store)
      when 'headline' then cmd_discovery_headline(args, store)
      else
        die "Usage: tyrion discovery [list|show|defer|search|headline]"
      end
    end

    # Standalone update path — lets a headline be sharpened later without also
    # needing a status transition (mark/discover already accept --headline at
    # creation/upgrade time for that case).
    def self.cmd_discovery_headline(args, store)
      disc_id  = args.shift
      headline = presence(args.join(' ').strip)
      die "Usage: tyrion discovery headline <disc-id> \"<text>\"" unless disc_id && headline

      project = resolve_project(store)
      disc    = store.find_discovery(disc_id)
      die "Discovery #{disc_id} not found" unless disc && disc['project_id'] == project['id']

      disc = store.set_headline(disc_id, headline)
      puts "Headline set: #{disc['id']}  #{disc['headline']}"
    end

    def self.cmd_discovery_list(args, store)
      status_filter = resolve_discovery_status(args)
      project       = resolve_project(store)
      discs         = store.list_discoveries(project_id: project['id'], status: status_filter)

      return puts "(no discoveries)" if discs.empty?

      discs.each { |d| puts "#{d['id']}  [#{d['status']}]  #{Output.origin_tag(d['origin'])}  #{Output.discovery_glance_text(d)}" }
    end

    SEARCH_SNIPPET_WIDTH = 60

    # Dedup check before filing a new mark: "is this already tracked?". Silent
    # when nothing matches (exit 0, no output) so an agent can run it mid-task
    # without adding noise — the answer that matters is the one with hits.
    def self.cmd_discovery_search(args, store)
      status_filter = resolve_discovery_status(args)
      args.slice!(args.index('--status'), 2) if args.index('--status')
      term = args.join(' ')
      die 'Usage: tyrion discovery search "<term>" [--status <alias>]' if term.strip.empty?

      project = resolve_project(store)
      discs   = store.search_discoveries(project_id: project['id'], term: term, status: status_filter)

      discs.each do |d|
        text = presence(d['headline']) || presence(d['question']) || presence(d['finding']) || ''
        text = "#{text[0, SEARCH_SNIPPET_WIDTH - 1]}…" if text.length > SEARCH_SNIPPET_WIDTH
        puts "#{d['id']}  [#{d['status']}]  #{text}  (#{Output.time_ago(d['created_at'])})"
      end
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

      puts "#{disc['id']}  [#{disc['status']}]  #{Output.origin_tag(disc['origin'])}"
      puts "Verdict:        #{disc['verdict'] || '(unscored)'}"
      puts "Headline:       #{disc['headline']}" if disc['headline']
      puts "Question:       #{disc['question'] || '—'}"
      puts "Finding:        #{disc['finding'] || '—'}"
      puts "Confidence:     #{disc['confidence'] || '—'}"
      puts "Recommendation: #{disc['recommendation'] || '—'}"
      puts "Hypothesis:     #{disc['hypothesis'] || '—'}" if disc['hypothesis']
      puts "Exit criteria:  #{disc['exit_criteria'] || '—'}" if disc['exit_criteria']
      puts "Defer reason:   #{disc['defer_reason']}" if disc['defer_reason']
    end

    def self.cmd_discovery_defer(args, store)
      disc_id = args.shift
      die "Usage: tyrion discovery defer <disc-id> [\"why\"]" unless disc_id
      reason = presence(args.join(' ').strip)

      disc = store.find_discovery(disc_id)
      die "Discovery #{disc_id} not found" unless disc

      # Repeat defer keeps the reason already on record — show which one won.
      return puts "already deferred, nothing to do: #{defer_summary(disc)}" if disc['status'] == 'deferred'

      puts "[deferred] #{defer_summary(store.defer_discovery(disc_id, reason: reason))}"
    rescue RuntimeError => e
      die e.message
    end

    def self.defer_summary(disc)
      [disc['id'], presence(disc['defer_reason'])].compact.join(' — ')
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
        $stderr.puts "Usage: tyrion spike start \"your question\" [--auto]\n       tyrion spike done [--auto]\n       tyrion spike promote <disc-id>"
        exit 1
      end
    end

    def self.cmd_spike_start(args, store, input: $stdin, output: $stdout)
      origin   = consume_auto_flag(args)
      question = args.first&.strip
      die "Usage: tyrion spike start \"your question\" [--auto]" if question.nil? || question.empty?

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
        origin:        origin,
        git_context:   Repo.git_context_json
      )
      output.puts "[active_spike] #{disc['id']}"
    end

    # confirmed: hypothesis held. falsified: it didn't, no alternative found. falsified_alternative:
    # it didn't, but the spike surfaced what's true instead. partial: some held, some didn't.
    VALID_VERDICTS = %w[confirmed falsified falsified_alternative partial].freeze

    def self.cmd_spike_done(args, store, input: $stdin, output: $stdout)
      origin  = consume_auto_flag(args, default: nil)
      verdict = extract_flag_value(args, '--verdict')
      if verdict && !VALID_VERDICTS.include?(verdict)
        die "Unknown verdict '#{verdict}'. Valid: #{VALID_VERDICTS.join(', ')}"
      end

      project, = resolve_project_epic(store, require_epic: false)

      spike = store.active_spike_for(project['id'])
      die "No active spike. Start one: tyrion spike start \"your question\"" unless spike

      finding        = prompt(input, output, "Key finding (one paragraph max): ")
      confidence     = prompt_confidence(input, output)
      recommendation = prompt(input, output, "Recommendation: ")

      disc = store.close_spike(spike['id'], finding: presence(finding), confidence: confidence,
                                            recommendation: presence(recommendation), origin: origin,
                                            verdict: verdict)
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
      project, epic = resolve_project_epic(store)

      story = if args.first && !args.first.start_with?('--')
        resolve_my_story(store, epic, explicit_slug: args.first, claim_if_none: false)
      else
        s = resolve_my_story(store, epic, explicit_slug: nil, claim_if_none: false)
        unless s
          # Self-guiding empty-state: show pending queue instead of a bare error
          pending = store.stories_for_epic(epic['id']).select { |st| st['status'] == 'pending' }
          $stderr.puts "No story is in progress in epic #{epic['slug']}."
          if pending.any?
            $stderr.puts ""
            $stderr.puts "Next pending stories:"
            pending.first(5).each { |st| $stderr.puts "  #{st['slug']}" }
            $stderr.puts ""
            $stderr.puts "Use: tyrion start #{pending.first['slug']}"
          else
            $stderr.puts "Use: tyrion start <slug>  or  tyrion list  to see all stories."
          end
          exit 1
        end
        s
      end

      stale_flag = if Output.stale?(story['last_note_at'])
        " #{Output.red(Output.stale_label(story['last_note_at']))}"
      else
        ''
      end

      # ── Big-picture header ──────────────────────────────────────────────
      north_star = project['about_md']&.lines&.first&.strip&.sub(/^#+\s*/, '')
      puts "#{Output.bold('Project:')} #{project['name']}"
      puts "         #{Output.dim(north_star)}" if presence(north_star)

      epic_stories = store.stories_for_epic(epic['id'])
      done_n  = epic_stories.count { |s| s['status'] == 'done' }
      intent_snippet = epic['intent'] ? " — #{epic['intent'][0, 60]}#{'…' if epic['intent'].length > 60}" : ''
      puts "#{Output.bold('Epic:')}    #{epic['name']} · #{done_n}/#{epic_stories.length} done#{intent_snippet}"

      all_epics   = store.list_epics(project['id'])
      graph       = store.epic_graph(project['id'])
      open_parts  = all_epics.reject { |e| e['id'] == epic['id'] }.filter_map do |e|
        e_stories = store.stories_for_epic(e['id'])
        pending_n = e_stories.count { |s| %w[pending in_progress blocked].include?(s['status']) }
        next nil unless pending_n > 0

        waiting = e['status'] == 'active' && e['archived_at'].nil? && !store.unmet_prereqs(e, graph).empty?
        "#{e['slug']} (#{pending_n})#{waiting ? " #{Output.dim('waiting')}" : ''}"
      end
      puts "#{Output.dim('Open:')}    #{open_parts.join(' · ')}" if open_parts.any?
      puts

      puts "#{Output.bold('Resuming:')} #{story['slug']} — #{story['title']} [#{Output.status_label(story['status'])}]#{stale_flag}"
      puts

      root   = Repo.worktree_root
      branch = Repo.git_branch
      dirty  = Repo.dirty_count
      puts "Branch:   #{branch}"
      puts "Worktree: #{root.sub(Dir.home, '~')}"
      puts "Dirty:    #{dirty > 0 ? Output.yellow("#{dirty} files") : Output.green('clean')}"

      if (drift_path = drift_changed_path(epic, root))
        puts
        print_drift_warning(drift_path)
      end

      lessons = lessons_for_scope(store, project_id: epic['project_id'], epic_id: epic['id'], story_id: story['id'])
      unless lessons.empty?
        puts
        puts Output.bold("Lessons:")
        lessons.each { |l| puts "  📎 [#{l['trigger']}] #{l['text']}" }
      end

      print_known_section(store, epic['project_id'])

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

      print_gates_section(store, story['id'])

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

    VALID_NOTE_KINDS = %w[plan progress decision blocker test handoff recovery session followup observation].freeze

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

    # ── gate ───────────────────────────────────────────────────────────────
    # Records a pass/fail gate result (pre-push, code-review, spec-review, codex-vet,
    # uat, …) as a kind='gate' story note. The only writer of gate notes — do NOT
    # route these through `tyrion note`.

    def self.cmd_gate(args, store)
      detail = extract_flag_value(args, '--detail')
      meta   = extract_flag_value(args, '--meta')
      slug, gate_name, result = args
      die "Usage: tyrion gate <slug> <gate-name> pass|fail [--detail \"...\"] [--meta '<json>']" unless slug && gate_name && result
      die "Invalid result: #{result}. Must be pass|fail." unless %w[pass fail].include?(result)

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      body = "#{gate_name}: #{result.upcase}"
      body += " — #{detail}" if presence(detail)

      metadata = { 'gate' => gate_name, 'result' => result }
      metadata['detail'] = detail if presence(detail)
      if presence(meta)
        begin
          metadata.merge!(JSON.parse(meta))
        rescue JSON::ParserError
          die "--meta must be valid JSON: #{meta}"
        end
      end

      store.add_note(story['id'], 'gate', body, metadata: JSON.dump(metadata))

      label = "#{gate_name} #{result.upcase} — #{slug}"
      puts "Gate recorded: #{result == 'pass' ? Output.green(label) : Output.red(label)}"
    end

    # ── commits ──────────────────────────────────────────────────────────────
    # Captures the story's commit record as a kind='commit' story note. Also runs
    # automatically at `tyrion done` (see cmd_done). Append-only, like gates.

    def self.cmd_commits(args, store)
      slug = args.shift
      die "Usage: tyrion commits <slug>" unless slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      since = commit_capture_since(story)
      die "Cannot capture commits: #{slug} has no started_at, claimed_at, or created_at timestamp" unless since

      count = write_commit_note(store, story, since)
      die "Cannot capture commits: git is unavailable in this worktree" if count.nil?

      puts "Commits recorded: #{count.zero? ? 'none' : count} — #{slug}"
    end

    # Timestamp a commit capture measures from — started_at wins, then claimed_at,
    # then created_at. nil only if the story somehow has none.
    def self.commit_capture_since(story)
      presence(story['started_at']) || presence(story['claimed_at']) || presence(story['created_at'])
    end

    # Writes one kind='commit' note listing commits since `since`. Returns the
    # commit count, or nil if git is unavailable (Repo.commits_since nil/raised).
    # Raise-free so callers (e.g. cmd_done) can capture opportunistically.
    def self.write_commit_note(store, story, since)
      commits = begin
        Repo.commits_since(since)
      rescue StandardError
        nil
      end
      return nil if commits.nil?

      sha_of = ->(line) { line.split(' ', 2).first }

      # In a shared repo, commits_since also returns sibling lanes' commits. Drop any
      # SHA already recorded in another story's commit note so it isn't double-attributed
      # (dogfood 2026-07-10 finding 5). Raise-free: a query hiccup just skips the filter.
      claimed = begin
        store.commit_shas_in_other_stories(story['id'])
      rescue StandardError
        []
      end
      commits = commits.reject { |line| claimed.include?(sha_of[line]) }

      if commits.empty?
        body = 'no commits — no changes required'
        metadata = { 'shas' => [], 'count' => 0 }
      else
        shas = commits.map(&sha_of)
        body = (["commits since #{since}:"] + commits).join("\n")
        # Shared-branch honesty (dogfood 2026-07-10 run-3): commits_since sweeps
        # in siblings' in-flight commits, and the dedup above only drops SHAs a
        # sibling has ALREADY recorded — a not-yet-closed sibling's commits still
        # land here. When other stories in this project are in_progress at capture
        # time, caveat the list. Raise-free: a query hiccup skips the caveat.
        if (caveat = shared_branch_caveat(store, story))
          body = "#{body}\n#{caveat}"
        end
        metadata = { 'shas' => shas, 'count' => shas.length }
      end

      store.add_note(story['id'], 'commit', body, metadata: JSON.dump(metadata))
      commits.length
    end

    # Caveat line for a commit note captured while sibling stories are live on the
    # same branch, or nil when this story is the sole in_progress story in its
    # project. Byte-identical-to-legacy path is nil (no siblings). Raise-free.
    def self.shared_branch_caveat(store, story)
      n = begin
        store.concurrent_in_progress_count(story['id'])
      rescue StandardError
        0
      end
      return nil if n.nil? || n.zero?

      noun = n == 1 ? 'story' : 'stories'
      "⚠ shared-branch capture: #{n} concurrent in_progress #{noun} — some commits may belong to another lane"
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

    # ── reconcile ──────────────────────────────────────────────────────────

    def self.parse_reconcile_flags(args)
      flags = { context: nil, next_action: nil, note: nil, checks: [] }
      i = 0
      while i < args.length
        case args[i]
        when '--context'
          flags[:context] = args[i + 1]
          i += 2
        when '--next'
          flags[:next_action] = args[i + 1]
          i += 2
        when '--note'
          flags[:note] = args[i + 1]
          i += 2
        when '--check'
          pos      = args[i + 1]
          evidence = args[i + 2]
          die "Usage: --check <n> \"evidence\"" unless pos && evidence
          flags[:checks] << [pos, evidence]
          i += 3
        else
          i += 1
        end
      end
      flags
    end

    def self.cmd_reconcile(args, store, input: $stdin, output: $stdout)
      slug = args.shift
      die "Usage: tyrion reconcile <slug> [--context TEXT] [--next TEXT] [--note TEXT] [--check <n> \"evidence\"]" unless slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      flags     = parse_reconcile_flags(args)
      ctx_text  = flags[:context]     || prompt(input, output, "Current context: ")
      next_text = flags[:next_action] || prompt(input, output, "Next action: ")
      note_text = flags[:note]        || prompt(input, output, "Decision note: ")
      die "A decision note is required." unless presence(note_text)
      checks = flags[:checks]

      store.reconcile_story(story['id'], context: ctx_text, next_action: next_text, note: note_text, checks: checks)

      output.puts "Reconciled #{slug}"
      output.puts "  context updated"     if presence(ctx_text)
      output.puts "  next action updated" if presence(next_text)
      output.puts "  note added (decision)"
      checks.each { |pos, _ev| output.puts "  criterion #{pos} marked met" }
    rescue RuntimeError => e
      die e.message
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
      all_flag = args.delete('--all')
      position = args.shift unless all_flag
      evidence = args.join(' ')

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug) if slug
      die "Story not found: #{slug}" if slug && !story

      # Self-guiding error: when slug is valid but position is missing, show criteria
      unless slug && (position || all_flag)
        if story
          criteria = store.criteria_for_story(story['id'])
          pending  = criteria.reject { |c| c['status'] == 'met' }
          $stderr.puts "Usage: tyrion check <slug> <position> \"evidence\""
          $stderr.puts "       tyrion check <slug> --all \"evidence\""
          $stderr.puts ""
          $stderr.puts "Criteria for #{slug}:"
          criteria.each { |c| $stderr.puts "  #{Output.criterion_icon(c['status'])} #{c['position']}. #{c['keyword'].ljust(5)} #{c['text']}" }
          $stderr.puts ""
          $stderr.puts "#{pending.length} pending — e.g.: tyrion check #{slug} #{pending.first['position']} \"evidence\"" if pending.any?
        else
          $stderr.puts "Usage: tyrion check <slug> <position> \"evidence\""
        end
        exit 1
      end

      if all_flag
        criteria = store.criteria_for_story(story['id'])
        pending  = criteria.reject { |c| c['status'] == 'met' }
        die "No pending criteria for #{slug}" if pending.empty?
        pending.each { |c| store.check_criterion(story['id'], c['position'], evidence) }
        puts "All #{pending.length} criteria marked met for #{slug}"
        puts "Evidence: #{evidence}" unless evidence.empty?
      else
        store.check_criterion(story['id'], position.to_i, evidence)
        puts "Criterion #{position} marked met for #{slug}"
        puts "Evidence: #{evidence}" unless evidence.empty?
      end
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

    def self.cmd_done(args, store, input: $stdin, output: $stdout)
      slug         = args.shift
      force        = args.delete('--force')
      from_checks  = args.delete('--from-checks')
      required_gates = extract_require_gates!(args)
      summary      = args.join(' ')

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug) if slug
      die "Story not found: #{slug}" if slug && !story

      # Self-guiding error: when no summary, show met criteria + pre-filled command
      unless slug && !summary.empty?
        if story
          criteria = store.criteria_for_story(story['id'])
          met      = criteria.select { |c| c['status'] == 'met' }
          pending  = criteria.reject { |c| c['status'] == 'met' }
          $stderr.puts "Usage: tyrion done <slug> \"completion summary\" [--force]"
          $stderr.puts ""
          if pending.empty? && criteria.any?
            $stderr.puts "All #{met.length} criteria are met. Provide a completion summary:"
            $stderr.puts "  tyrion done #{slug} \"...\""
          else
            $stderr.puts "Criteria (#{met.length}/#{criteria.length} met):"
            criteria.each { |c| $stderr.puts "  #{Output.criterion_icon(c['status'])} #{c['position']}. #{c['text']}" }
            $stderr.puts ""
            $stderr.puts "  tyrion done #{slug} \"...\" #{pending.any? ? '--force (unmet criteria exist)' : ''}"
          end
        else
          $stderr.puts "Usage: tyrion done <slug> \"completion summary\" [--force]"
        end
        exit 1
      end

      if from_checks
        criteria = store.criteria_for_story(story['id'])
        evidence = criteria.select { |c| c['status'] == 'met' && c['evidence'] && !c['evidence'].empty? }
                           .map { |c| "#{c['position']}. #{c['text']}: #{c['evidence']}" }.join('; ')
        summary = evidence.empty? ? summary : "#{summary} | Evidence: #{evidence}"
      end

      # Enforcement: never close over a failing gate. A gate whose latest result
      # is fail blocks the close unless --force, which records the override as a
      # force-close gate note so the bypass is itself traceable in the Gates section.
      failing = latest_failing_gates(store, story['id'])
      if failing.any?
        if force
          store.add_note(story['id'], 'gate', 'force-close: PASS',
                         metadata: JSON.dump('gate' => 'force-close', 'result' => 'pass',
                                             'detail' => "overrode failing: #{failing.join(', ')}"))
        else
          $stderr.puts "Refusing to close #{slug}: #{failing.length} gate(s) have a failing latest result:"
          failing.each { |name| $stderr.puts "  ✗ #{name}" }
          $stderr.puts ""
          $stderr.puts "Re-record the gate as pass, or override with:"
          $stderr.puts "  tyrion done #{slug} \"#{summary}\" --force"
          exit 1
        end
      end

      # Enforcement: --require-gates=<names> refuses the close unless each named
      # gate has at least one recorded gate note — gate coverage is otherwise
      # honor-system. The failing-gate refusal above already handles
      # present-but-failing gates; this catches gates never recorded at all.
      if required_gates.any?
        missing = required_gates - recorded_gate_names(store, story['id'])
        if missing.any?
          $stderr.puts "Refusing to close #{slug}: --require-gates names #{missing.length} gate(s) with no recorded note:"
          missing.each { |name| $stderr.puts "  ✗ #{name}" }
          $stderr.puts ""
          $stderr.puts "Record each with: tyrion gate #{slug} <name> pass|fail"
          exit 1
        end
      end

      # Auto-capture the commit record before sealing the story. Never let a git
      # hiccup block the close — write_commit_note is raise-free and returns nil
      # when git is unavailable, in which case we skip silently (with a note).
      # An existing commit note (e.g. a pre-merge branch-scoped `tyrion commits`
      # capture from a lane worktree) is authoritative — don't stack a second
      # note whose time window would sweep sibling merges and merge commits.
      has_commit_note = store.gate_notes_for_story(story['id']).any? { |n| n['kind'] == 'commit' }
      if !has_commit_note && (since = commit_capture_since(story))
        puts Output.dim("(commit capture skipped — git unavailable)") if write_commit_note(store, story, since).nil?
      end

      # Honesty warnings before sealing — both non-blocking (dogfood 2026-07-10):
      # a story closed with a dirty tree loses that uncommitted work from the
      # commit record, and a story closed with zero gates leaves no evidence trail.
      # Warn, never block — the close still succeeds.
      print_done_warnings(store, story, slug)

      store.complete_story(story['id'], summary, force: force)
      Repo.clear_active_story(token: current_lane_token)
      puts "#{Output.green('Done:')} #{slug} — #{story['title']}"

      maybe_prompt_epic_seal(store, epic, input: input, output: output)
      print_next_epic_suggestion(store, epic, output: output) if epic_drained?(store, epic['id'])
    rescue RuntimeError => e
      die e.message
    end

    # Non-blocking close warnings. Raise-free (Repo.dirty_count returns 0 when git
    # is unavailable), so a git hiccup never blocks the close. gate_notes_for_story
    # returns gate AND commit kinds — filter to kind='gate' so an auto-captured
    # commit note doesn't mask a genuinely gate-less close.
    def self.print_done_warnings(store, story, slug)
      puts Output.yellow('⚠  Uncommitted work in the working tree will be missing from the commit record.') if Repo.dirty_count.positive?

      ungated = store.gate_notes_for_story(story['id']).none? { |n| n['kind'] == 'gate' }
      puts Output.yellow("⚠  No gates recorded — record one with: tyrion gate #{slug} <name> pass|fail") if ungated
    end

    # After a story closes, offer to seal the epic when every story is done.
    # Prompt, don't silent-auto: sometimes the user wants to inspect first.
    def self.maybe_prompt_epic_seal(store, epic, input:, output:)
      return if epic['status'] == 'done'
      return unless store.all_stories_done?(epic['id'])

      count = store.stories_for_epic(epic['id']).length

      # Dark-factory / non-interactive: never block a close on a prompt.
      if input.equal?($stdin) && !$stdin.tty?
        output.puts "All #{count} stories done. Tip: run `tyrion epic complete #{epic['slug']}` when ready to seal."
        return
      end

      answer = prompt(input, output, "All #{count} stories done. Seal epic #{epic['slug']} as complete? [y/N] ")
      if answer.downcase == 'y'
        unlocked = seal_epic_and_report_unlocks(store, epic)
        output.puts "Epic #{epic['slug']} sealed as done."
        output.puts Output.dim("Tip: /tyrion-changelog #{epic['slug']} — add a changelog entry for this epic.")
        print_unlocked_epics(unlocked, output: output)
      else
        output.puts "Tip: run `tyrion epic complete #{epic['slug']}` when ready to seal."
      end
    end

    # True when the epic has no pending or in_progress stories left — the trigger
    # for surfacing a next-epic suggestion (done/abandoned/blocked don't count as
    # remaining work).
    def self.epic_drained?(store, epic_id)
      store.stories_for_epic(epic_id).none? { |s| %w[pending in_progress].include?(s['status']) }
    end

    # Renders the next-epic suggestion for a drained epic: the whole ready set
    # with actionable (pending-story) work, not one arbitrary pick — a waiting
    # epic (unmet prerequisite) is never among them, via Store#ready_epics. The
    # single-candidate case keeps the exact original wording so existing
    # callers/specs pinning it see no change.
    def self.print_next_epic_suggestion(store, epic, output: $stdout)
      graph = store.epic_graph(epic['project_id'])
      candidates = store.ready_epics(epic['project_id'], graph: graph)
                        .reject { |e| e['id'] == epic['id'] }
                        .select { |e| graph[:story_counts][e['id']]['pending'].positive? }

      case candidates.length
      when 0
        output.puts "All epics complete"
      when 1
        output.puts "Epic '#{epic['slug']}' complete. Next: tyrion epic activate #{candidates.first['slug']}"
      else
        output.puts "Epic '#{epic['slug']}' complete. Ready: #{candidates.map { |e| e['slug'] }.join(', ')} — tyrion epic activate <slug>"
      end
    end

    # Non-blocking warning for every path that lets an agent begin work in an
    # epic (tyrion start, claim-next, epic activate): if the epic itself is
    # waiting on an unmet prerequisite, name it and the escape hatch, but never
    # refuse — that hard-refuse treatment is reserved for a *blocked story*
    # (tyrion start's separate, stricter guard).
    def self.warn_if_epic_waiting(store, epic)
      graph = store.epic_graph(epic['project_id'])
      unmet = store.unmet_prereqs(epic, graph)
      return if unmet.empty?

      reasons = unmet.map { |u| "#{u[:slug]} (#{u[:reason]})" }.join(', ')
      puts Output.yellow("⚠  Epic '#{epic['slug']}' is waiting on: #{reasons}")
      puts Output.dim("   Escape hatch: tyrion epic depends rm #{epic['slug']} <dep-slug>")
    end

    # Seals epic through Store#seal_epic (which owns the container invariant
    # and the honesty rules) and reports which OTHER epics that seal just made
    # eligible, as a before/after diff of Store#ready_epics. The one
    # chokepoint all three seal call sites (cmd_epic_complete,
    # maybe_prompt_epic_seal, web POST /epic/:slug/seal) route through, so
    # none of them can seal by writing status directly and bypass either the
    # container invariant or this announcement.
    def self.seal_epic_and_report_unlocks(store, epic, force: false)
      before_ids = store.ready_epics(epic['project_id']).map { |e| e['id'] }
      store.seal_epic(epic['id'], force: force)
      store.ready_epics(epic['project_id']).reject { |e| before_ids.include?(e['id']) }
    end

    # Shared rendering for seal_epic_and_report_unlocks' diff — used by both
    # seal call sites that print to a Ruby IO (web's flash message builds its
    # own string instead).
    def self.print_unlocked_epics(unlocked, output: $stdout)
      return if unlocked.empty?
      output.puts "Unlocked: #{unlocked.map { |e| e['slug'] }.join(', ')} — now eligible (tyrion epic activate <slug>)"
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

    def self.print_drift_warning(drift_path, indent: '')
      puts Output.yellow("#{indent}⚠  feature file changed since import - criteria may be stale")
      puts Output.yellow("#{indent}   Re-import: tyrion import #{drift_path}")
    end

    # epic_id/story_id nil means "don't filter by that scope" — a lesson with a
    # nil epic_id or story_id is project-wide/epic-wide and always applies.
    def self.lessons_for_scope(store, project_id:, epic_id:, story_id: nil)
      store.list_lessons(project_id: project_id).select do |l|
        (l['epic_id'].nil? || l['epic_id'] == epic_id) &&
          (story_id.nil? || l['story_id'].nil? || l['story_id'] == story_id)
      end
    end

    # Returns the stored feature_source_path when the epic's file has changed since
    # import; nil when unchanged, missing, or untracked.
    def self.drift_changed_path(epic, root)
      return nil unless epic['feature_source_path'] && epic['feature_source_hash']

      stored_path = epic['feature_source_path']
      full_path   = File.absolute_path?(stored_path) ? stored_path : File.join(root, stored_path)
      return nil unless File.exist?(full_path)
      return nil if Digest::SHA256.file(full_path).hexdigest == epic['feature_source_hash']

      stored_path
    end

    # ── drift ──────────────────────────────────────────────────────────────

    def self.cmd_drift(args, store)
      project = resolve_project(store)
      epics   = store.list_epics(project['id'])
      tracked = epics.select { |e| e['feature_source_path'] && e['feature_source_hash'] }

      if tracked.empty?
        puts "No epics with tracked feature files."
        return
      end

      root = Repo.worktree_root
      tracked.each do |epic|
        stored_path = epic['feature_source_path']
        full_path   = File.absolute_path?(stored_path) ? stored_path : File.join(root, stored_path)
        slug        = epic['slug']

        if !File.exist?(full_path)
          puts "#{slug}: feature file missing"
        elsif Digest::SHA256.file(full_path).hexdigest != epic['feature_source_hash']
          puts "#{slug}: feature file changed - run tyrion import #{stored_path}"
        else
          puts "#{slug}: up to date"
        end
      end
    end

    # ── followup ───────────────────────────────────────────────────────────

    def self.cmd_followup(args, store, output: $stdout)
      sub = args.shift
      case sub
      when 'list'    then cmd_followup_list(args, store, output: output)
      when 'resolve' then cmd_followup_resolve(args, store, output: output)
      else
        die "Unknown followup subcommand: #{sub}\n" \
            "Usage: tyrion followup list <slug>\n" \
            "       tyrion followup resolve <slug> <n>"
      end
    end

    def self.cmd_followup_list(args, store, output: $stdout)
      slug = args.reject { |a| a.start_with?('--') }.first
      die "Usage: tyrion followup list <slug>" unless slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      notes = store.followup_notes(story['id'])
      if notes.empty?
        output.puts "No followup notes for #{slug}."
        return
      end

      output.puts Output.bold("Followups for #{slug}")
      output.puts
      notes.each_with_index do |note, i|
        resolved = note['resolved_at'] ? Output.dim(" [resolved #{note['resolved_at'][0, 10]}]") : ''
        output.puts "  #{i + 1}. #{note['body']}#{resolved}"
        output.puts "     #{Output.dim(note['created_at'][0, 19].gsub('T', ' '))}"
      end
    end

    def self.cmd_followup_resolve(args, store, output: $stdout)
      positional = args.reject { |a| a.start_with?('--') }
      slug, n    = positional[0], positional[1]&.to_i
      die "Usage: tyrion followup resolve <slug> <n>" unless slug && n && n >= 1

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      notes = store.followup_notes(story['id'])
      die "No followup notes for #{slug}." if notes.empty?
      note = notes[n - 1]
      die "Index #{n} out of range (1-#{notes.length})" unless note
      die "Followup #{n} is already resolved" if note['resolved_at']

      store.resolve_followup_note(note['id'])
      output.puts Output.green("✓ Followup #{n} resolved: #{note['body'][0, 60]}")
    end

    # ── lesson ─────────────────────────────────────────────────────────────

    LESSON_USAGE = "Usage: tyrion lesson add --at <trigger> \"text\"\n" \
                   "       tyrion lesson list [--at <trigger>] [--verbose]\n" \
                   "       tyrion lesson retire <lesson-NNN>\n" \
                   "       tyrion lesson promote <lesson-NNN> [--to epic|project|global]\n" \
                   "       tyrion lesson demote <lesson-NNN>\n" \
                   "       tyrion lesson mine [--dir <path>]"

    def self.cmd_lesson(args, store, input: $stdin, output: $stdout)
      sub = args.shift
      case sub
      when 'add'     then cmd_lesson_add(args, store, output: output)
      when 'list'    then cmd_lesson_list(args, store, output: output)
      when 'retire'  then cmd_lesson_retire(args, store, output: output)
      when 'promote' then cmd_lesson_promote(args, store, output: output)
      when 'demote'  then cmd_lesson_demote(args, store, output: output)
      when 'mine'    then cmd_lesson_mine(args, store, input: input, output: output)
      when nil       then die LESSON_USAGE
      else                die "Unknown lesson subcommand: #{sub}\n#{LESSON_USAGE}"
      end
    end

    def self.cmd_lesson_add(args, store, output: $stdout)
      trigger = extract_flag_value(args, '--at')
      die "Missing required --at <trigger>" unless trigger

      text = args.join(' ')
      die "Usage: tyrion lesson add --at <trigger> \"text\"" unless presence(text)

      project, epic = resolve_project_epic(store, require_epic: false)
      lesson = store.create_lesson(
        project_id: project['id'],
        trigger:    trigger,
        text:       text,
        epic_id:    epic&.dig('id')
      )
      output.puts Output.green("✓ Lesson #{lesson['id']} added [#{trigger}]")
    end

    # `--at <trigger>` is the just-in-time injection path other skill steps
    # shell out to and parse verbatim: one lesson body per line, nothing else,
    # and silent (no output at all) when there are no matches.
    def self.cmd_lesson_list(args, store, output: $stdout)
      trigger = extract_flag_value(args, '--at')
      verbose = args.delete('--verbose')
      project = resolve_project(store)

      if trigger
        lessons = store.list_lessons(project_id: project['id'], trigger: trigger)
        lessons.each { |l| output.puts l['text'] }
        return
      end

      lessons = store.list_lessons(project_id: project['id'])
      return output.puts "(no lessons)" if lessons.empty?

      lessons.group_by { |l| l['trigger'] }.each do |trig, group|
        output.puts "[#{trig}]"
        group.each do |l|
          if verbose
            output.puts "  #{l['id']}  #{lesson_scope_label(l)}  #{l['source']}  #{Output.time_ago(l['created_at'])}"
            output.puts "    #{l['text']}"
          else
            output.puts "  #{l['id']}  #{l['text']}"
          end
        end
      end
    end

    def self.cmd_lesson_retire(args, store, output: $stdout)
      id = args.shift
      die "Usage: tyrion lesson retire <lesson-NNN>" unless id

      store.retire_lesson(id)
      output.puts Output.green("✓ Lesson #{id} retired")
    rescue RuntimeError => e
      die e.message
    end

    # Values must track lesson_rank's scale 1:1 (epic/project/global only —
    # you can't promote *to* story) so `target_rank - current_rank` in
    # cmd_lesson_promote yields the correct number of promote_lesson calls.
    LESSON_PROMOTE_TARGET_RANKS = { 'epic' => 1, 'project' => 2, 'global' => 3 }.freeze

    def self.cmd_lesson_promote(args, store, output: $stdout)
      id = args.shift
      die "Usage: tyrion lesson promote <lesson-NNN> [--to epic|project|global]" unless id

      level = extract_flag_value(args, '--to')

      if level
        die "Unknown --to level: #{level}. Must be one of: epic, project, global" unless LESSON_PROMOTE_TARGET_RANKS.key?(level)

        lesson = store.find_lesson(id)
        die "Lesson not found: #{id}" unless lesson

        target_rank  = LESSON_PROMOTE_TARGET_RANKS[level]
        current_rank = lesson_rank(lesson)
        die "Lesson #{id} is already at or beyond #{level} scope" if current_rank >= target_rank

        result = nil
        (target_rank - current_rank).times { result = store.promote_lesson(id) }
      else
        result = store.promote_lesson(id)
      end

      output.puts Output.green("✓ Lesson #{id} promoted to #{lesson_scope_label(result, store: store)}")
    rescue RuntimeError => e
      die e.message
    end

    def self.cmd_lesson_demote(args, store, output: $stdout)
      id = args.shift
      die "Usage: tyrion lesson demote <lesson-NNN>" unless id

      result = store.demote_lesson(id)
      output.puts Output.green("✓ Lesson #{id} demoted to #{lesson_scope_label(result, store: store)}")
    rescue RuntimeError => e
      die e.message
    end

    # Structural rank of a lesson's current scope, narrowest to widest:
    # 0 = story-scoped, 1 = epic-scoped, 2 = project-wide, 3 = global.
    # Assumes strict nesting (story_id set implies epic_id set implies
    # project_id set) — the same assumption Store#promote_lesson's
    # narrowest-field-wins column choice already depends on. Every current
    # writer (create_lesson) upholds this; if a future caller ever creates a
    # non-nested row, both this rank and promote_lesson's column choice need
    # revisiting together, not just one of them.
    def self.lesson_rank(lesson)
      return 0 if lesson['story_id']
      return 1 if lesson['epic_id']
      return 2 if lesson['project_id']

      3
    end
    private_class_method :lesson_rank

    # Human-facing scope label: 'global', 'project-wide', or the epic name.
    # `list_lessons` rows already carry `epic_name` from its join; rows from
    # `promote_lesson`/`find_lesson` don't, so fall back to a store lookup.
    def self.lesson_scope_label(lesson, store: nil)
      return 'global' if lesson['project_id'].nil?
      return 'project-wide' if lesson['epic_id'].nil?

      lesson['epic_name'] || store&.find_epic_by_id(lesson['epic_id'])&.dig('name')
    end
    private_class_method :lesson_scope_label

    # Scans session JSONL transcripts for recurring correction signals (deterministic
    # regex matching — no LLM involved) and proposes candidate lessons for human
    # approval. Never writes a lesson without an explicit 'y' at the prompt.
    def self.cmd_lesson_mine(args, store, input: $stdin, output: $stdout)
      dir = extract_flag_value(args, '--dir') || default_lesson_mine_dir
      die "No session directory found. Pass --dir <path>." unless dir && Dir.exist?(dir)

      project, epic = resolve_project_epic(store, require_epic: false)
      groups = LessonMiner.scan(dir)
      candidates = groups.values.flatten

      if candidates.empty?
        output.puts "No correction candidates found in #{dir}."
        return
      end

      added = 0
      skipped = 0
      candidates.each do |candidate|
        output.puts ""
        output.puts "[#{candidate[:trigger]}] (#{candidate[:role]}, #{candidate[:file]})"
        output.puts candidate[:text]
        answer = prompt(input, output, "Add as lesson? [y/N]: ").downcase

        if answer == 'y'
          store.create_lesson(
            project_id: project['id'],
            trigger:    candidate[:trigger],
            text:       candidate[:text],
            epic_id:    epic&.dig('id'),
            source:     'auto-extracted'
          )
          added += 1
        else
          skipped += 1
        end
      end

      output.puts ""
      output.puts Output.green("✓ #{candidates.length} candidates found, #{added} added, #{skipped} skipped")
    end

    # Default scan directory — derives the Claude Code session dir for the current
    # cwd the same way the tyrion-implement skill does. Thin env wrapper; not unit
    # tested (logic that matters is LessonMiner.scan, exercised with explicit --dir).
    def self.default_lesson_mine_dir
      dasherized = Dir.pwd.gsub('/', '-')
      candidate = File.join(Dir.home, '.claude', 'projects', dasherized)
      Dir.exist?(candidate) ? candidate : nil
    end
    private_class_method :default_lesson_mine_dir

    # ── depends ────────────────────────────────────────────────────────────

    def self.cmd_depends(args, store)
      subcmd = args.shift
      case subcmd
      when 'add' then cmd_depends_add(args, store)
      when 'rm'  then cmd_depends_rm(args, store)
      else
        die "Usage: tyrion depends add|rm <slug> <dep-slug>"
      end
    end

    def self.cmd_depends_add(args, store)
      slug, dep_slug = args
      die "Usage: tyrion depends add <slug> <dep-slug>" unless slug && dep_slug

      _project, epic = resolve_project_epic(store)
      story     = store.find_story(epic['id'], slug)
      dep_story = store.find_story(epic['id'], dep_slug)
      die "Story not found: #{slug}"     unless story
      die "Story not found: #{dep_slug}" unless dep_story
      die "#{slug} cannot depend on itself" if slug == dep_slug

      current = JSON.parse(story['depends_on'] || '[]')
      if current.include?(dep_slug)
        puts "#{slug} already depends on #{dep_slug}"
      else
        store.update_story_depends_on(story['id'], current + [dep_slug])
        puts "#{Output.green('+')} #{slug} now depends on #{dep_slug}"
      end
    end

    def self.cmd_depends_rm(args, store)
      slug, dep_slug = args
      die "Usage: tyrion depends rm <slug> <dep-slug>" unless slug && dep_slug

      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story

      current = JSON.parse(story['depends_on'] || '[]')
      if current.include?(dep_slug)
        store.update_story_depends_on(story['id'], current - [dep_slug])
        puts "#{Output.red('-')} #{slug} no longer depends on #{dep_slug}"
      else
        puts "#{slug} does not depend on #{dep_slug}"
      end
    end

    # ── wave ───────────────────────────────────────────────────────────────

    def self.cmd_wave(args, store)
      subcmd = args.shift
      case subcmd
      when 'show' then cmd_wave_show(args, store)
      when 'set'  then cmd_wave_set(args, store)
      when 'next' then cmd_wave_next(args, store)
      else
        die "Usage: tyrion wave show | tyrion wave set <slug> <N> | tyrion wave next [--with-pocket]"
      end
    end

    def self.cmd_wave_next(args, store)
      with_pocket = args.include?('--with-pocket')
      _project, epic = resolve_project_epic(store)
      waves = store.wave_plan(epic['id'])
      stories = store.stories_for_epic(epic['id'])
      status_map = stories.to_h { |s| [s['slug'], s['status']] }

      # Scan waves in order. Skip fully-done waves; return pending stories from
      # the first wave that is not yet fully done (those are the dispatchable ones).
      pending_slugs = []
      waves.keys.grep(Integer).sort.each do |wn|
        next if waves[wn].all? { |s| status_map[s] == 'done' }
        pending_slugs = waves[wn].select { |s| status_map[s] == 'pending' }
        break
      end

      if pending_slugs.empty?
        puts '(no pending stories)'
        return
      end

      criteria_map = if with_pocket
                       stories.each_with_object({}) { |s, h| h[s['id']] = store.criteria_for_story(s['id']) }
                     end

      pending_slugs.each_with_index do |slug, i|
        puts slug
        next unless with_pocket

        story = stories.find { |s| s['slug'] == slug }
        unchecked = criteria_map[story['id']].reject { |c| %w[met not_applicable].include?(c['status']) }
        puts "  epic: #{epic['slug']}"
        puts "  story: #{slug}"
        unchecked.each { |c| puts "  [ ] #{c['keyword']} #{c['text']}" }
        puts unless i == pending_slugs.length - 1
      end
    end

    def self.cmd_wave_show(_args, store)
      _project, epic = resolve_project_epic(store)
      waves = store.wave_plan(epic['id'])
      if waves.empty?
        puts Output.dim("No stories in this epic.")
        return
      end
      pinned = store.stories_for_epic(epic['id'])
                    .select { |s| s['wave_override'] }
                    .to_h { |s| [s['slug'], s['wave_rationale']] }
      waves.each do |wave_num, slugs|
        if wave_num == :cycle
          puts "#{Output.red('Cycle')}: #{slugs.join(', ')} (circular dependency — fix with tyrion depends rm)"
        else
          annotated = slugs.map { |s| pinned.key?(s) ? "#{s} #{Output.dim('[pinned]')}" : s }
          puts "#{Output.bold("Wave #{wave_num}")}: #{annotated.join(', ')}"
        end
      end
    end

    def self.cmd_wave_set(args, store)
      slug     = args.shift
      wave_str = args.shift
      rationale = args.shift
      die "Usage: tyrion wave set <slug> <wave-number> [rationale]" unless slug && wave_str
      wave_num = wave_str.to_i
      die "wave-number must be a positive integer" unless wave_num.positive?
      _project, epic = resolve_project_epic(store)
      story = store.find_story(epic['id'], slug)
      die "Story not found: #{slug}" unless story
      waves = store.wave_plan(epic['id'])
      die "Cannot override wave for #{slug}: story is in a dependency cycle" if waves[:cycle]&.include?(slug)
      store.set_wave_override(story['id'], wave_num, rationale)
      puts "#{Output.green('✓')} #{slug} pinned to wave #{wave_num}"
    end

    # ── setup-codex ────────────────────────────────────────────────────────

    def self.cmd_setup_codex(_args, _store)
      skills_dir = File.expand_path('../../skills', __dir__)
      die "skills directory not found: #{skills_dir}" unless Dir.exist?(skills_dir)

      link = File.join(Dir.home, '.agents', 'skills', 'tyrion')
      if File.symlink?(link)
        File.unlink(link)
      elsif File.exist?(link)
        die "#{link} exists and is not a symlink — move it aside and re-run"
      end
      FileUtils.mkdir_p(File.dirname(link))
      File.symlink(skills_dir, link)

      names = Dir.glob(File.join(skills_dir, '*/SKILL.md')).map { |p| File.basename(File.dirname(p)) }.sort
      puts Output.green('Codex skill discovery installed:')
      puts "  #{link} -> #{skills_dir}"
      puts "Skills available (#{names.size}): #{names.join(', ')}"
      puts 'Restart the Codex CLI to discover them.'
    end

    # ── setup claude ───────────────────────────────────────────────────────
    # Installs (or reports on) Tyrion's Claude Code integration: the generic
    # shim script + the merged hooks/whitelist settings.

    def self.cmd_setup(args, store)
      case args.shift
      when 'claude' then cmd_setup_claude(args, store)
      else die "Unknown setup target. Use: claude"
      end
    end

    def self.cmd_setup_claude(args, _store)
      check = args.delete('--check')
      root  = Repo.worktree_root
      settings_path  = File.join(root, SETTINGS_RELATIVE_PATH)
      shim_path      = File.join(root, SHIM_INSTALL_PATH)
      claude_md_path = File.join(root, CLAUDE_MD_RELATIVE_PATH)

      return cmd_setup_claude_check(settings_path, shim_path, claude_md_path) if check

      # Preflight everything before any write — malformed input means zero writes.
      existing = load_settings_for_merge(settings_path)
      merged   = build_merged_settings(existing)
      shim_content = shim_script(version: SHIM_VERSION)
      existing_claude_md = File.exist?(claude_md_path) ? File.read(claude_md_path) : nil
      new_claude_md       = build_merged_claude_md(existing_claude_md)

      atomic_write(shim_path, shim_content, mode: 0o755)
      atomic_write(settings_path, "#{JSON.pretty_generate(merged)}\n")
      atomic_write(claude_md_path, new_claude_md)

      puts Output.green('Tyrion Claude Code integration installed:')
      puts "  shim:      #{shim_path}"
      puts "  settings:  #{settings_path}"
      puts "  CLAUDE.md: #{claude_md_path}"
      puts 'Hooks: SessionStart, PreCompact, PreToolUse(Bash) -> tyrion-shim.sh'
      puts "Whitelist: #{TYRION_PERMISSIONS.join(', ')}"
    rescue InvalidSettingsError => e
      die "refusing to install — #{e.message}"
    end

    def self.cmd_setup_claude_check(settings_path, shim_path, claude_md_path)
      existing, malformed_message =
        begin
          [load_settings_for_merge(settings_path), nil]
        rescue InvalidSettingsError => e
          [nil, e.message]
        end

      hooks_status     = existing ? setup_claude_hooks_status(existing) : :absent
      whitelist_status = existing ? setup_claude_whitelist_status(existing) : :absent

      shim_version = installed_shim_version(shim_path)
      shim_status  =
        if shim_version.nil?
          :absent
        elsif shim_version != SHIM_VERSION
          :drift
        else
          :current
        end

      claude_md_status_value = claude_md_status(claude_md_path)

      statuses       = [hooks_status, whitelist_status, shim_status, claude_md_status_value]
      all_current    = statuses.all? { |s| s == :current }
      fail_open_risk = all_current && !shim_reports_armed?(shim_path)

      puts "settings file: malformed JSON — #{malformed_message}" if malformed_message
      puts "hooks: #{hooks_status}"
      puts "whitelist: #{whitelist_status}"
      puts "gate shim + version: #{shim_status}#{shim_version ? " (v#{shim_version})" : ''}"
      puts "CLAUDE.md block: #{claude_md_status_value}"

      overall, code, suffix =
        if statuses.include?(:absent)
          ['partial', EXIT_PARTIAL, ' — run tyrion setup claude to complete install']
        elsif claude_md_status_value == :ambiguous
          ['drift', EXIT_DRIFT,
           ' — CLAUDE.md has ambiguous TYRION-MANAGED-BLOCK markers; resolve manually ' \
           '(re-running tyrion setup claude will itself refuse until fixed)']
        elsif statuses.include?(:drift)
          ['drift', EXIT_DRIFT, ' — re-run tyrion setup claude to refresh']
        elsif fail_open_risk
          ['fail-open', EXIT_FAIL_OPEN, ' — shim installed but not reporting armed; check that `tyrion` resolves on PATH']
        else
          ['current', EXIT_CURRENT, '']
        end

      puts "Overall: #{overall}#{suffix}"
      exit(code)
    end

    # :absent if none of the 3 canonical events have a tyrion-owned matcher-
    # group; :current if all 3 are present and byte-identical to
    # tyrion_hook_groups; :drift otherwise (missing some, or present-but-stale).
    def self.setup_claude_hooks_status(existing)
      per_event_states = tyrion_hook_groups.map do |event, wanted_group|
        found = Array(existing.dig('hooks', event)).find { |g| tyrion_group_match?(g, wanted_group['matcher']) }

        if found.nil?
          :absent
        elsif found == wanted_group
          :current
        else
          :drift
        end
      end

      if per_event_states.all? { |s| s == :absent }
        :absent
      elsif per_event_states.all? { |s| s == :current }
        :current
      else
        :drift
      end
    end

    def self.setup_claude_whitelist_status(existing)
      present = allow_list(existing) & TYRION_PERMISSIONS
      missing = TYRION_PERMISSIONS - present

      if present.empty?
        :absent
      elsif missing.empty?
        :current
      else
        :drift
      end
    end

    # Actually invokes the installed shim end-to-end (mirrors the exact
    # regression this design catches: a hook that looks wired but silently
    # fails open). Any failure shelling out counts as fail-open risk.
    def self.shim_reports_armed?(shim_path)
      out = `#{shim_path.shellescape} tyrion hook claim-gate --check 2>&1`
      out.include?('armed')
    rescue StandardError
      false
    end

    # ── hook (claim-gate) ────────────────────────────────────────────────────
    # Fat-binary port of hooks/claim-gate.sh's embedded Ruby (thin-shim design —
    # a generic shim script in the target repo execs `tyrion hook claim-gate`,
    # so upgrading the gem upgrades every installed repo's gate for free).
    # See hooks/claim-gate.sh for the full behavioral rationale in comments;
    # this is a straight logic port with real quote literals (no 34.chr/39.chr
    # workarounds — those existed only to keep the old bash heredoc quote-
    # balanced, which doesn't apply to a real .rb file).

    def self.cmd_hook(args, store)
      case args.shift
      when 'claim-gate' then cmd_hook_claim_gate(args, store)
      else die "Unknown hook subcommand. Use: claim-gate"
      end
    end

    def self.cmd_hook_claim_gate(args, store)
      return cmd_hook_claim_gate_check if args.first == '--check'

      cmd_hook_claim_gate_decide(store)
    rescue StandardError
      # Any internal error — fail open, never wedge the agent.
    end

    # Diagnostic mode: reports whether the gate is armed from the current
    # directory. ALWAYS exits 0 — it reports, never blocks.
    def self.cmd_hook_claim_gate_check
      root =
        begin
          Repo.tyrion_root(Dir.pwd)
        rescue StandardError
          nil
        end
      puts(root ? 'armed' : 'fail-open: no .tyrion project found from this directory')
      puts "version: #{GATE_VERSION}"
    end

    # Only gate a ledger-mutating tyrion subcommand invoked as an ACTUAL command —
    # the `tyrion` (or `.../bin/tyrion`) token must sit in command position: at the
    # start of a command segment or after a shell separator, following only optional
    # `VAR=value` env assignments and plain interpreter words (`ruby`, `bundle exec`,
    # ...). A flag (e.g. `-C`) or a quote before the token breaks the run, so
    # `git -C /path/tyrion check-ignore ...` and `git commit -m "tyrion note: ..."`
    # never match. The verb must be a complete token — `check-ignore` is not `check`.
    # Group 1 is the verb; group 2 is the first positional arg (the target slug).
    CLAIM_GATE_RE = %r{
      (?:^|[\n;&|])            # start of a command segment
      \s*
      # optional VAR=value env assignments. The value is a balanced single- or
      # double-quoted string, or a bare unquoted token.
      (?:\w+=(?:'[^']*'|"[^"]*"|[^\s'"]*)\s+)*
      (?:[A-Za-z0-9_.]+\s+)*   # optional plain interpreter words (ruby, bundle, exec)
      (?:\S*/)?                # optional path prefix on the executable (bin/, /path/bin/)
      tyrion\s+
      (note|check|done)        # the gated verb
      (?=[\s;&|]|$)            # verb must be a complete token, not check-ignore
      (?:\s+(\S+))?            # optional first positional arg (the target slug)
    }x.freeze

    # Claude Code runs this hook with cwd = the SESSION's project dir, so a gated
    # command that targets a DIFFERENT repo via a `cd <dir> &&` (or `cd <dir>;`)
    # prefix would otherwise be judged against the session ledger, not the one it
    # actually mutates. Matches the last top-level `cd <dir>` in the command chain
    # that leads up to the gated command.
    CLAIM_GATE_CD_RE = %r{
      (?:^|[\n;&|])                     # segment boundary before cd
      \s*
      cd\s+
      (?:
        "([^"]*)" |                     # double-quoted dir (may hold spaces)
        '([^']*)' |                     # single-quoted dir
        ([^\s;&|]+)                     # bare dir
      )
      \s*
      (?=$|[\n;&|])                     # cd must be a complete segment
    }x.freeze

    def self.cmd_hook_claim_gate_decide(store)
      data =
        begin
          JSON.parse($stdin.read)
        rescue StandardError
          return # unparseable hook payload — not our place to block
        end

      cmd = data.dig('tool_input', 'command').to_s
      m = cmd.match(CLAIM_GATE_RE)
      return unless m

      verb        = m[1]
      target_slug = m[2]

      cd_dir = claim_gate_cd_dir(cmd[0...m.begin(0)])
      root   = Repo.tyrion_root(cd_dir || Dir.pwd)
      return unless root # outside a Tyrion project — fail open

      token = claim_gate_lane_token(cmd)

      project_slug = Repo.active_project(root)
      epic_slug    = Repo.active_epic(root, token: token)

      epic            = nil
      has_in_progress = false
      if project_slug && (project = store.find_project_by_slug(project_slug)) &&
         epic_slug && (epic = store.find_epic(project['id'], epic_slug))
        has_in_progress   = !store.in_progress_story_for(epic['id'], token).nil? if token
        # Legacy single-session: an unclaimed (NULL claimed_by) in_progress story
        # in the active epic is this lane's story too.
        has_in_progress ||= !store.story_in_progress_unclaimed(epic['id']).nil?
      end

      return if has_in_progress

      # Orchestrator affordance: a lane with no in_progress story may still record
      # a post-hoc `tyrion note` on a story its subagents already finished — i.e.
      # a story whose status is `done` or `blocked`. `check`/`done` are never
      # permitted without a claim, and `note` on a pending/in_progress story stays
      # blocked.
      if verb == 'note' && target_slug && epic
        story = store.find_story(epic['id'], target_slug)
        return if story && %w[done blocked].include?(story['status'])
      end

      $stderr.puts <<~MSG
        Tyrion claim gate: no in_progress story in this lane.
        Claim a story before recording ledger updates:
          tyrion start <slug>
        Then re-run your `tyrion #{verb}` command.
      MSG
      exit 2
    end

    def self.claim_gate_cd_dir(head)
      cd_dir = nil
      head.scan(CLAIM_GATE_CD_RE) { cd_dir = Regexp.last_match(1) || Regexp.last_match(2) || Regexp.last_match(3) }
      cd_dir
    end

    # An explicit TYRION_LANE=<token> prefix in the command wins over the ambient
    # lane identity. An agent may write the value quoted; strip a matched
    # surrounding quote pair (the unquoted form has no pair and is unchanged).
    def self.claim_gate_lane_token(cmd)
      raw_lane = cmd[/\bTYRION_LANE=(\S+)/, 1]
      if raw_lane
        q = raw_lane[0]
        if q == '"' || q == "'"
          close    = raw_lane.index(q, 1)
          raw_lane = close ? raw_lane[1...close] : raw_lane[1..-1]
        end
      end
      raw_lane || current_lane_token
    end

    # ── atomic write ───────────────────────────────────────────────────────
    # Build-complete-then-rename pattern: write to a temp file in the SAME
    # directory as +path+ (required for an atomic same-filesystem rename), then
    # rename it into place. If anything raises before the rename, no partial
    # file is left at +path+.
    def self.atomic_write(path, content, mode: nil)
      FileUtils.mkdir_p(File.dirname(path))
      tmp_path = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.write(tmp_path, content)
      File.chmod(mode, tmp_path) if mode
      File.rename(tmp_path, path)
    ensure
      File.delete(tmp_path) if tmp_path && File.exist?(tmp_path)
    end

    # ── shim template ──────────────────────────────────────────────────────
    # The generic shim installed into target repos. Its only job: fail open
    # silently if the real binary isn't resolvable, else `exec` it so the real
    # command's exit code (e.g. exit 2 from the claim gate) propagates unchanged.
    SHIM_MARKER_RE = /# tyrion-shim v(\d+)/.freeze

    def self.shim_script(version: SHIM_VERSION)
      <<~SHIM
        #!/usr/bin/env bash
        # tyrion-shim v#{version} — installed by `tyrion setup claude`.
        # Re-run setup to upgrade; do not hand-edit.
        if ! command -v "$1" >/dev/null 2>&1; then
          exit 0
        fi
        exec "$@"
      SHIM
    end

    # Reads the version marker from an installed shim. Returns nil if the file
    # doesn't exist or doesn't look like a tyrion-owned shim (no matching marker).
    def self.installed_shim_version(path)
      return nil unless File.exist?(path)
      match = File.read(path).match(SHIM_MARKER_RE)
      match && match[1].to_i
    end

    # ── CLAUDE.md managed block ───────────────────────────────────────────
    # Line-anchored HTML-comment markers so they're invisible when CLAUDE.md
    # renders as markdown. Body hash is computed over the bytes strictly
    # between the marker lines (never including the marker lines themselves),
    # so the hash is never self-referential.
    CLAUDE_MD_BEGIN_RE = /^<!-- BEGIN TYRION-MANAGED-BLOCK v(\d+) sha256:([0-9a-f]{64}) -->$/.freeze
    CLAUDE_MD_END_RE   = /^<!-- END TYRION-MANAGED-BLOCK -->$/.freeze

    # The canonical body text, hashed and wrapped by `render_claude_md_block`.
    # Points at `tyrion prime` for live state rather than dumping a static
    # command reference (which would itself drift from the CLI).
    def self.claude_md_block_body
      <<~BODY.chomp
        ## Tyrion

        This repo is tracked by Tyrion, a resumability ledger for coding agents.

        Rules:
        - claim before code (tyrion claim-next)
        - evidence via tyrion note/check, not ad hoc

        Run `tyrion prime` for the live session briefing — active epic/story, next action, unmet criteria.
      BODY
    end

    # Renders the full marker-delimited block (BEGIN line + body + END line),
    # ready to be spliced into a CLAUDE.md file.
    def self.render_claude_md_block(body: claude_md_block_body, version: CLAUDE_MD_BLOCK_VERSION)
      hash = Digest::SHA256.hexdigest(body)
      "<!-- BEGIN TYRION-MANAGED-BLOCK v#{version} sha256:#{hash} -->\n#{body}\n<!-- END TYRION-MANAGED-BLOCK -->\n"
    end

    # Finds every BEGIN/END marker line in +content+, returning
    # [begin_matches, end_matches] (each a MatchData array, in file order).
    def self.claude_md_marker_scan(content)
      [claude_md_matches(content, CLAUDE_MD_BEGIN_RE), claude_md_matches(content, CLAUDE_MD_END_RE)]
    end

    def self.claude_md_matches(content, regexp)
      [].tap { |matches| content.scan(regexp) { matches << Regexp.last_match } }
    end

    # true only for the unambiguous "exactly one begin, one end, end after
    # begin" shape. Anything else (0/2+ of either, or end before begin) is
    # ambiguous and must not be auto-resolved.
    def self.claude_md_well_formed?(begins, ends)
      begins.length == 1 && ends.length == 1 && ends.first.begin(0) > begins.first.begin(0)
    end

    # Pure function: given the current CLAUDE.md content (nil/absent -> no
    # file yet), returns the new full file content with the tyrion-owned
    # block created/replaced. Raises InvalidSettingsError (zero writes, per
    # the caller's preflight-then-write pattern) when the existing markers
    # are ambiguous. Never touches disk.
    def self.build_merged_claude_md(existing_content)
      content = existing_content || ''
      begins, ends = claude_md_marker_scan(content)
      new_block = render_claude_md_block

      if begins.empty? && ends.empty?
        return new_block if content.empty?

        return append_claude_md_block(content, new_block)
      end

      unless claude_md_well_formed?(begins, ends)
        raise InvalidSettingsError,
              "CLAUDE.md has ambiguous TYRION-MANAGED-BLOCK markers (#{begins.length} BEGIN, #{ends.length} END " \
              'found) — resolve manually before re-running setup'
      end

      begin_match = begins.first
      end_match   = ends.first

      prefix = content[0...begin_match.begin(0)]
      after_end = end_match.end(0)
      after_end += 1 if content[after_end] == "\n"
      suffix = content[after_end..] || ''

      "#{prefix}#{new_block}#{suffix}"
    end

    # Appends +new_block+ after +content+, ensuring a blank-line separator
    # regardless of whether +content+ already ends with 0, 1, or 2 newlines.
    def self.append_claude_md_block(content, new_block)
      separator =
        if content.end_with?("\n\n")
          ''
        elsif content.end_with?("\n")
          "\n"
        else
          "\n\n"
        end

      "#{content}#{separator}#{new_block}"
    end

    # :drift covers a well-formed block that's stale for any reason — hand-
    # edited, corrupted hash, or an old block version — since a plain
    # version+hash match against the canonical block is all that separates
    # :current from it.
    def self.claude_md_status(path)
      return :absent unless File.exist?(path)

      begins, ends = claude_md_marker_scan(File.read(path))
      return :absent if begins.empty? && ends.empty?
      return :ambiguous unless claude_md_well_formed?(begins, ends)

      begin_match = begins.first
      if begin_match[1].to_i == CLAUDE_MD_BLOCK_VERSION && begin_match[2] == Digest::SHA256.hexdigest(claude_md_block_body)
        :current
      else
        :drift
      end
    end

    # ── whitelist ──────────────────────────────────────────────────────────

    def self.cmd_whitelist(args, _store)
      case args.shift || 'show'
      when 'show'   then whitelist_show
      when 'add'    then whitelist_add(whitelist_scope(args))
      when 'remove' then whitelist_remove(whitelist_scope(args))
      else die "Unknown whitelist subcommand. Use: add, remove, show"
      end
    end

    def self.whitelist_scope(args)
      scope = extract_flag_value(args, '--scope') || 'local'
      die "Unknown scope '#{scope}'. Use: local, project, global" unless WHITELIST_SCOPES.key?(scope)
      scope
    end

    def self.whitelist_add(scope)
      path     = WHITELIST_SCOPES[scope].call
      settings = load_settings(path)
      allow    = allow_list(settings)
      added    = TYRION_PERMISSIONS.reject { |p| allow.include?(p) }
      if added.empty?
        puts "Already whitelisted in #{scope} (#{path})"
        return
      end
      settings['permissions'] ||= {}
      settings['permissions']['allow'] = allow + added
      write_settings(path, settings)
      puts "Added to #{scope} (#{path}):"
      added.each { |p| puts "  #{Output.green('+')} #{p}" }
    end

    def self.whitelist_remove(scope)
      path = WHITELIST_SCOPES[scope].call
      unless File.exist?(path)
        puts "Nothing to remove — #{path} does not exist"
        return
      end
      settings = load_settings(path)
      allow    = allow_list(settings)
      removed  = TYRION_PERMISSIONS.select { |p| allow.include?(p) }
      if removed.empty?
        puts "Nothing to remove — tyrion rules not found in #{scope}"
        return
      end
      settings['permissions']['allow'] = allow - TYRION_PERMISSIONS
      settings['permissions'].delete('allow') if settings['permissions']['allow'].empty?
      settings.delete('permissions') if settings['permissions'].empty?
      write_settings(path, settings)
      puts "Removed from #{scope} (#{path}):"
      removed.each { |p| puts "  #{Output.red('-')} #{p}" }
    end

    def self.whitelist_show
      indent = ' ' * 12
      puts "Tyrion permission whitelist status:\n\n"
      WHITELIST_SCOPES.each do |scope_name, build_path|
        path  = build_path.call
        label = scope_name.ljust(8)
        unless File.exist?(path)
          puts "  #{Output.dim(label)} #{Output.dim('(no settings file)')}"
          next
        end
        found = TYRION_PERMISSIONS & allow_list(load_settings(path))
        if found.any?
          puts "  #{Output.green(label)} #{path}"
          found.each { |p| puts "#{indent}#{Output.dim(p)}" }
        else
          puts "  #{Output.dim(label)} #{path} #{Output.dim('(no tyrion rules)')}"
        end
      end
    end

    def self.allow_list(settings) = settings.dig('permissions', 'allow') || []

    def self.load_settings(path)
      return {} unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      die "Invalid JSON in #{path}: #{e.message}"
    end

    def self.write_settings(path, settings)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(settings)}\n")
    end

    # ── settings merge engine (`tyrion setup claude`) ────────────────────────
    # Pure logic that folds Tyrion's hooks + whitelist permissions into a
    # possibly-absent/malformed `.claude/settings.json`-shaped hash, without
    # disturbing anything foreign already there. No disk I/O except in
    # `load_settings_for_merge` (read-only); nothing here ever writes a file —
    # `cmd_setup_claude` does that, via `atomic_write`.
    #
    # Error-signaling convention: invalid input is signaled by RAISING
    # `InvalidSettingsError` (never a silent nil / false return) from both
    # `load_settings_for_merge` (bad JSON syntax) and `build_merged_settings`
    # (well-formed JSON, but the wrong shape per `validate_settings_shape`).
    # Callers should rescue this one class around the whole load -> build ->
    # write pipeline.
    class InvalidSettingsError < StandardError; end

    # Builds the command string for one tyrion-owned hook entry, e.g.
    # `"$CLAUDE_PROJECT_DIR"/.claude/hooks/tyrion-shim.sh tyrion hook claim-gate`.
    def self.shim_command(*subcmd_parts)
      %("$CLAUDE_PROJECT_DIR"/#{SHIM_INSTALL_PATH} #{subcmd_parts.join(' ')})
    end

    # The three matcher-groups Tyrion owns, keyed by hook event name. Built
    # fresh each call (not a frozen constant) — callers may hand these
    # straight into arrays that get further merged.
    def self.tyrion_hook_groups
      {
        'SessionStart' => { 'matcher' => '', 'hooks' => [{ 'type' => 'command', 'command' => shim_command('tyrion', 'prime') }] },
        'PreCompact'   => { 'matcher' => '', 'hooks' => [{ 'type' => 'command', 'command' => shim_command('tyrion', 'prime') }] },
        'PreToolUse'   => { 'matcher' => 'Bash', 'hooks' => [{ 'type' => 'command', 'command' => shim_command('tyrion', 'hook', 'claim-gate') }] }
      }
    end

    # A matcher-group is "tyrion-owned" if any of its inner hook commands
    # reference the shim path — this is how a stale tyrion entry (e.g. from an
    # older shim version or the pre-shim direct-script style) is told apart
    # from a foreign one, with no extra metadata needed.
    def self.tyrion_owned_hook_group?(group)
      return false unless group.is_a?(Hash)

      Array(group['hooks']).any? { |h| h.is_a?(Hash) && h['command'].to_s.include?(SHIM_INSTALL_PATH) }
    end

    # The one shared "is this the tyrion-owned group for this matcher"
    # predicate — used both to find the group to replace in-place
    # (`merge_hook_groups`) and to report its status (`setup_claude_hooks_status`),
    # so the ownership rule can't drift between the two call sites.
    def self.tyrion_group_match?(group, matcher)
      group.is_a?(Hash) && group['matcher'] == matcher && tyrion_owned_hook_group?(group)
    end

    # Given the existing matcher-group array for ONE hook event (nil/absent ->
    # treated as []) and the one tyrion-owned group that should be present,
    # returns a NEW array: replaces an existing tyrion-owned group for the
    # same matcher in place (same position), else appends. Never mutates
    # +existing_groups+; every foreign/other-matcher group is preserved
    # untouched, in order.
    def self.merge_hook_groups(existing_groups, tyrion_group)
      existing_groups = Array(existing_groups || [])
      matcher = tyrion_group['matcher']
      idx = existing_groups.find_index { |g| tyrion_group_match?(g, matcher) }

      if idx
        replaced = existing_groups.dup
        replaced[idx] = tyrion_group
        replaced
      else
        existing_groups + [tyrion_group]
      end
    end

    # Given the whole settings hash (may lack `hooks` entirely, or have
    # some/all of the three tyrion event arrays absent), returns a NEW hash
    # with SessionStart/PreCompact/PreToolUse each merged per
    # `merge_hook_groups`, every other event key (e.g. a user's own `Stop`
    # hook) preserved byte-for-byte in original key order, and every other
    # top-level key in +settings_hash+ untouched. Does not mutate the input.
    def self.merge_settings_hooks(settings_hash)
      original_hooks = settings_hash['hooks'].is_a?(Hash) ? settings_hash['hooks'] : {}
      tyrion_groups  = tyrion_hook_groups

      new_hooks = {}
      original_hooks.each do |event, groups|
        new_hooks[event] = tyrion_groups.key?(event) ? merge_hook_groups(groups, tyrion_groups[event]) : groups
      end
      tyrion_groups.each do |event, group|
        new_hooks[event] = merge_hook_groups(nil, group) unless new_hooks.key?(event)
      end

      settings_hash.merge('hooks' => new_hooks)
    end

    # Folds TYRION_PERMISSIONS into settings_hash['permissions']['allow'] the
    # same way `whitelist_add` does (additive, no duplicates, preserves
    # existing order) — as a pure function, reusing `allow_list`. Does not
    # mutate the input.
    def self.merge_settings_permissions(settings_hash)
      allow    = allow_list(settings_hash)
      added    = TYRION_PERMISSIONS.reject { |p| allow.include?(p) }
      original_permissions = settings_hash['permissions'].is_a?(Hash) ? settings_hash['permissions'] : {}

      settings_hash.merge('permissions' => original_permissions.merge('allow' => allow + added))
    end

    # true/false — is +settings_hash+ safe to merge into? Rejects (returns
    # false, never raises) hooks/events/matcher-groups/permissions present
    # but of the wrong type.
    def self.validate_settings_shape(settings_hash)
      return false unless settings_hash.is_a?(Hash)

      hooks = settings_hash['hooks']
      if hooks
        return false unless hooks.is_a?(Hash)
        return false unless hooks.all? { |_event, groups| valid_hook_group_array?(groups) }
      end

      permissions = settings_hash['permissions']
      if permissions
        return false unless permissions.is_a?(Hash)

        allow = permissions['allow']
        return false if allow && !allow.is_a?(Array)
      end

      true
    end

    def self.valid_hook_group_array?(groups)
      return false unless groups.is_a?(Array)

      groups.all? do |group|
        next false unless group.is_a?(Hash)

        inner_hooks = group['hooks']
        inner_hooks.nil? || inner_hooks.is_a?(Array)
      end
    end

    # Reads+parses the settings file at +path+. Absent file -> {}. Valid
    # JSON -> parsed hash. Invalid JSON syntax -> raises InvalidSettingsError
    # (see error-signaling convention above).
    def self.load_settings_for_merge(path)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise InvalidSettingsError, "Invalid JSON in #{path}: #{e.message}"
    end

    # The composed public entry point `cmd_setup_claude` calls. Pure function:
    # given an already-parsed settings hash, returns the fully merged hash
    # (hooks merged + whitelist permissions folded in) or raises
    # InvalidSettingsError per `validate_settings_shape`. Never writes to disk.
    def self.build_merged_settings(existing_hash)
      raise InvalidSettingsError, 'malformed .claude/settings.json shape' unless validate_settings_shape(existing_hash)

      merge_settings_permissions(merge_settings_hooks(existing_hash))
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
          tyrion epic complete [slug] [--force]    Seal an epic as done (all stories must be done)
          tyrion epic archive <slug>               Archive an epic (hides it from epic list)
          tyrion epic unarchive <slug>             Restore an archived epic
          tyrion epic mode <slug> [dark_factory|shape]  Get/set epic autonomy mode
          tyrion epic parent <slug> <parent>       Set slug's containing epic (--none clears it)
          tyrion epic depends add <slug> <dep>     Record that epic <slug> must run after epic <dep>
          tyrion epic depends rm <slug> <dep>      Remove an epic-level dependency
          tyrion epic waves                        Show epic wave plan — runnable epics only

        Import:
          tyrion import <file.feature>             Import gherkin scenarios as stories

        Status & navigation:
          tyrion status                            Plan view (the main command)
          tyrion statusline                        One-line lane surface for the Claude Code statusline
          tyrion list [--status pending]           List stories
          tyrion show <slug>                       Full story detail
          tyrion notes <slug> [--kind <kind>]      All notes, untruncated (full body)
          tyrion web [restart|stop|status]         Start (or open) the web UI — auto-opens browser
                                                    (alias: tyrion dashboard; flags: --port N, --no-open)
          tyrion web ambient                       Open the project-scoped ambient page in a narrow window

        Work:
          tyrion start <slug> [--steal]            Claim a story (--steal to force takeover of another lane)
          tyrion block <slug> "reason" [--discovery disc-NNN]  Block a story with a reason
          tyrion unblock <slug> [--resume]         Unblock a story → restores prior status (--resume forces in_progress)
          tyrion claim-next                        Claim next pending story (transactional)
          tyrion claim <slug> --as <label>         Pre-claim a story for a lane (adopts on TYRION_LANE=<label> start)
          tyrion unclaim <slug> [--steal]          Release a claim → pending (frees a dead lane; --steal for a live one)
          tyrion whoami                            Show this lane's token, liveness, and claimed story
          tyrion worktrees                         Dashboard of all git worktrees + active lanes (path, branch, epic, story, owner, live/dead)
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
          tyrion drift                             Check if feature files have changed since last import
          tyrion followup list <slug>              List followup notes (open + resolved)
          tyrion followup resolve <slug> <n>       Mark followup #n as resolved

        Discovery (SDRD spike loop) — add --auto on any of the four to record origin=agent:
          tyrion mark "description" [--headline "…"] [--auto]
                                                    Bookmark — instant breadcrumb with git context
          tyrion discover [--auto]                 Organic capture — question + finding → findings_ready
          tyrion discover <disc-id> --finding "…"  Upgrade a mark → findings_ready, no prompts
                                                    ([--question "…"] [--headline "…"])
          tyrion spike start "question" [--auto]   Frame a known unknown → active_spike
          tyrion spike done [--auto]               Close spike with finding + confidence + recommendation
          tyrion spike promote <disc-id>           Promote findings_ready → linked story
          tyrion discovery list [--status <alias>] List discoveries (aliases: active|marks|ready|promoted|deferred|all)
          tyrion discovery show <disc-id>          Show full discovery detail
          tyrion discovery defer <disc-id> ["why"] Retire an open mark/finding with a reason
          tyrion discovery search "<term>"         Search discoveries (all statuses; silent if no match)
          tyrion discovery headline <disc-id> "…"  Set/update the glance-surface headline (ambient, status, list)

        Lessons:
          tyrion lesson add --at <trigger> "text"   Record a lesson, scoped to active epic if any
          tyrion lessons [--at <trigger>]           List active lessons (silent if none match --at)
          tyrion lesson list [--at <trigger>] [--verbose]  Same as above (--verbose adds scope/source/age)
          tyrion lesson retire <lesson-NNN>         Retire a lesson
          tyrion lesson mine [--dir <path>]         Scan session JSONL for candidate lessons, approve interactively

        Permissions:
          tyrion whitelist show                    Show whitelist status across all scopes
          tyrion whitelist add [--scope local|project|global]   Add tyrion rules (default: local)
          tyrion whitelist remove [--scope local|project|global] Remove tyrion rules

        Claude Code:
          tyrion setup claude                      Wire hooks, claim-gate shim, and whitelist into .claude/settings.json
          tyrion setup claude --check              Report install status per surface, writes nothing
          tyrion hook claim-gate [--check]         PreToolUse claim-gate logic (invoked by the installed shim)

        Other agents:
          tyrion setup-codex                       Install tyrion skills into Codex native skill discovery (~/.agents/skills)
      USAGE
    end

    # Derive a stable, per-session lane token for the calling agent process.
    # Token format: "claude:<pid>:<start-stamp>" (ps path) or "<agent>:<session-id>" (sandbox path).
    # Tiers (first match wins):
    #   1. TYRION_LANE env — explicit override, sandbox-safe, universal.
    #   2. CODEX_THREAD_ID env — sandbox-safe Codex identity (ps denied in Codex sandbox).
    #   3. Process-walk via Repo.agent_pid — claude path, terminal-agnostic.
    #   4. CMUX_CLAUDE_PID env — optional fast-path accelerator for the claude/pid token.
    #   5. nil — legacy single-session behavior (no lane ownership).
    # Memoized per OS process via @_lane_token; reset to :unset to re-derive (e.g. in specs).
    def self.current_lane_token
      @_lane_token = derive_lane_token if @_lane_token == :unset
      @_lane_token
    end

    private

    # ── Helpers ────────────────────────────────────────────────────────────

    def self.die(msg)
      $stderr.puts "Error: #{msg}"
      exit 1
    end

    # Renders the Gates: section (gate/commit notes) for tyrion show / tyrion resume.
    # Per gate name: latest result (✓ pass / ✗ fail) + total run count. Commit notes
    # print their body verbatim. Prints nothing when the story has no gate/commit notes.
    # Project-wide (not epic- or story-scoped): what's already been noticed, so
    # the agent doesn't re-investigate a question someone already marked.
    KNOWN_SECTION_LIMIT = 5

    def self.print_known_section(store, project_id)
      open = store.open_discoveries(project_id: project_id)
      return if open.empty?

      puts
      puts Output.bold("Known:")
      open.first(KNOWN_SECTION_LIMIT).each do |d|
        if d['status'] == 'findings_ready'
          text = presence(d['finding']) || presence(d['question']) || '(no finding recorded)'
          puts "  → #{d['id']}  #{text}  #{Output.dim("(tyrion spike promote #{d['id']})")}"
        else
          puts "  • #{d['id']}  #{presence(d['question']) || '(no description)'}"
        end
      end
      remaining = open.length - KNOWN_SECTION_LIMIT
      puts Output.dim("  (#{remaining} more — tyrion discovery list --status all)") if remaining > 0
    end

    def self.print_gates_section(store, story_id)
      notes = store.gate_notes_for_story(story_id)
      return if notes.empty?

      puts Output.bold("Gates:")
      notes.select { |n| n['kind'] == 'gate' }
           .group_by { |n| n['body'][/\A(.+?): (?:PASS|FAIL)/, 1] || n['body'] }
           .each do |name, runs|
        icon  = runs.last['body'].match?(/\A.+?: PASS/) ? Output.green('✓') : Output.red('✗')
        label = runs.length == 1 ? 'run' : 'runs'
        puts "  #{icon} #{name} (#{runs.length} #{label})"
      end
      notes.select { |n| n['kind'] == 'commit' }.each do |c|
        lines = c['body'].lines.map(&:chomp)
        puts "  #{lines.first}"
        lines[1..].each { |line| puts "    #{line}" }
      end
      puts
    end

    # Gate names whose most-recent gate note has a failing result. Prefers the
    # metadata {gate,result}, falling back to the body regex that
    # print_gates_section uses — cmd_gate keeps the two in lockstep, so the
    # enforcement decision matches what the Gates section renders. Returns names
    # in first-seen order; [] when clean.
    def self.latest_failing_gates(store, story_id)
      store.gate_notes_for_story(story_id)
           .select { |n| n['kind'] == 'gate' }
           .group_by { |n| gate_name_of(n) }
           .filter_map { |name, runs| name if gate_result_of(runs.last) == 'fail' }
    end

    # Distinct gate names that have at least one recorded gate note, regardless
    # of pass/fail (coverage is presence, not result). Same
    # gate_notes_for_story → kind='gate' → gate_name_of pipeline that
    # latest_failing_gates uses, so the two stay in lockstep.
    def self.recorded_gate_names(store, story_id)
      store.gate_notes_for_story(story_id)
           .select { |n| n['kind'] == 'gate' }
           .map { |n| gate_name_of(n) }.uniq
    end

    # Parse --require-gates=<name1,name2> out of args (mutating), returning the
    # list of required gate names. Absent flag → [] (no coverage requirement,
    # identical to legacy behavior). Empty/whitespace names are dropped.
    def self.extract_require_gates!(args)
      flag = args.find { |a| a.start_with?('--require-gates=') }
      return [] unless flag

      args.delete(flag)
      flag.split('=', 2)[1].to_s.split(',').map(&:strip).reject(&:empty?)
    end

    def self.gate_name_of(note)
      meta = parse_gate_metadata(note)
      (meta && presence(meta['gate'])) || note['body'][/\A(.+?): (?:PASS|FAIL)/, 1] || note['body']
    end

    def self.gate_result_of(note)
      meta = parse_gate_metadata(note)
      return meta['result'].to_s.downcase if meta && presence(meta['result'])

      note['body'][/\A.+?: (PASS|FAIL)/, 1]&.downcase
    end

    def self.parse_gate_metadata(note)
      JSON.parse(note['metadata']) if presence(note['metadata'])
    rescue JSON::ParserError
      nil
    end

    # Removes "--flag value" from args in place and returns the value.
    # Dies with a clear message if the flag is present but has no value.
    def self.extract_flag_value(args, flag)
      return nil unless (idx = args.index(flag))
      value = args[idx + 1]
      die "Missing value after #{flag}" if value.nil? || value.start_with?('--')
      args.slice!(idx, 2)
      value
    end

    def self.derive_lane_token
      # Tier 1 — explicit override
      explicit = ENV['TYRION_LANE']
      return explicit if explicit && !explicit.strip.empty?

      agent_label = ENV['TYRION_AGENT']

      # Tier 2 — Codex sandbox-safe identity (ps is denied under Codex)
      thread_id = ENV['CODEX_THREAD_ID']
      if thread_id && !thread_id.strip.empty?
        label = agent_label || 'codex'
        return "#{label}:#{thread_id}"
      end

      # Tier 3 & 4 — pid-based token (claude path); CMUX_CLAUDE_PID is a fast-path
      # accelerator that skips the ps walk when available, but produces the same result.
      pid = if ENV['CMUX_CLAUDE_PID']&.match?(/\A\d+\z/)
              ENV['CMUX_CLAUDE_PID'].to_i
            else
              Repo.agent_pid
            end
      return nil unless pid

      stamp = Repo.pid_start_stamp(pid)
      return nil unless stamp

      label = agent_label || 'claude'
      "#{label}:#{pid}:#{stamp}"
    end
    private_class_method :derive_lane_token

    def self.resolve_project(store)
      slug = Repo.active_project
      die "No active project. Run: tyrion project activate <slug>" unless slug
      project = store.find_project_by_slug(slug)
      die "Active project '#{slug}' not found. Run: tyrion init" unless project
      project
    end

    # Activate +slug+ as the per-lane epic for +token+. Prints a loud warning on
    # stderr when the epic changes so concurrent sessions can spot cross-lane drift.
    # Silent on first activation or re-activating the same epic (no noise).
    def self.set_active_epic_for_lane(slug, token:, root: nil)
      root ||= Repo.worktree_root
      old = Repo.active_epic(root, token: token)
      Repo.write_active_epic(slug, root, token: token)
      $stderr.puts Output.yellow("⚠ EPIC SWITCHED #{old} → #{slug}") if old && old != slug
    end

    def self.resolve_project_epic(store, require_epic: true)
      project = resolve_project(store)

      epic_slug = Repo.active_epic(token: current_lane_token)
      unless epic_slug
        die "No active epic. Run: tyrion epic activate <slug>" if require_epic
        return [project, nil]
      end

      epic = store.find_epic(project['id'], epic_slug)
      die "Active epic '#{epic_slug}' not found. Run: tyrion epic activate <slug>" unless epic

      [project, epic]
    end

    # Six-rung story resolver for the current lane. Returns a story hash or nil.
    # Rung 1: explicit_slug given → always wins (dies if not found).
    # Rung 2: in_progress story whose claimed_by == current lane token (PRIMARY; survives /clear).
    # Rung 3: story with claimed_by == "assigned:<TYRION_LANE>" → adopt + re-stamp to real token.
    # Rung 4: .tyrion/active-story file pin (per-lane then shared fallback via Repo.active_story).
    # Rung 5: sole unclaimed (NULL claimed_by) in_progress story — legacy single-session.
    # Rung 6: claim-next and stamp, only when claim_if_none: true.
    def self.resolve_my_story(store, epic, explicit_slug:, claim_if_none:)
      # Rung 1 — explicit slug always wins
      if explicit_slug
        story = store.find_story(epic['id'], explicit_slug)
        die "Story not found: #{explicit_slug}" unless story
        return story
      end

      token = current_lane_token

      # Rung 2 — in_progress story owned by this lane token (PRIMARY; survives /clear)
      if token
        story = store.story_in_progress_for_token(epic['id'], token)
        return story if story
      end

      # Rung 3 — pre-claim placeholder "assigned:<TYRION_LANE>" → adopt + re-stamp
      if token && (lane_env = presence(ENV['TYRION_LANE']))
        story = store.story_with_pre_claim(epic['id'], "assigned:#{lane_env}")
        return store.update_story(story['id'], 'claimed_by' => token) if story
      end

      # Rung 4 — per-lane .tyrion/active-story file pin
      if (pinned_slug = Repo.active_story(token: token))
        story = store.find_story(epic['id'], pinned_slug)
        return story if story
      end

      # Rung 5 — sole unclaimed in_progress story (legacy single-session)
      story = store.story_in_progress_unclaimed(epic['id'])
      return story if story

      # Rung 6 — claim-next and stamp (only when claim_if_none: true)
      if claim_if_none
        story = store.claim_next_story(epic['id'], claimed_by: token)
        Repo.write_active_story(story['slug'], token: token) if token
        story
      end
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
