# frozen_string_literal: true

require_relative '../bin/tyrion_backup'

# bin/tyrion_backup.rb only *defines* run!/keep?/prunable?/parse_options -- it
# never calls run! itself (only the separate bin/tyrion-backup shim does, and
# this spec never requires that shim), so requiring it here is safe: no real
# backup runs. TODAY is fixed at require time (Date.today) -- every date in
# this spec is expressed relative to it, so the spec never rots.
RSpec.describe 'tyrion-backup retention' do
  describe '#keep?' do
    it 'keeps every snapshot in the daily window (0-14 days ago)' do
      expect(keep?(Date.today)).to be true
      expect(keep?(Date.today - 14)).to be true
    end

    it 'in the weekly window (15-56 days ago), keeps only Sundays' do
      (15..56).each do |age|
        date = Date.today - age
        expect(keep?(date)).to eq(date.sunday?),
          "age #{age} (#{date.strftime('%A')}): expected keep? == #{date.sunday?}"
      end
    end

    it 'beyond the weekly window (57+ days ago), keeps only the 1st of the month' do
      far_back       = Date.today << 6 # 6 calendar months back -- comfortably past 56 days regardless of month lengths
      first_of_month = Date.new(far_back.year, far_back.month, 1)
      mid_month      = Date.new(far_back.year, far_back.month, 15)

      expect(keep?(first_of_month)).to be true
      expect(keep?(mid_month)).to be false
    end
  end

  describe '#prunable?' do
    it 'ignores files that are not tyrion-YYYYMMDD.db[.gz] snapshots' do
      expect(prunable?('/tmp/backups/README.md')).to be false
      expect(prunable?('/tmp/backups/tyrion-notadate.db.gz')).to be false
    end

    it 'matches both the compressed and gzip-failure-uncompressed naming' do
      old_stamp = (Date.today - 100).strftime('%Y%m%d')
      expect(prunable?("/tmp/backups/tyrion-#{old_stamp}.db.gz")).to be true
      expect(prunable?("/tmp/backups/tyrion-#{old_stamp}.db")).to be true
    end
  end

  describe '#parse_options' do
    it 'dies with a usage message on an unrecognized flag, without a raw backtrace' do
      expect { parse_options(['--bogus']) }.to raise_error(SystemExit)
        .and output(/unknown option --bogus/).to_stderr
    end

    it 'dies with a clear message when --db is given no value' do
      expect { parse_options(['--db']) }.to raise_error(SystemExit)
        .and output(/--db needs a path/).to_stderr
    end

    it 'defaults db/dest when no flags are given' do
      options = parse_options([])
      expect(options[:db]).to eq(ENV['TYRION_DB_PATH'] || File.expand_path('~/.tyrion/tyrion.db'))
      expect(options[:dest]).to eq(File.expand_path('~/.tyrion/backups'))
    end
  end
end
