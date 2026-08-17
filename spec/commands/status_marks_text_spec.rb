# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion status — marks lane' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'discovery-autonomy') }
  let(:store) { ctx.store }

  def mark(question)
    store.create_discovery(project_id: ctx.project['id'], status: 'mark', question: question)
  end

  def status_output
    capture_io { Tyrion::Commands.cmd_status([], store) }.first
  end

  it 'spells out each mark question instead of a bare count' do
    disc = mark('why does import re-hash every run?')

    out = status_output

    expect(out).to include('why does import re-hash every run?').and include(disc['id'])
    expect(out).not_to include('unformalized mark')
  end

  it 'shows the 3 most recently created marks, newest first' do
    %w[oldest second third newest].each { |q| mark(q) }

    lines = status_output.lines.grep(/oldest|second|third|newest/).map(&:strip)

    expect(lines.map { |l| l[/oldest|second|third|newest/] }).to eq %w[newest third second]
  end

  it 'adds a "(N more)" pointer when more than 3 marks exist' do
    5.times { |i| mark("m#{i}") }

    expect(status_output).to include('(2 more — tyrion discovery list --status marks)')
  end

  it 'omits the "(N more)" pointer at 3 marks or fewer' do
    3.times { |i| mark("m#{i}") }

    expect(status_output).not_to include('more — tyrion discovery list')
  end

  it 'keeps a paragraph-length mark to one line' do
    mark("#{'x' * 200} tail")

    line = status_output.lines.grep(/xxx/).first

    expect(line).to include('…')
    expect(line).not_to include('tail')
  end
end
