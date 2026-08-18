# frozen_string_literal: true

# tyrion-backup — nightly snapshot of ~/.tyrion/tyrion.db with GFS-lite retention.
#
# Why sqlite3 .backup and not `cp`: tyrion opens its DB in WAL mode (see
# lib/tyrion/store.rb). A plain file copy can grab the main .db file mid-write,
# out of sync with the -wal file that hasn't been checkpointed yet. `sqlite3
# <src> ".backup <dest>"` uses SQLite's own backup API, which is safe against a
# live, concurrently-written database regardless of journal mode.
#
# Retention (GFS-lite, no external gem):
#   - 0-14 days ago:  every daily snapshot kept
#   - 15-56 days ago: only Sunday's snapshot kept (~6 weekly points)
#   - 57+ days ago:   only the 1st-of-month snapshot kept (unbounded, but sparse)
#
# Personal dev-box script — not packaged in tyrion.gemspec, wired up via
# ~/Library/LaunchAgents/com.forrest.tyrion-backup.plist (nightly, 2am).
#
# This file holds all the logic and is require-able (spec/tyrion_backup_spec.rb
# does exactly that); bin/tyrion-backup is the thin executable entry point.

require 'date'
require 'fileutils'

DAILY_WINDOW_DAYS  = 14
WEEKLY_WINDOW_DAYS = 56
TODAY  = Date.today
PREFIX = "[tyrion-backup #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}]"

def log(message)
  puts "#{PREFIX} #{message}"
end

def die(message)
  abort "#{PREFIX} #{message}"
end

def parse_options(argv)
  options = { db: ENV['TYRION_DB_PATH'] || File.expand_path('~/.tyrion/tyrion.db'),
              dest: File.expand_path('~/.tyrion/backups') }

  until argv.empty?
    flag = argv.shift
    case flag
    when '--db'   then options[:db]   = argv.shift or die('--db needs a path')
    when '--dest' then options[:dest] = argv.shift or die('--dest needs a directory')
    else die("unknown option #{flag} (usage: tyrion-backup [--db PATH] [--dest DIR])")
    end
  end

  options
end

# `system('sqlite3', ...)` below is the multi-arg form: no shell is involved,
# so String#shellescape is the wrong tool -- it escapes for a POSIX shell to
# parse later, but this string is parsed by sqlite3's own dot-command
# tokenizer instead. Verified empirically (not assumed) against that
# tokenizer: double-quote wrapping with no further escaping handles both a
# space and an embedded apostrophe in the path; shellescape's backslash
# style does not (its escaped space is still read as a token separator).
def sqlite_dot_arg(path)
  ".backup \"#{path}\""
end

# Staged under a pid-qualified name, then renamed into place. Rename is atomic
# on the same filesystem and overwrites in one step -- today's existing good
# snapshot survives right up to the instant a complete replacement exists,
# instead of being deleted up front and left missing if sqlite3 or gzip fails.
def snapshot!(db_path, dest)
  staging = File.join(dest, ".staging-#{Process.pid}.db")
  final   = File.join(dest, "tyrion-#{TODAY.strftime('%Y%m%d')}.db")

  unless system('sqlite3', db_path, sqlite_dot_arg(staging))
    FileUtils.rm_f(staging)
    die "sqlite3 .backup failed (exit #{$?&.exitstatus})"
  end

  if system('gzip', '-f', staging)
    staging = "#{staging}.gz"
    final   = "#{final}.gz"
  else
    log 'gzip failed, keeping this snapshot uncompressed'
  end

  File.rename(staging, final)
  final
end

def snapshots(dest)
  Dir.glob(File.join(dest, 'tyrion-*.db{,.gz}'))
end

# Matches a plain .db (gzip failed that day) or a .db.gz snapshot -- the sweep
# must see both, or an uncompressed leftover from a gzip failure never gets
# pruned and sits there full-size forever.
SNAPSHOT_NAME = /\Atyrion-(\d{8})\.db(?:\.gz)?\z/

def prunable?(path)
  match = File.basename(path).match(SNAPSHOT_NAME)
  return false unless match

  !keep?(Date.strptime(match[1], '%Y%m%d'))
rescue Date::Error
  false # not a stamp this script wrote -- leave it alone rather than guess
end

def keep?(date)
  age_days = (TODAY - date).to_i
  return true if age_days <= DAILY_WINDOW_DAYS
  return date.sunday? if age_days <= WEEKLY_WINDOW_DAYS

  date.day == 1
end

def sweep!(dest)
  pruned = snapshots(dest).select { |path| prunable?(path) }
  pruned.each { |path| File.delete(path) }
  pruned.map { |path| File.basename(path) }
end

def run!(argv)
  options = parse_options(argv)

  unless File.exist?(options[:db])
    log "no DB at #{options[:db]}, nothing to back up"
    return
  end

  FileUtils.mkdir_p(options[:dest])

  written = snapshot!(options[:db], options[:dest])
  log "wrote #{written} (#{File.size(written)} bytes)"

  pruned = sweep!(options[:dest])
  log "pruned #{pruned.size} backup(s): #{pruned.join(', ')}" unless pruned.empty?
  log "#{snapshots(options[:dest]).size} backup(s) on disk in #{options[:dest]}"
end
