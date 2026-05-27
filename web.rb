#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Tyrion — Field Ops Ledger, StreamWeaver edition
# Usage: cd ~/work/tyrion && bundle exec ruby web.rb
#        Custom DB: TYRION_DB_PATH=~/.tyrion/custom.db bundle exec ruby web.rb

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('web/lib', __dir__))

require 'bundler/setup'
require 'tyrion'
require 'tyrion_web/data'
require 'tyrion_web/presenter'
require 'stream_weaver'

CSS_PATH = File.expand_path('web/assets/tyrion.css', __dir__)

# ── Layout: tyrion_shell ────────────────────────────────────────────────────────
#
# Exclusive layout — opts out of StreamWeaver's default h1/body-padding/
# #app-container chrome.  The body flexes as a column:
#   render_slot(:header)  → .t-topbar  (height: 68px, flex-shrink: 0)
#   main_content_region   → #app-container (.t-sidebar + .t-main inside)
StreamWeaver.register_layout(:tyrion_shell,
  exclusive:    true,
  body_classes: %w[tyrion-shell],
  css_path:     CSS_PATH) do
  render_slot(:header)
  main_content_region
end

# ── Screen helpers ───────────────────────────────────────────────────────────────
# Mixed into the App's singleton class via components: [TyrionScreens].
# All DSL methods (div, button, text, text_field, …) are available as self.xxx.
module TyrionScreens
  P = TyrionWeb::Presenter  # shorthand

  TABS = [
    { screen: 'active',      icon: '📖', label: 'Active Story' },
    { screen: 'roadmap',     icon: '🗺', label: 'Roadmap'      },
    { screen: 'warroom',     icon: '⚔',  label: 'War Room'     },
    { screen: 'discoveries', icon: '💡', label: 'Discoveries'  },
    { screen: 'global',      icon: '🌍', label: 'Global View'  },
    { screen: 'about',       icon: '❓', label: 'About'        },
  ].freeze

  # ── Sidebar ─────────────────────────────────────────────────────────────────

  def render_sidebar(stories, disc, active_story, state)
    # Navigation tabs
    div(class: 't-nav-group') do
      TABS.each do |tab|
        css = state[:screen] == tab[:screen] ? 't-nav-item t-nav-active' : 't-nav-item'
        button("#{tab[:icon]}  #{tab[:label]}",
               id: "nav_#{tab[:screen]}", style: :none, class: css) do |st|
          st[:screen] = tab[:screen]
          st
        end
      end
    end

    # Stories in current epic
    if stories.any?
      div(class: 't-sidebar-section') { text 'Stories' }
      stories.each do |s|
        s_status = s['status']
        row_cls  = 't-story-row'
        row_cls += ' t-story-active' if s_status == 'in_progress'
        row_cls += ' t-story-done'   if s_status == 'done'
        glyph    = s_status == 'pending' ? '○' : '●'
        target   = s_status == 'in_progress' ? 'active' : 'roadmap'
        div(class: row_cls) do
          div(class: s_status == 'in_progress' ? 't-story-icon t-story-icon-pulse' : 't-story-icon') do
            button(glyph, id: "si_#{s['id']}", style: :none) do |st|
              st[:screen] = target; st
            end
          end
          div(class: 't-story-name') do
            button(s['slug'], id: "srow_#{s['id']}", style: :none) do |st|
              st[:screen] = target; st
            end
          end
        end
      end
    end

    # Discovery strip
    if disc[:spike] || disc[:ready_count] > 0 || disc[:mark_count] > 0
      div(class: 't-disc-strip') do
        div(class: 't-sidebar-section') { text 'Discoveries' }
        if disc[:spike]
          q = disc[:spike]['question']&.slice(0, 38) || 'active spike'
          button("⚗  #{q}", id: 'nav_disc_spike', style: :none, class: 't-disc-row') do |st|
            st[:screen] = 'discoveries'; st
          end
        end
        if disc[:ready_count] > 0
          button("✦  #{disc[:ready_count]} ready → promote",
                 id: 'nav_disc_ready', style: :none, class: 't-disc-row') do |st|
            st[:screen] = 'discoveries'; st
          end
        end
        if disc[:mark_count] > 0
          button("·  #{disc[:mark_count]} marks",
                 id: 'nav_disc_marks', style: :none, class: 't-disc-row') do |st|
            st[:screen] = 'discoveries'; st
          end
        end
      end
    end
  end

  # ── Active Story ─────────────────────────────────────────────────────────────

  def render_active_story(story, criteria, notes, base, state)
    # Attention rail — stale warning
    if story && P.stale?(story['last_note_at'])
      div(class: 't-attention-rail') do
        div(class: 't-rail-item urgent') do
          text "⚡ #{story['slug']} — #{P.stale_label(story['last_note_at'])}"
        end
      end
    end

    div(class: 't-outer') do
      div(class: 't-parchment') do
        if story
          render_story_hero(story)
          render_context_next_action(story, state)
          render_criteria(story, criteria) if criteria.any?
          render_notes(notes)              if notes.any?
          render_quick_note_form(story['id'], state)
        else
          render_no_story_state(base)
        end
      end
    end
  end

  def render_story_hero(story)
    div(class: 't-status-badge t-status-in-progress') do
      div(class: 't-dot t-dot-pulse') { text '●' }
      text '  in_progress'
      if story['last_note_at']
        div(style: 'margin-left:14px;font-size:11px;opacity:.65;') do
          text "last note #{P.time_ago(story['last_note_at'])}"
        end
      end
    end
    div(class: 't-hero-title') { text story['slug'] }
    if story['title'] && story['title'] != story['slug']
      div(style: 'font-size:15px;color:var(--ink-dim);margin:-6px 0 14px;font-style:italic;font-family:var(--font-display);') do
        text story['title']
      end
    end
  end

  def render_context_next_action(story, state)
    ctx = story['current_context'].to_s.strip
    na  = story['next_action'].to_s.strip
    div(class: 't-split') do
      div(class: 't-block') do
        div(class: 't-block-label') { text 'Current Context' }
        div(class: 't-block-text') { text ctx.empty? ? '(none — set with: tyrion context <slug> "…")' : ctx }
      end
      div(class: 't-block') do
        div(class: 't-block-label') { text 'Next Action' }
        div(class: 't-block-text') { text na.empty? ? '(not set — use: tyrion next <slug> "…")' : na }
      end
    end
  end

  def render_criteria(story, criteria)
    sid = story['id']
    div(class: 't-crit-section') do
      met   = criteria.count { |c| c['status'] == 'met' }
      div(class: 't-crit-label') { text "Criteria · #{met}/#{criteria.size} met" }
      criteria.each do |c|
        is_met  = c['status'] == 'met'
        pos     = c['position']
        btn_id  = "crit_#{c['id'][0, 8]}_#{is_met ? 'u' : 'c'}"
        btn_cls = "t-crit-check#{is_met ? ' met' : ''}"
        div(class: 't-crit-row') do
          button(is_met ? '✓' : ' ', id: btn_id, style: :none, class: btn_cls) do |st|
            store = Tyrion::Store.new
            if is_met
              store.uncheck_criterion(sid, pos)
            else
              store.check_criterion(sid, pos, 'checked via UI')
            end
            st
          end
          div(class: "t-crit-text#{is_met ? ' met' : ''}") { text c['text'] }
        end
      end
    end
  end

  def render_notes(notes)
    div(class: 't-notes-section') do
      div(class: 't-crit-label') { text 'Recent Notes' }
      notes.first(5).each do |note|
        div(class: 't-note-entry') do
          div(class: 't-note-meta') { text "#{note['kind']} · #{P.time_ago(note['created_at'])}" }
          div(class: 't-note-body') { text note['body'] }
        end
      end
    end
  end

  def render_quick_note_form(story_id, state)
    state[:_qnote] ||= ''
    div(class: 't-quick-note-form',
        style: 'margin-top:24px;display:flex;align-items:center;gap:8px;') do
      text_field(:_qnote, placeholder: 'progress note…', submit: false,
                 style: 'flex:1;background:rgba(255,255,255,.5);border:1px solid var(--ink-faint);border-radius:4px;padding:7px 10px;font-size:13px;font-family:var(--font-mono);color:var(--ink);')
      button('+ Note', id: "qnote_#{story_id[0, 8]}", style: 'background:var(--ink);color:var(--parchment);border:none;padding:7px 14px;border-radius:4px;font-size:12px;font-family:var(--font-mono);cursor:pointer;') do |st|
        body = st[:_qnote].to_s.strip
        unless body.empty?
          Tyrion::Store.new.add_note(story_id, :progress, body)
        end
        st[:_qnote] = ''
        st
      end
    end
  end

  def render_no_story_state(base)
    div(style: 'text-align:center;padding:60px 0;') do
      div(style: 'font-size:52px;opacity:.22;margin-bottom:18px;') { text '⚡' }
      div(style: 'font-family:Cinzel,serif;font-size:22px;color:var(--ink-dim);') do
        text base[:epic] ? 'No story in progress' : 'No active project'
      end
      div(style: 'font-size:14px;color:var(--ink-faint);margin-top:10px;font-family:var(--font-mono);') do
        text base[:epic] ? "tyrion claim #{base[:epic]['slug']}" : 'tyrion project activate <slug>'
      end
    end
  end

  # ── Roadmap ───────────────────────────────────────────────────────────────────

  def render_roadmap(project, epic, _state)
    d    = TyrionWeb::Data.load_roadmap_view
    pres = TyrionWeb::Presenter
    div(class: 't-outer') do
      div(class: 't-parchment') do
        div(class: 't-block-label', style: 'margin-bottom:6px;') { text 'Campaign Ledger' }
        div(class: 't-hero-title') { text project ? (project['name'] || project['slug']) : 'No Project' }
        if d[:epics].any?
          done_n = d[:epics].count { |e| e['status'] == 'done' }
          div(style: 'font-size:12px;color:var(--ink-muted);margin-bottom:20px;font-family:var(--font-mono);') do
            text "♜ #{done_n} of #{d[:epics].size} epics complete"
          end
          d[:epics].each do |ep|
            is_active = epic && ep['id'] == epic['id']
            seal      = pres.epic_seal_glyph(ep, epic&.dig('id'))
            ep_stories = is_active ? d[:stories] : []
            done_s    = ep_stories.count { |s| s['status'] == 'done' }
            div(style: "margin-bottom:14px;padding:12px 14px;background:#{is_active ? 'rgba(255,255,255,.1)' : 'rgba(255,255,255,.04)'};border:1px solid rgba(159,119,64,.2);border-radius:8px;") do
              mb = is_active ? '8' : '0'
              div(style: "display:flex;align-items:center;gap:10px;margin-bottom:#{mb}px;") do
                div(style: 'font-size:14px;opacity:.7;') { text seal }
                div(style: 'font-family:Cinzel,serif;font-size:13px;color:var(--ink-dim);') { text ep['slug'] }
                div(style: 'margin-left:auto;font-size:11px;font-family:var(--font-mono);opacity:.5;') do
                  text is_active ? "#{done_s}/#{ep_stories.size} stories" : ep['status']
                end
              end
              if is_active && ep_stories.any?
                ep_stories.each do |s|
                  glyph   = s['status'] == 'pending' ? '○' : '●'
                  s_color = case s['status']
                            when 'done'        then 'color:var(--emerald)'
                            when 'in_progress' then 'color:var(--amber)'
                            else 'color:var(--ink-faint)'
                            end
                  div(style: "display:flex;align-items:center;gap:8px;padding:4px 0;font-size:12px;font-family:var(--font-mono);") do
                    div(style: s_color) { text glyph }
                    div(style: 'color:var(--ink-muted);') { text s['slug'] }
                  end
                end
              end
            end
          end
        else
          div(style: 'color:var(--ink-faint);font-style:italic;padding:20px 0;') { text 'No epics yet' }
        end
      end
    end
  end

  # ── Discoveries ──────────────────────────────────────────────────────────────

  def render_discoveries(project, _state)
    d = project ? TyrionWeb::Data.load_discoveries_view : { spike: nil, findings_ready: [], marks: [] }
    div(class: 't-outer') do
      div(class: 't-parchment') do
        div(class: 't-hero-title') { text 'Discoveries' }

        if d[:spike]
          div(class: 't-block', style: 'margin-bottom:16px;border-left:2px solid var(--violet);') do
            div(class: 't-block-label') { text '⚗  Active Spike' }
            div(class: 't-block-text') { text d[:spike]['question'] || '(no question set)' }
          end
        end

        if d[:findings_ready].any?
          div(class: 't-crit-label', style: 'margin:20px 0 10px;') do
            text "Findings Ready (#{d[:findings_ready].size})"
          end
          d[:findings_ready].each do |disc|
            div(class: 't-block', style: 'margin-bottom:8px;') do
              div(class: 't-block-text') { text disc['question'] || '(untitled discovery)' }
            end
          end
        end

        if d[:marks].any?
          div(class: 't-crit-label', style: 'margin:20px 0 10px;') do
            text "Marks · Unformalized (#{d[:marks].size})"
          end
          d[:marks].each do |disc|
            div(class: 't-block', style: 'margin-bottom:8px;opacity:.7;') do
              div(class: 't-block-text') { text disc['question'] || '(no question)' }
            end
          end
        end

        if !d[:spike] && d[:findings_ready].empty? && d[:marks].empty?
          div(style: 'text-align:center;padding:48px 0;') do
            div(style: 'font-size:40px;opacity:.2;margin-bottom:16px;') { text '💡' }
            div(style: 'color:var(--ink-faint);font-style:italic;') { text 'No discoveries yet' }
          end
        end
      end
    end
  end

  # ── War Room ─────────────────────────────────────────────────────────────────

  def render_warroom(project, _state)
    d = project ? TyrionWeb::Data.load_war_room_view : { queue: [], active: [], blocked: [], done: [] }
    div(class: 't-outer') do
      div(class: 't-parchment') do
        div(class: 't-hero-title') { text 'War Room' }
        div(class: 't-split') do
          render_kanban_col('Queue', d[:queue], '#')
          render_kanban_col('⚡ In Progress', d[:active], 'var(--amber)')
        end
        div(class: 't-split', style: 'margin-top:12px;') do
          render_kanban_col('✗ Blocked', d[:blocked], 'var(--crimson)')
          render_kanban_col('✓ Done (recent)', d[:done], 'var(--emerald)')
        end
      end
    end
  end

  def render_kanban_col(label, items, _accent)
    div(class: 't-block') do
      div(class: 't-block-label') { text label }
      if items.any?
        items.each do |s|
          div(style: 'padding:6px 0;border-bottom:1px solid rgba(159,119,64,.1);font-size:12px;font-family:var(--font-mono);color:var(--ink-muted);') do
            text "#{s['epic_slug']} › #{s['slug']}"
          end
        end
      else
        div(style: 'font-size:12px;opacity:.4;font-style:italic;padding:4px 0;') { text 'none' }
      end
    end
  end

  # ── Global View ───────────────────────────────────────────────────────────────

  def render_global(_state)
    d = TyrionWeb::Data.load_global_view
    div(class: 't-outer') do
      div(class: 't-parchment') do
        div(class: 't-hero-title') { text 'Global View' }

        if d[:in_progress].any?
          div(class: 't-crit-label') { text "In Progress (#{d[:in_progress].size})" }
          d[:in_progress].each do |item|
            div(class: 't-block', style: 'margin-bottom:10px;') do
              div(style: 'display:flex;align-items:center;gap:8px;margin-bottom:6px;') do
                div(class: 't-block-label') do
                  text "#{item[:project]['slug']} › #{item[:epic]['slug']} › #{item[:story]['slug']}"
                end
              end
              if item[:story]['current_context']
                div(class: 't-block-text') { text item[:story]['current_context'] }
              end
              if item[:story]['next_action']
                div(style: 'font-size:12px;color:var(--amber-dim);font-family:var(--font-mono);margin-top:4px;') do
                  text "→ #{item[:story]['next_action']}"
                end
              end
            end
          end
        else
          div(style: 'text-align:center;padding:48px 0;') do
            div(style: 'font-size:40px;opacity:.2;margin-bottom:16px;') { text '🌍' }
            div(style: 'color:var(--ink-faint);font-style:italic;') { text 'No stories in progress' }
          end
        end

        if d[:done_today].any?
          div(class: 't-crit-label', style: 'margin-top:24px;') do
            text "Done Today (#{d[:done_today].size})"
          end
          d[:done_today].each do |item|
            div(style: 'padding:4px 0;font-size:12px;font-family:var(--font-mono);color:var(--emerald);opacity:.8;') do
              text "✓ #{item[:project]['slug']} › #{item[:story]['slug']}"
            end
          end
        end
      end
    end
  end

  # ── About ─────────────────────────────────────────────────────────────────────

  def render_about(project, epic, _state)
    div(class: 't-outer') do
      div(class: 't-parchment') do
        div(class: 't-hero-title') { text project ? (project['name'] || project['slug']) : 'Tyrion' }
        div(style: 'font-size:13px;color:var(--ink-muted);margin-bottom:24px;font-family:var(--font-mono);') do
          text 'Small. Excellent. Running the realm.'
        end

        if project
          div(class: 't-block', style: 'margin-bottom:10px;') do
            div(class: 't-block-label') { text 'Active Project' }
            div(class: 't-block-text') { text project['slug'] }
          end
          if project['about_md']&.strip&.length.to_i > 0
            div(class: 't-block', style: 'margin-bottom:10px;') do
              div(class: 't-block-label') { text 'About' }
              div(class: 't-block-text') { text project['about_md'].slice(0, 500) }
            end
          end
        end

        if epic
          div(class: 't-block', style: 'margin-bottom:10px;') do
            div(class: 't-block-label') { text 'Active Epic' }
            div(class: 't-block-text') { text "#{epic['slug']} (#{epic['status']})" }
            if epic['intent']
              div(style: 'font-size:12px;color:var(--ink-faint);margin-top:4px;') { text epic['intent'] }
            end
          end
        end

        div(class: 't-block', style: 'margin-top:20px;') do
          div(class: 't-block-label') { text 'Quick Reference' }
          [
            'tyrion project activate <slug>   — set active project',
            'tyrion claim <epic-slug>          — start an epic',
            'tyrion next <story> "…"           — set next action',
            'tyrion note <story> progress "…" — add progress note',
            'tyrion check <story> N "…"        — check acceptance criterion',
            'tyrion done <story> "summary"     — mark story complete',
            'tyrion disc spike "question"      — start a discovery spike',
          ].each do |cmd|
            div(style: 'padding:3px 0;font-size:11px;font-family:var(--font-mono);color:var(--ink-muted);') do
              text cmd
            end
          end
        end
      end
    end
  end
