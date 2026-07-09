# frozen_string_literal: true

module Views
  class Layout < Phlex::HTML
    def initialize(project:, epic:, stories: [], disc_summary: {}, active_tab: :active,
                   git_branch: 'main', dirty_count: 0, project_slug: nil)
      @project     = project
      @epic        = epic
      @stories     = stories
      @disc_summary = disc_summary
      @active_tab  = active_tab
      @git_branch  = git_branch || 'unknown'
      @dirty_count = dirty_count.to_i
      @project_slug = project_slug
    end

    TABS = [
      { id: :warroom,     path: '/warroom',     icon: '⚔',  label: 'War Room'     },
      { id: :roadmap,     path: '/roadmap',     icon: '🗺', label: 'Roadmap'      },
      { id: :active,      path: '/',            icon: '📖', label: 'Active Story' },
      { id: :global,      path: '/global',      icon: '🌍', label: 'Global View'  },
      { id: :discoveries, path: '/discoveries', icon: '💡', label: 'Discoveries'  },
      { id: :about,       path: '/about',       icon: '❓', label: 'About Tyrion' },
    ].freeze

    def view_template
      doctype
      html(lang: "en") do
        head do
          meta(charset: "UTF-8")
          meta(name: "viewport", content: "width=device-width, initial-scale=1.0")
          title { "Tyrion — Field Ops Ledger" }
          link(rel: "preconnect", href: "https://fonts.googleapis.com")
          link(href: "https://fonts.googleapis.com/css2?family=Cinzel:wght@400;600;700&family=Lora:ital,wght@0,400;1,400;1,600&family=IBM+Plex+Mono:wght@300;400&display=swap", rel: "stylesheet")
          link(rel: "stylesheet", href: "/shared.css")
        end
        body do
          div(class: "shell") do
            render_topbar
            render_sidebar
            yield
          end
        end
      end
    end

    private

    def nav_href(path)
      qs = []
      qs << "project=#{@project_slug}" if @project_slug
      qs << "epic=#{@epic['slug']}" if @epic
      qs.empty? ? path : "#{path}?#{qs.join('&')}"
    end

    def render_topbar
      div(class: "topbar") do
        div(class: "topbar-main") do
          div(class: "topbar-brand") do
            img(src: "/assets/LionCrest.png", alt: "Tyrion",
                style: "height:44px;width:auto;margin-right:10px;vertical-align:middle;")
            span(style: "font-family:'Cinzel',serif;font-size:24px;font-weight:700;color:var(--gold-bright);letter-spacing:0.12em;") { "TYRION" }
          end
          if @project
            span(class: "topbar-sep") { "·" }
            proj_label = (@project['slug'] || @project['name'] || '')
            span(class: "topbar-crumb") { proj_label.length > 26 ? "#{proj_label[0..25]}…" : proj_label }
          end
          if @epic
            span(class: "topbar-sep") { "·" }
            epic_label = @epic['slug'] || ''
            span(class: "topbar-crumb active") { epic_label.length > 22 ? "#{epic_label[0..21]}…" : epic_label }
          end
          div(class: "topbar-git") do
            branch = @git_branch.length > 28 ? "#{@git_branch[0..27]}…" : @git_branch
            span(class: "pill pill-neutral") { "⎇ #{branch}" }
            if @dirty_count > 0
              span(class: "pill pill-amber") { "✗ #{@dirty_count}" }
            else
              span(class: "pill pill-neutral") { "✓ clean" }
            end
          end
        end
        div(class: "topbar-nav") do
          TABS.each do |tab|
            is_active = @active_tab == tab[:id]
            href = nav_href(tab[:path])
            a(class: is_active ? "demo-tab active" : "demo-tab",
              href: href,
              style: "text-decoration:none;") do
              plain "#{tab[:icon]} #{tab[:label]}"
            end
          end
        end
      end
    end

    def render_sidebar
      div(class: "sidebar") do
        if @project && @epic
          div(style: "padding:10px 14px 0;font-size:12px;color:var(--text-dim);font-family:var(--font-mono);") do
            plain "#{@project['slug']} › #{@epic['slug']}"
          end
          div(class: "sidebar-section") { "Stories · #{@epic['slug']}" }

          @stories.each do |s|
            s_status = s['status']
            row_class = case s_status
                        when 'done'        then 'story-row done'
                        when 'in_progress' then 'story-row active'
                        else 'story-row'
                        end
            icon_color = case s_status
                         when 'done'        then 'var(--emerald)'
                         when 'in_progress' then 'var(--amber)'
                         else 'var(--ink-faint)'
                         end
            icon_glyph = s_status == 'pending' ? '○' : '●'
            href = s_status == 'in_progress' ? nav_href('/') : "/stories/#{s['id']}"

            a(class: row_class, href: href, style: "text-decoration:none;") do
              span(class: s_status == 'in_progress' ? 's-icon s-icon-pulse' : 's-icon',
                   style: "color:#{icon_color}") { icon_glyph }
              span(class: "s-name") { s['slug'] }
            end
          end

          disc = @disc_summary
          if disc[:spike] || disc[:ready_count] > 0 || disc[:mark_count] > 0
            div(class: "disc-strip") do
              div(class: "sidebar-section") { "Discoveries" }
              if disc[:spike]
                a(class: "disc-row", href: "/discoveries", style: "text-decoration:none;") do
                  span(class: "d-pill spike") { "spike" }
                  span(class: "d-label") { disc[:spike]['question']&.slice(0, 40) || "active spike" }
                end
              end
              if disc[:ready_count] > 0
                a(class: "disc-row", href: "/discoveries", style: "text-decoration:none;") do
                  span(class: "d-pill ready") { "#{disc[:ready_count]} ready" }
                  span(class: "d-label") { "promote to story →" }
                end
              end
              if disc[:mark_count] > 0
                a(class: "disc-row", href: "/discoveries", style: "text-decoration:none;") do
                  span(class: "d-pill mark") { "#{disc[:mark_count]} marks" }
                  span(class: "d-label") { "unformalized" }
                end
              end
            end
          end
        else
          div(style: "padding:16px 14px;font-size:13px;color:var(--text-muted);") do
            plain "No active project"
          end
        end
      end
    end

  end
end
