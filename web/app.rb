#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Tyrion Web UI — Sinatra + Phlex prototype
# Usage: cd apps/tyrion && bundle exec ruby app.rb
# Or via app-ctl: bin/app-ctl start tyrion

require "sinatra"
require "phlex"
require "phlex-sinatra"

$LOAD_PATH.unshift(File.join(__dir__, "lib"))
$LOAD_PATH.unshift(File.join(__dir__, "..", "lib"))

require "tyrion"
require "tyrion_web/presenter"
require "tyrion_web/data"

Dir[File.join(__dir__, "views", "**", "*.rb")].sort.each { |f| require f }

set :port, (ENV["TYRION_PORT"] || 4579).to_i
set :bind, "0.0.0.0"
set :public_folder, File.join(__dir__, "public")
set :server, :puma
disable :protection
set :host_authorization, { permitted_hosts: [] }
enable :sessions
set :session_secret, ENV.fetch('TYRION_SESSION_SECRET', SecureRandom.hex(32))

helpers do
  def store
    TyrionWeb::Data.store
  end

  def sidebar_data(project, epic)
    TyrionWeb::Data.load_sidebar_data(project, epic)
  end

  def base_git
    {
      git_branch: TyrionWeb::Data.safe_git_branch,
      dirty_count: TyrionWeb::Data.safe_dirty_count
    }
  end

  def with_flash(success_msg)
    yield
    session[:flash] = success_msg
  rescue StandardError => e
    session[:flash] = "Error: #{e.message}"
  ensure
    redirect "/"
  end

  def with_epic_flash
    slug = params[:project]
    proj = slug ? store.find_project_by_slug(slug) : TyrionWeb::Data.resolve_active_project
    raise "project not found" unless proj
    epic = store.find_epic(proj['id'], params[:slug])
    raise "epic not found" unless epic
    session[:flash] = yield(epic)
  rescue StandardError => e
    session[:flash] = "Error: #{e.message}"
  ensure
    redirect "/roadmap#{"?project=#{slug}" if slug}"
  end

  # with_flash hardcodes redirect "/" (the Active Story page) — wrong for discovery
  # mutations, which need to land back on the discovery itself or wherever the
  # action was triggered from (e.g. the ambient pane). params[:return_to] lets a
  # caller (the ambient inline-expand form) redirect somewhere other than the
  # discovery's own page; absent, it defaults there, same shape as with_epic_flash.
  def with_discovery_flash(disc_id)
    session[:flash] = yield
  rescue StandardError => e
    session[:flash] = "Error: #{e.message}"
  ensure
    redirect safe_return_to(disc_id)
  end

  # params[:return_to] is user-controlled input reflected straight into a
  # redirect -- an open redirect (`return_to=//evil.com` or `return_to=https://evil.com`)
  # without validation. Only a same-site absolute path is accepted; anything
  # else (missing, protocol-relative "//", a full URL, or a leading backslash
  # -- some browsers still normalize "/\evil.com" to "//evil.com") falls back
  # to the discovery's own page.
  def safe_return_to(disc_id)
    back = params[:return_to]
    return "/discoveries/#{disc_id}" unless back.is_a?(String) && back.match?(%r{\A/[^/\\]})

    back
  end
end

# ── Active Story (default) ─────────────────────────────────────────────────────

get "/" do
  project_param = params[:project]&.strip&.then { |s| s.empty? ? nil : s }
  env_project   = ENV['TYRION_PROJECT']&.strip&.then { |s| s.empty? ? nil : s }
  redirect "/global" if project_param.nil? && env_project.nil?

  d = TyrionWeb::Data.load_active_story_view(project_slug: project_param, epic_slug: params[:epic])
  phlex Views::ActiveStory.new(
    project: d[:project], epic: d[:epic], story: d[:story],
    criteria: d[:criteria], notes: d[:notes],
    stories: d[:stories], disc_summary: d[:disc_summary],
    epic_switcher: d[:epic_switcher], epic_scope_mode: :scoped,
    git_branch: d[:git_branch], dirty_count: d[:dirty_count],
    flash: session[:flash].tap { session.delete(:flash) },
    project_slug: params[:project]
  )
end

# ── Roadmap ────────────────────────────────────────────────────────────────────

get "/roadmap" do
  d    = TyrionWeb::Data.load_roadmap_view(project_slug: params[:project])
  base = TyrionWeb::Data.load_sidebar_data(d[:project], d[:active_epic])
  phlex Views::RoadmapView.new(
    project: d[:project], active_epics: d[:active_epics], archived_epics: d[:archived_epics],
    active_epic: d[:active_epic],
    active_story: d[:active_story], stories_by_epic: d[:stories_by_epic], criteria: d[:criteria],
    sidebar_stories: base[:stories], disc_summary: base[:disc_summary],
    epic_switcher: base[:epic_switcher],
    project_slug: params[:project],
    flash: session.delete(:flash),
    **base_git
  )
