# frozen_string_literal: true

require "supabase/realtime"

# US-006 updated this file: Timer now ports supabase-py's AsyncTimer 1:1 —
# `schedule_timeout` increments `tries` BEFORE computing the delay, and passes
# `tries + 1` to the backoff lambda (see py `realtime/_async/timer.py:24-29`).
# The previous rb behavior (passing `tries`, incrementing after sleep) gave
# a different curve and is captured in the new
# `us006_timer_backoff_curve_spec.rb` regression spec.
RSpec.describe Supabase::Realtime::Timer do
  let(:fired)    { [] }
  let(:callback) { -> { fired << :tick } }
  let(:backoff)  { ->(tries) { 2**tries } }
  let(:timer)    { described_class.new(callback: callback, backoff: backoff) }

  def join_pending(t)
    t.instance_variable_get(:@thread)&.join
  end

  describe "#initialize" do
    it "starts with tries=0 and no pending thread" do
      expect(timer.tries).to eq(0)
      expect(timer.instance_variable_get(:@thread)).to be_nil
    end
  end

  describe "#schedule_timeout" do
    it "bumps tries to 1 BEFORE computing the delay and passes tries+1 to backoff" do
      delays = []
      allow(timer).to receive(:sleep) { |s| delays << s }

      timer.schedule_timeout
      join_pending(timer)

      # py: tries 0→1, delay = timer_calc(1+1) = 2**2 = 4
      expect(delays).to eq([4])
      expect(timer.tries).to eq(1)
      expect(fired).to eq([:tick])
    end

    it "produces 4, 8, 16 second delays across three ticks (formula 2**(tries+1))" do
      delays = []
      allow(timer).to receive(:sleep) { |s| delays << s }

      3.times do
        timer.schedule_timeout
        join_pending(timer)
      end

      expect(delays).to eq([4, 8, 16])
      expect(fired.length).to eq(3)
      expect(timer.tries).to eq(3)
    end

    it "cancels the previous pending tick when called again" do
      slow = described_class.new(
        callback: -> { fired << :tick },
        backoff: ->(_tries) { 5 }
      )
      slow.schedule_timeout
      first_thread = slow.instance_variable_get(:@thread)

      slow.schedule_timeout
      second_thread = slow.instance_variable_get(:@thread)

      first_thread.join(0.5)
      expect(first_thread).not_to be_alive
      expect(first_thread).not_to eq(second_thread)

      second_thread.kill
      expect(fired).to be_empty
    end

    it "returns self for chaining" do
      allow(timer).to receive(:sleep)
      expect(timer.schedule_timeout).to be(timer)
    end
  end

  describe "#reset" do
    it "cancels the pending tick without firing the callback" do
      slow = described_class.new(
        callback: -> { fired << :tick },
        backoff: ->(_tries) { 5 }
      )
      slow.schedule_timeout
      thread = slow.instance_variable_get(:@thread)

      slow.reset
      thread.join(0.5)

      expect(thread).not_to be_alive
      expect(fired).to be_empty
    end

    it "resets tries to 0 so the next schedule starts the backoff curve over" do
      delays = []
      allow(timer).to receive(:sleep) { |s| delays << s }

      2.times do
        timer.schedule_timeout
        join_pending(timer)
      end
      expect(timer.tries).to eq(2)

      timer.reset
      expect(timer.tries).to eq(0)

      timer.schedule_timeout
      join_pending(timer)

      # After reset: tries 0→1, delay = 2**(1+1) = 4
      expect(delays.last).to eq(4)
    end

    it "returns self for chaining" do
      expect(timer.reset).to be(timer)
    end

    it "is idempotent when called with no pending tick" do
      expect { timer.reset }.not_to raise_error
      expect { timer.reset }.not_to raise_error
      expect(timer.tries).to eq(0)
    end

    it "is idempotent after a schedule" do
      slow = described_class.new(
        callback: -> { fired << :tick },
        backoff: ->(_tries) { 5 }
      )
      slow.schedule_timeout
      expect { slow.reset }.not_to raise_error
      expect { slow.reset }.not_to raise_error
      expect(fired).to be_empty
    end
  end
end
