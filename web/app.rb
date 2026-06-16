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
end

# ── Active Story (default) ─────────────────────────────────────────────────────

get "/" do
  d = TyrionWeb::Data.load_active_story_view(project_slug: params[:project])
  phlex Views::ActiveStory.new(
    project: d[:project], epic: d[:epic], story: d[:story],
    criteria: d[:criteria], notes: d[:notes],
    stories: d[:stories], disc_summary: d[:disc_summary],
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
    project: d[:project], epics: d[:epics], active_epic: d[:active_epic],
    active_story: d[:active_story], stories_by_epic: d[:stories_by_epic], criteria: d[:criteria],
    sidebar_stories: base[:stories], disc_summary: base[:disc_summary],
    project_slug: params[:project],
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
    project_slug: params[:project],
    **base_git
  )
end

# ── War Room ───────────────────────────────────────────────────────────────────

get "/warroom" do
  d    = TyrionWeb::Data.load_war_room_view(project_slug: params[:project])
  epic = d[:project] ? TyrionWeb::Data.resolve_active_epic(d[:project]) : nil
  base = TyrionWeb::Data.load_sidebar_data(d[:project], epic)
  phlex Views::WarRoomView.new(
    project: d[:project], queue: d[:queue], active: d[:active],
    blocked: d[:blocked], done: d[:done],
    epic: epic, stories: base[:stories], disc_summary: base[:disc_summary],
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
      **base_git
    ))
  end
  story_tab = d[:story]['status'] == 'in_progress' ? :active : :warroom
  phlex Views::ActiveStory.new(
    project: d[:project], epic: d[:epic], story: d[:story],
    criteria: d[:criteria], notes: d[:notes],
    stories: d[:stories], disc_summary: d[:disc_summary],
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
