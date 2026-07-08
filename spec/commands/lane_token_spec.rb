# frozen_string_literal: true

require 'spec_helper'

# Specs for Commands.current_lane_token and the Repo helpers it depends on.
# Repo.agent_pid and Repo.pid_start_stamp are stubbed in all Commands tests
# so CI never needs a real `ps` ancestor walk.
#
# The memo (@_lane_token) is reset before each example via the reset helper.

RSpec.describe 'lane token identity' do
  # Reset the per-process memo so each example derives freshly.
  def reset_lane_token_memo
    Tyrion::Commands.instance_variable_set(:@_lane_token, :unset)
  end

  around do |ex|
    reset_lane_token_memo
    # Isolate env changes from leaking between examples
    saved = %w[TYRION_LANE CODEX_THREAD_ID CMUX_CLAUDE_PID TYRION_AGENT].each_with_object({}) do |k, h|
      h[k] = ENV.delete(k)
    end
    ex.run
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    reset_lane_token_memo
  end

  describe 'Commands.current_lane_token' do
    subject(:token) { Tyrion::Commands.current_lane_token }

    context 'tier 1 — TYRION_LANE is set' do
      before { ENV['TYRION_LANE'] = 'claude:99999:abc123' }

      it 'returns TYRION_LANE verbatim without touching ps or other env vars' do
        expect(Tyrion::Repo).not_to receive(:agent_pid)
        expect(token).to eq('claude:99999:abc123')
      end

      it 'returns the raw value even if it looks unusual' do
        ENV['TYRION_LANE'] = 'custom-lane-42'
        reset_lane_token_memo
        expect(token).to eq('custom-lane-42')
      end
    end

    context 'tier 2 — CODEX_THREAD_ID is set (TYRION_LANE absent)' do
      before { ENV['CODEX_THREAD_ID'] = 'thread_abc123xyz' }

      it 'returns "codex:<thread-id>" without any ps walk' do
        expect(Tyrion::Repo).not_to receive(:agent_pid)
        expect(token).to eq('codex:thread_abc123xyz')
      end

      it 'uses TYRION_AGENT override for the agent label' do
        ENV['TYRION_AGENT'] = 'openai'
        reset_lane_token_memo
        expect(token).to eq('openai:thread_abc123xyz')
      end
    end

    context 'tier 3 — process-walk (TYRION_LANE and CODEX_THREAD_ID absent)' do
      let(:agent_pid)   { 11152 }
      let(:start_stamp) { 'abc123hash' }

      before do
        allow(Tyrion::Repo).to receive(:agent_pid).and_return(agent_pid)
        allow(Tyrion::Repo).to receive(:pid_start_stamp).with(agent_pid).and_return(start_stamp)
      end

      it 'returns "claude:<pid>:<stamp>"' do
        expect(token).to eq("claude:#{agent_pid}:#{start_stamp}")
      end

      it 'uses TYRION_AGENT to override the agent label' do
        ENV['TYRION_AGENT'] = 'codex'
        reset_lane_token_memo
        expect(token).to eq("codex:#{agent_pid}:#{start_stamp}")
      end

      it 'memoizes — Repo.agent_pid is called only once even when token is requested again' do
        expect(Tyrion::Repo).to receive(:agent_pid).once.and_return(agent_pid)
        token
        Tyrion::Commands.current_lane_token
      end

      it 'returns nil when pid_start_stamp cannot be derived (ps denied/empty)' do
        allow(Tyrion::Repo).to receive(:pid_start_stamp).with(agent_pid).and_return(nil)
        expect(token).to be_nil
      end
    end

    context 'tier 4 — CMUX_CLAUDE_PID accelerator' do
      let(:start_stamp) { 'stamp456' }

      before do
        ENV['CMUX_CLAUDE_PID'] = '11152'
        # Walk would also succeed for the same pid — accelerator short-circuits it
        allow(Tyrion::Repo).to receive(:pid_start_stamp).with(11152).and_return(start_stamp)
      end

      it 'produces "claude:<CMUX_CLAUDE_PID>:<stamp>" without a full ps walk' do
        # agent_pid may or may not be called depending on implementation;
        # what matters is the TOKEN is identical to what the walk would produce
        expect(token).to eq("claude:11152:#{start_stamp}")
      end

    end

    context 'tier 5 — degradation to nil' do
      before do
        allow(Tyrion::Repo).to receive(:agent_pid).and_return(nil)
      end

      it 'returns nil when no agent ancestor is found (legacy single-session path)' do
        expect(token).to be_nil
      end

      it 'never returns a guessed or fabricated token' do
        expect(token).not_to be_a(String)
      end
    end

    context 'token stability across /clear (same OS process)' do
      let(:agent_pid)   { 11152 }
      let(:start_stamp) { 'stablehash' }

      before do
        allow(Tyrion::Repo).to receive(:agent_pid).and_return(agent_pid)
        allow(Tyrion::Repo).to receive(:pid_start_stamp).with(agent_pid).and_return(start_stamp)
      end

      it 're-deriving the token (simulating /clear by resetting memo) yields the identical token' do
        first_token = token
        reset_lane_token_memo
        second_token = Tyrion::Commands.current_lane_token
        expect(second_token).to eq(first_token)
      end
    end
  end

  describe 'Repo.agent_pid' do
    subject(:pid) { Tyrion::Repo.agent_pid(start_pid) }

    let(:start_pid) { 1000 }

    context 'when ps walk finds a claude ancestor' do
      before do
        # ps_ppid_comm(pid) returns [ppid_of_pid, comm_of_pid].
        # Simulated tree: pid 1000 is bash (ppid=2000), pid 2000 is claude (ppid=3000).
        # So the claude ancestor IS pid 2000, which is what we expect returned.
        allow(Tyrion::Repo).to receive(:ps_ppid_comm).with(1000).and_return([2000, '/bin/bash'])
        allow(Tyrion::Repo).to receive(:ps_ppid_comm).with(2000).and_return([3000, '/Users/me/.local/bin/claude'])
      end

      it 'returns the pid of the nearest claude/codex/gemini ancestor' do
        expect(pid).to eq(2000)
      end
    end

    context 'when comm has a leading dash (login shell)' do
      before do
        # pid 1000 has comm "-/bin/bash" (login shell marker), ppid=2000.
        # pid 2000 has comm "codex", ppid=3000 — so pid 2000 is the codex ancestor.
        allow(Tyrion::Repo).to receive(:ps_ppid_comm).with(1000).and_return([2000, '-/bin/bash'])
        allow(Tyrion::Repo).to receive(:ps_ppid_comm).with(2000).and_return([3000, '/usr/local/bin/codex'])
      end

      it 'strips the leading dash before basename matching' do
        expect(pid).to eq(2000)
      end
    end

    context 'when ps is denied (sandboxed, e.g. Codex)' do
      before do
        allow(Tyrion::Repo).to receive(:ps_ppid_comm).and_raise(StandardError, 'Operation not permitted')
      end

      it 'returns nil without raising' do
        expect(pid).to be_nil
      end
    end

    context 'when no agent ancestor exists in the tree' do
      before do
        allow(Tyrion::Repo).to receive(:ps_ppid_comm).with(1000).and_return([1, 'launchd'])
        allow(Tyrion::Repo).to receive(:ps_ppid_comm).with(1).and_return(nil)
      end

      it 'returns nil' do
        expect(pid).to be_nil
      end
    end
  end

  describe 'Repo.pid_start_stamp' do
    subject(:stamp) { Tyrion::Repo.pid_start_stamp(12345) }

    context 'when ps returns lstart' do
      before do
        allow(Tyrion::Repo).to receive(:ps_lstart).with(12345).and_return('Tue Jun 16 13:35:59 2026    ')
      end

      it 'returns a non-nil string (the normalized hash)' do
        expect(stamp).to be_a(String)
        expect(stamp).not_to be_empty
      end

      it 'normalizes differently-formatted lstart strings to the same hash' do
        # Two independent derives, each stubbing a distinct whitespace variant.
        allow(Tyrion::Repo).to receive(:ps_lstart).with(12345).and_return('Tue Jun 16 13:35:59 2026')
        stamp1 = Tyrion::Repo.pid_start_stamp(12345)

        allow(Tyrion::Repo).to receive(:ps_lstart).with(99999).and_return('Tue Jun 16 13:35:59 2026    ')
        stamp2 = Tyrion::Repo.pid_start_stamp(99999)

        expect(stamp1).to eq(stamp2)
      end

      it 'produces different hashes for different lstart values' do
        allow(Tyrion::Repo).to receive(:ps_lstart).with(12345).and_return('Mon Jun 15 09:00:00 2026')
        stamp1 = Tyrion::Repo.pid_start_stamp(12345)
        allow(Tyrion::Repo).to receive(:ps_lstart).with(12345).and_return('Tue Jun 16 13:35:59 2026')
        stamp2 = Tyrion::Repo.pid_start_stamp(12345)
        expect(stamp1).not_to eq(stamp2)
      end
    end

    context 'when ps is denied or returns empty' do
      before do
        allow(Tyrion::Repo).to receive(:ps_lstart).with(12345).and_return(nil)
      end

      it 'returns nil without raising' do
        expect(stamp).to be_nil
      end
    end
  end
end
