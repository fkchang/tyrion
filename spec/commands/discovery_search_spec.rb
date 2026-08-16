# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Tyrion::Commands.cmd_discovery_search' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'discovery-autonomy') }
  let(:store) { ctx.store }

  def make(status:, **fields)
    store.create_discovery(project_id: ctx.project['id'], status: status, **fields)
  end

  # create_discovery stamps created_at itself, so backdate directly to get a
  # deterministic newest-first ordering across distinct timestamps.
  def backdate(disc, seconds)
    SQLite3::Database.new(File.join(ctx.tmpdir, 'test.db')) do |db|
      db.execute(
        'UPDATE discoveries SET created_at = ? WHERE id = ?',
        [(Time.now - seconds).utc.strftime('%Y-%m-%dT%H:%M:%S.%6NZ'), disc['id']]
      )
    end
  end

  def search(*args)
    out, = capture_io { Tyrion::Commands.cmd_discovery_search(args, store) }
    out
  end

  context 'criterion 3 — AND across words, OR across question/finding/recommendation' do
    it 'matches when each word hits a different field' do
      disc = make(status: 'findings_ready', question: 'How do we cache epics?',
                  finding: 'The sidebar rerenders', recommendation: 'Memoize the query')
      expect(search('cache sidebar memoize')).to include(disc['id'])
    end

    it 'is case-insensitive' do
      disc = make(status: 'mark', question: 'SQLite WAL contention')
      expect(search('sqlite wal')).to include(disc['id'])
    end

    it 'excludes a discovery matching only some of the words' do
      disc = make(status: 'mark', question: 'SQLite WAL contention')
      expect(search('sqlite postgres')).not_to include(disc['id'])
    end

    it 'matches on finding alone' do
      disc = make(status: 'findings_ready', question: 'unrelated',
                  finding: 'Phlex components leak state')
      expect(search('phlex')).to include(disc['id'])
    end

    it 'matches on recommendation alone' do
      disc = make(status: 'findings_ready', question: 'unrelated',
                  recommendation: 'Adopt the lane token')
      expect(search('lane token')).to include(disc['id'])
    end
  end

  context 'criterion 4 — LIKE wildcards in the term are escaped, not expanded' do
    it 'treats % literally' do
      literal = make(status: 'mark', question: 'throughput dropped 50% under load')
      other   = make(status: 'mark', question: 'throughput is fine')

      out = search('50%')
      expect(out).to include(literal['id'])
      expect(out).not_to include(other['id'])
    end

    it 'treats _ literally' do
      literal = make(status: 'mark', question: 'rename source_story_id')
      other   = make(status: 'mark', question: 'rename sourceXstory')

      out = search('source_story')
      expect(out).to include(literal['id'])
      expect(out).not_to include(other['id'])
    end

    it 'does not let a bare % match everything' do
      make(status: 'mark', question: 'nothing to see here')
      expect(search('%')).to eq ''
    end

    it 'treats a backslash literally' do
      literal = make(status: 'mark', question: 'escape the \\n in output')
      other   = make(status: 'mark', question: 'escape the n in output')

      out = search('\\n')
      expect(out).to include(literal['id'])
      expect(out).not_to include(other['id'])
    end
  end

  context 'criterion 5 — no status is excluded by default' do
    it 'returns a hit in every discovery status' do
      statuses = %w[mark findings_ready active_spike deferred promoted_to_story invalidated]
      discs    = statuses.map { |s| make(status: s, question: "widget in #{s}") }

      out = search('widget')
      discs.each { |d| expect(out).to include(d['id']) }
    end

    it 'narrows to one status when --status is passed' do
      mark  = make(status: 'mark', question: 'widget one')
      ready = make(status: 'findings_ready', question: 'widget two')

      out = search('widget', '--status', 'marks')
      expect(out).to include(mark['id'])
      expect(out).not_to include(ready['id'])
    end

    it 'does not treat the --status alias as part of the search term' do
      disc = make(status: 'mark', question: 'widget one')
      expect(search('widget', '--status', 'marks')).to include(disc['id'])
    end
  end

  context 'criterion 6 — newest-first, one line per hit, id/status/snippet/age' do
    it 'orders newest first' do
      old = make(status: 'mark', question: 'widget older')
      backdate(old, 3600)
      recent = make(status: 'mark', question: 'widget newer')

      lines = search('widget').lines
      expect(lines.first).to include(recent['id'])
      expect(lines.last).to include(old['id'])
    end

    it 'prints one line per match' do
      3.times { |i| make(status: 'mark', question: "widget #{i}") }
      expect(search('widget').lines.size).to eq 3
    end

    it 'includes the id, status and age' do
      disc = make(status: 'findings_ready', question: 'widget alignment')
      line = search('widget')
      expect(line).to include(disc['id'])
      expect(line).to include('[findings_ready]')
      expect(line).to match(/\((just now|\d+[mhd] ago)\)$/)
    end

    it 'truncates the snippet to 60 characters' do
      long = 'widget ' + ('x' * 200)
      make(status: 'mark', question: long)

      snippet = search('widget')[/\]\s\s(.*?)\s\s\(/, 1]
      expect(snippet.length).to eq 60
      expect(snippet).to end_with('…')
    end

    it 'falls back to the finding when there is no question' do
      make(status: 'findings_ready', finding: 'widget alignment is off by one')
      expect(search('widget')).to include('widget alignment is off by one')
    end
  end

  context 'criterion 7 — blank term is a usage error, not a match-everything' do
    it 'exits 1 with usage for no term at all' do
      make(status: 'mark', question: 'widget')
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery_search([], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('Usage: tyrion discovery search')
    end

    it 'exits 1 with usage for an all-whitespace term' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery_search(['   '], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('Usage: tyrion discovery search')
    end

    it 'exits 1 when only --status is given' do
      _out, err = capture_io do
        expect do
          Tyrion::Commands.cmd_discovery_search(['--status', 'marks'], store)
        end.to raise_error(SystemExit)
      end
      expect(err).to include('Usage: tyrion discovery search')
    end
  end

  context 'criterion 8 — no matches is silent and exits 0' do
    it 'prints nothing and does not raise' do
      make(status: 'mark', question: 'something entirely different')
      out, err = capture_io { Tyrion::Commands.cmd_discovery_search(['widget'], store) }
      expect(out).to eq ''
      expect(err).to eq ''
    end
  end

  context 'criterion 9 — results are scoped to the active project' do
    it 'excludes a matching discovery belonging to another project' do
      other = store.create_project(slug: 'otherproj', name: 'Other')
      leaked = store.create_discovery(project_id: other['id'], status: 'mark',
                                      question: 'widget in the other project')
      mine   = make(status: 'mark', question: 'widget in my project')

      out = search('widget')
      expect(out).to include(mine['id'])
      expect(out).not_to include(leaked['id'])
    end
  end

  context 'criteria 10-12 — --status marks resolves to the mark status' do
    it 'lists only mark discoveries instead of dying on an unknown alias' do
      mark  = make(status: 'mark', question: 'a bookmark')
      ready = make(status: 'findings_ready', question: 'a finding')

      out, = capture_io { Tyrion::Commands.cmd_discovery_list(['--status', 'marks'], store) }
      expect(out).to include(mark['id'])
      expect(out).not_to include(ready['id'])
    end

    it 'lists marks in the valid-alias error message' do
      _out, err = capture_io do
        expect do
          Tyrion::Commands.cmd_discovery_list(['--status', 'bogus'], store)
        end.to raise_error(SystemExit)
      end
      expect(err).to include('marks')
    end
  end

  context 'dispatch' do
    it 'routes tyrion discovery search through cmd_discovery' do
      disc = make(status: 'mark', question: 'widget alignment')
      out, = capture_io { Tyrion::Commands.cmd_discovery(['search', 'widget'], store) }
      expect(out).to include(disc['id'])
    end

    it 'names search in the unknown-subcommand usage hint' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery(['bogus'], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('search')
    end
  end
end