end

# ── App ─────────────────────────────────────────────────────────────────────────

app 'Tyrion',
    layout:     :tyrion_shell,
    fonts:      [
      { google: 'Cinzel:wght@400;600;700' },
      { google: 'Lora:ital,wght@0,400;1,400;1,600' },
      { google: 'IBM+Plex+Mono:wght@300;400' }
    ],
    components: [TyrionScreens] do

  state[:screen] ||= 'active'

  # Load base data — always needed for topbar + sidebar
  base     = TyrionWeb::Data.load_active_story_view
  project  = base[:project]
  epic     = base[:epic]
  story    = base[:story]
  criteria = base[:criteria]
  notes    = base[:notes]
  stories  = base[:stories]
  disc     = base[:disc_summary]
  branch   = base[:git_branch]
  dirty    = base[:dirty_count].to_i

  # ── Topbar ──────────────────────────────────────────────────────────────────
  layout_slot(:header) do
    div(class: 't-topbar') do
      div(class: 't-brand') do
        div(class: 't-wordmark') { text 'TYRION' }
        div(class: 't-tagline') { text 'Small. Excellent. Running the realm.' }
      end
      if project || epic
        div(class: 't-crumb') do
          div(class: 't-crumb-seg') { text project['name'] || project['slug'] } if project
          div(class: 't-crumb-seg', style: 'opacity:.4;') { text '›' } if project && epic
          div(class: 't-crumb-seg t-crumb-active') { text epic['slug'] } if epic
        end
      end
      div(class: 't-pills') do
        div(class: 't-pill') { text "⎇  #{branch}" }
        if dirty > 0
          div(class: 't-pill t-pill-amber') { text "✗ #{dirty} dirty" }
        else
          div(class: 't-pill') { text '✓ clean' }
        end
      end
    end
  end

  # ── Sidebar ──────────────────────────────────────────────────────────────────
  div(class: 't-sidebar') do
    render_sidebar(stories, disc, story, state)
  end

  # ── Main Content ─────────────────────────────────────────────────────────────
  div(class: 't-main') do
    case state[:screen]
    when 'active'
      render_active_story(story, criteria, notes, base, state)
    when 'roadmap'
      render_roadmap(project, epic, state)
    when 'discoveries'
      render_discoveries(project, state)
    when 'warroom'
      render_warroom(project, state)
    when 'global'
      render_global(state)
    when 'about'
      render_about(project, epic, state)
    else
      render_active_story(story, criteria, notes, base, state)
    end
  end

end.run!
