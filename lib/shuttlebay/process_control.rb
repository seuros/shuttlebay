# frozen_string_literal: true

module Shuttlebay
  module ProcessControl
    private

    def trap_signals(signals, wake_w)
      signals.to_h do |signal, code|
        [signal, trap(signal) { wake_w.write_nonblock(code, exception: false) }]
      end
    end

    def close_self_pipe(previous, wake_r, wake_w)
      previous&.each { |signal, handler| trap(signal, handler || 'DEFAULT') }
      [wake_r, wake_w].compact.each(&:close)
    end

    def run_worker_process(index, signals)
      signals.each_key { |signal| trap(signal, 'DEFAULT') }
      yield.run
      $stdout.flush
      exit!(0)
    rescue StandardError, ScriptError => e
      @logger.error('worker crashed', index: index, **Logger.error_fields(e))
      $stdout.flush
      exit!(1)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