end

# ── Global View ────────────────────────────────────────────────────────────────

get "/global" do
  d    = TyrionWeb::Data.load_global_view
  proj = TyrionWeb::Data.resolve_active_project
  epic = proj ? TyrionWeb::Data.resolve_active_epic(proj) : nil
  base = TyrionWeb::Data.load_sidebar_data(proj, epic)
  phlex Views::GlobalView.new(
    project_cards: d[:project_cards],
    project: proj, epic: epic, stories: base[:stories], disc_summary: base[:disc_summary],
    epic_switcher: base[:epic_switcher],
    **base_git
  )
end

# ── Discoveries ────────────────────────────────────────────────────────────────

get "/discoveries" do
  d    = TyrionWeb::Data.load_discoveries_view(project_slug: params[:project])
  epic = TyrionWeb::Data.resolve_active_epic(d[:project])
  base = TyrionWeb::Data.load_sidebar_data(d[:project], epic)
  phlex Views::DiscoveriesView.new(
    project: d[:project], spike: d[:spike],
    findings_ready: d[:findings_ready], marks: d[:marks],
    epic: epic,
    stories: base[:stories], disc_summary: base[:disc_summary],
    epic_switcher: base[:epic_switcher],
    project_slug: params[:project],
    **base_git
  )
end

get "/discoveries/:id" do
  d = TyrionWeb::Data.load_discovery_show_view(params[:id])
  unless d[:discovery]
    proj = TyrionWeb::Data.resolve_active_project
    epic = proj ? TyrionWeb::Data.resolve_active_epic(proj) : nil
    base = TyrionWeb::Data.load_sidebar_data(proj, epic)
    halt 404, phlex(Views::NotFoundView.new(
      message: "Discovery #{params[:id]} not found.",
      project: proj, epic: epic,
      stories: base[:stories], disc_summary: base[:disc_summary],
      epic_switcher: base[:epic_switcher],
      **base_git
    ))
  end
  flash = session.delete(:flash)
  phlex Views::DiscoveryShow.new(
    project: d[:project], epic: d[:epic], sidebar_epic: d[:sidebar_epic],
    discovery: d[:discovery], epics: d[:epics],
    stories: d[:stories], disc_summary: d[:disc_summary],
    epic_switcher: d[:epic_switcher],
    flash: flash,
    **base_git
  )
end

# ── Ambient pane ───────────────────────────────────────────────────────────────
#
# Standalone narrow surface for a browser pane split alongside a terminal —
# rendered without Views::Layout on purpose (no navbar, no sidebar, no chrome).

get "/ambient" do
  d = TyrionWeb::Data.load_ambient_view(project_slug: params[:project])
  phlex Views::Ambient.new(
    project: d[:project], marks: d[:marks], findings_ready_count: d[:findings_ready_count],
    # Seeding the first-render token means an unchanged first poll repaints nothing.
    token: TyrionWeb::Data.ambient_token(marks: d[:marks], findings_ready_count: d[:findings_ready_count]),
    # The inline Defer form redirects back here via return_to -- without
    # reading/rendering this, success and failure both looked identical
    # (nothing visibly happens), and the message would ambush an unrelated
    # page later instead.
    flash: session.delete(:flash)
  )
end

# Companion poll for the ambient pane. Resolution is deliberately the SAME call
# the page render uses (fallback to the active project included) — a stricter
# lookup here would have the poller disagree with what the page is showing and
# blank a pane that is rendering fine. 404 is reserved for "no project resolved
# at all," and even then the body is the renderable empty-state payload.
get "/api/ambient_poll" do
  content_type :json
  d       = TyrionWeb::Data.load_ambient_view(project_slug: params[:project])
  payload = TyrionWeb::Data.ambient_poll_payload(d)
  halt 404, payload.to_json unless d[:project]

  payload.to_json
end

# ── War Room ───────────────────────────────────────────────────────────────────

get "/warroom" do
  d    = TyrionWeb::Data.load_war_room_view(project_slug: params[:project], epic_slug: params[:epic])
  epic = d[:epic] || (d[:project] ? TyrionWeb::Data.resolve_active_epic(d[:project]) : nil)
  base = TyrionWeb::Data.load_sidebar_data(d[:project], epic)
  phlex Views::WarRoomView.new(
    project: d[:project], queue: d[:queue], active: d[:active],
    blocked: d[:blocked], done: d[:done],
    epic: epic, stories: base[:stories], disc_summary: base[:disc_summary],
    epic_switcher: base[:epic_switcher],
    project_slug: params[:project],
    **base_git
  )
end

# ── Story Detail ──────────────────────────────────────────────────────────────

