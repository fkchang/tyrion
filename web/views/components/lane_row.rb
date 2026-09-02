# frozen_string_literal: true

module Views
  module Components
    # The single lane row renderer shared by the Fleet board and (phase 2)
    # the epic cockpit's Now tab -- one row per Tyrion::Liveness lane_row hash
    # from Liveness::Snapshot.current. Renders glyph, lane label, story link,
    # met/total, the newest-per-source signals, and the evidence marker.
    #
    # Every per-source signal carries its own data-at epoch (a leaf <span>
    # with no children) so the page can tick relative ages client-side
    # between reloads without a token change (fleet-board's UAT criterion).
    # data-at deliberately never sits on a container: the client-side ticker
    # does `el.textContent = ...`, which would wipe every child of an element
    # holding one -- see spec/fleet_data_spec.rb's regression guard.
    class LaneRow < Phlex::HTML
      # Order matches the design's own worked example ("edit 40s · commit 6m
      # · note 9m · gate 38m · process live"). claimed/started/updated feed
      # newest_at but aren't surfaced as their own signal chips -- they'd be
      # redundant with the row's other fields (lane age, met/total).
      SIGNAL_KEYS = %w[edit commit note gate].freeze

      def initialize(row:)
        @row = row
      end

      def view_template
        div(class: "lane-row") do
          render_glyph
          span(class: "lane-label") { @row['lane'] }
          render_story_link
          render_progress
          render_signals
          render_process
          render_resolution
          render_evidence
        end
      end

      private

      def render_glyph
        g = TyrionWeb::Presenter.liveness_glyph(@row['display_state'])
        span(class: "lane-glyph #{g[:css]}", title: g[:label]) { g[:glyph] }
      end

      def render_story_link
        a(class: "lane-story", href: "/stories/#{@row['story_id']}") { @row['slug'] }
      end

      def render_progress
        return unless @row['total'].to_i.positive?

        span(class: "lane-progress") { "#{@row['met']}/#{@row['total']}" }
      end

      # Liveness.lane_row always builds a full signals hash (never nil), so
      # this trusts the shape rather than re-guarding what lane A already
      # guarantees -- see liveness.rb's own "a fallback that can never fire
      # reads as a safety net that isn't."
      def render_signals
        signals = @row['signals']
        div(class: "lane-signals") do
          SIGNAL_KEYS.each do |key|
            ts = signals[key]
            next unless ts

            span(class: "lane-sig", data: { at: ts, label: key }) do
              "#{key} #{TyrionWeb::Presenter.time_ago_epoch(ts)}"
            end
          end
        end
      end

      def render_process
        state = @row.dig('signals', 'process')
        return unless state && state != 'unknown'

        span(class: "lane-process") { "process #{state}" }
      end

      # Only for the two resolver failure states -- a normal `resolved`
      # lookup has nothing worth naming on the row itself.
      def render_resolution
        label = TyrionWeb::Presenter.resolution_label(@row['resolution_state'])
        return unless label

        span(class: "lane-resolution") { label }
      end

      def render_evidence
        return unless @row['evidence'] == Tyrion::Liveness::EVIDENCE_LEDGER

        span(class: "lane-evidence") { Tyrion::Liveness::EVIDENCE_LEDGER }
      end
    end
  end
end