get "/stories/:id" do
  d = TyrionWeb::Data.load_story_view(story_id: params[:id])
  unless d[:story]
    proj = TyrionWeb::Data.resolve_active_project
    epic = proj ? TyrionWeb::Data.resolve_active_epic(proj) : nil
    base = TyrionWeb::Data.load_sidebar_data(proj, epic)
    halt 404, phlex(Views::NotFoundView.new(
      message: "Story #{params[:id]} not found.",
      project: proj, epic: epic,
      stories: base[:stories], disc_summary: base[:disc_summary],
      epic_switcher: base[:epic_switcher],
      **base_git
    ))
  end
  story_tab = d[:story]['status'] == 'in_progress' ? :active : :warroom
  phlex Views::ActiveStory.new(
    project: d[:project], epic: d[:epic], story: d[:story],
    criteria: d[:criteria], notes: d[:notes],
    stories: d[:stories], disc_summary: d[:disc_summary],
    epic_switcher: d[:epic_switcher],
    git_branch: d[:git_branch], dirty_count: d[:dirty_count],
    flash: nil, active_tab: story_tab
  )
end

# ── Poll API ──────────────────────────────────────────────────────────────────

get "/api/poll" do
  content_type :json
  story_id = params[:story_id]
  halt 400, { error: 'missing story_id' }.to_json unless story_id

  story = store.find_story_by_id(story_id.to_s)
  halt 404, { error: 'not_found' }.to_json unless story

  criteria = store.criteria_for_story(story_id.to_s)
  met      = criteria.count { |c| c['status'] == 'met' }
  token    = "#{story['last_note_at']}:#{met}:#{story['status']}"

  { token: token, slug: story['slug'], status: story['status'], met: met, total: criteria.size }.to_json
end

# ── About ──────────────────────────────────────────────────────────────────────

get "/about" do
  proj = TyrionWeb::Data.resolve_active_project
  epic = proj ? TyrionWeb::Data.resolve_active_epic(proj) : nil
  base = TyrionWeb::Data.load_sidebar_data(proj, epic)
  phlex Views::AboutView.new(
    project: proj, epic: epic,
    stories: base[:stories], disc_summary: base[:disc_summary],
    epic_switcher: base[:epic_switcher],
    **base_git
  )
end

# ── Mutations (PRG pattern) ────────────────────────────────────────────────────

post "/stories/:id/criteria/:position/check" do
  with_flash("Criterion #{params[:position]} marked done.") do
    store.check_criterion(params[:id], params[:position].to_i, params[:evidence] || "checked via UI")
  end
end

post "/stories/:id/criteria/:position/uncheck" do
  with_flash("Criterion #{params[:position]} unchecked.") do
    store.uncheck_criterion(params[:id], params[:position].to_i)
  end
end

post "/stories/:id/notes" do
  body = params[:body]&.strip
  redirect "/" if body.nil? || body.empty?
  with_flash(nil) { store.add_note(params[:id], :progress, body) }
end

post "/stories/:id/context" do
  with_flash(nil) do
    text = params[:text]&.strip
    store.update_context(params[:id], text) if text
  end
end

post "/stories/:id/next_action" do
  with_flash(nil) do
    text = params[:text]&.strip
    store.update_next_action(params[:id], text) if text
  end
end

post "/epic/:slug/seal" do
  with_epic_flash do |epic|
    unlocked = Tyrion::Commands.seal_epic_and_report_unlocks(store, epic)
    msg = "Epic #{params[:slug]} sealed ✓"
    msg += " — unlocked: #{unlocked.map { |e| e['slug'] }.join(', ')}" unless unlocked.empty?
    msg
  end
end

post "/epic/:slug/unarchive" do
  with_epic_flash { |epic| store.unarchive_epic(epic['id']); "Epic #{params[:slug]} unarchived" }
end

post "/discoveries/:id/defer" do
  with_discovery_flash(params[:id]) do
    reason = params[:reason]&.strip
    store.defer_discovery(params[:id], reason: (reason.nil? || reason.empty?) ? nil : reason)
    "Discovery #{params[:id]} deferred"
  end
end

post "/discoveries/:id/promote" do
  with_discovery_flash(params[:id]) do
    disc = store.find_discovery(params[:id])
    raise "discovery not found" unless disc

    epic = store.find_epic(disc['project_id'], params[:epic_slug])
    raise "epic not found" unless epic

    title = params[:title]&.strip
    title = disc['question'] if title.nil? || title.empty?
    story = store.promote_discovery_to_story(
      params[:id], epic_id: epic['id'], slug: Tyrion::Commands.slugify(title),
      title: title, intent: disc['recommendation']
    )
    "Promoted to story #{story['slug']}"
  end
end

post "/discoveries/:id/headline" do
  with_discovery_flash(params[:id]) do
    headline = params[:headline]&.strip
    store.set_headline(params[:id], headline.nil? || headline.empty? ? nil : headline)
    "Headline updated"
  end
end
