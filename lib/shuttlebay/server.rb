# frozen_string_literal: true

require 'socket'

module Shuttlebay
  class Server
    include ProcessControl

    RESPAWN_MIN = 0.1
    RESPAWN_MAX = 5.0
    STABLE_AFTER = 30.0
    SIGNALS = { 'TERM' => 'T', 'INT' => 'I', 'QUIT' => 'Q', 'CHLD' => 'C' }.freeze

    Slot = Struct.new(:index, :pid, :started_at, :backoff, :respawn_at)

    attr_reader :app_path, :socket_path, :workers, :threads, :ship

    def self.from_env(argv, env = ENV)
      socket_path = env.fetch('MS_SOCKET_PATH') do
        raise ArgumentError, 'MS_SOCKET_PATH is not set: shuttlebay runs as a mothership [[bays.http]] bay'
      end
      new(
        app_path: argv.first || 'config.ru',
        socket_path: socket_path,
        workers: Integer(env.fetch('MS_BAY_WORKERS', '0'), 10),
        threads: Integer(env.fetch('MS_BAY_THREADS', '3'), 10),
        ship: env.fetch('MS_SHIP', 'rack')
      )
    end

    def initialize(app_path:, socket_path:, workers:, threads:, ship:, logger: Shuttlebay.logger)
      raise ArgumentError, "workers must be >= 0 (got #{workers})" if workers.negative?
      raise ArgumentError, "threads must be >= 1 (got #{threads})" if threads < 1

      @app_path = app_path
      @socket_path = socket_path
      @workers = workers
      @threads = threads
      @ship = ship
      @logger = logger
      @master_pid = Process.pid
    end

    def run
      Shuttlebay.running = true
      app = load_app
      @listener = bind
      @logger.info('app loaded, socket bound', app: app_path, socket: socket_path,
                                               workers: workers, threads: threads)

      if workers.zero?
        worker(app, index: nil).run
      else
        supervise(app)
      end
    ensure
      cleanup if Process.pid == @master_pid
    end

    private

    def load_app
      require 'rack'
      require 'rack/builder'
      path = File.expand_path(app_path)
      raise ArgumentError, "Rack app not found: #{path}" unless File.file?(path)

      Rack::Builder.parse_file(path)
    end

    def bind
      if File.exist?(socket_path)
        raise ArgumentError, "#{socket_path} exists and is not a socket" unless File.socket?(socket_path)

        File.unlink(socket_path)
      end
      UNIXServer.new(socket_path).tap { |server| server.listen(1024) }
    end

    def worker(app, index:)
      Worker.new(app: app, listener: @listener, threads: threads, workers: workers, ship: ship,
                 index: index, master_pid: index && @master_pid, logger: @logger)
    end

    def supervise(app)
      wake_r, wake_w = IO.pipe
      previous = trap_signals(SIGNALS, wake_w)
      @app = app
      Shuttlebay.run_hooks(:before_fork)
      @slots = Array.new(workers) { |index| Slot.new(index, nil, nil, RESPAWN_MIN, monotonic) }
      @stopping = false

      until @stopping && @slots.none?(&:pid)
        spawn_due unless @stopping
        reap
        wait_for_signal(wake_r)
      end
      @logger.info('all workers stopped')
    ensure
      close_self_pipe(previous, wake_r, wake_w)
    end

    def wait_for_signal(wake_r)
      ready, = IO.select([wake_r], nil, nil, next_timeout)
      codes = ready ? wake_r.read_nonblock(1024, exception: false) : nil
      stop_code = codes.delete('C')[0] if codes.is_a?(String)
      begin_stop(SIGNALS.key(stop_code)) if stop_code
      stop_overdue if @stopping
    end

    def next_timeout
      return 0.2 if @stopping

      due = @slots.reject(&:pid).map(&:respawn_at).min
      due ? [[due - monotonic, 0.0].max, 1.0].min : 1.0
    end

    def spawn_due
      now = monotonic
      @slots.each do |slot|
        next if slot.pid || slot.respawn_at > now

        slot.pid = spawn_worker(slot.index)
        slot.started_at = now
      end
    end

    def spawn_worker(index)
      app = @app
      fork { run_worker_process(index, SIGNALS) { worker(app, index: index) } }
    end

    def reap
      loop do
        pid, status = Process.wait2(-1, Process::WNOHANG)
        break unless pid

        exited(pid, status)
      end
    rescue Errno::ECHILD
      @slots.each { |slot| slot.pid = nil }
    end

    def exited(pid, status)
      slot = @slots.find { |candidate| candidate.pid == pid }
      return unless slot

      uptime = monotonic - slot.started_at
      slot.pid = nil
      slot.backoff = RESPAWN_MIN if uptime >= STABLE_AFTER
      delay = slot.backoff
      slot.backoff = [slot.backoff * 2, RESPAWN_MAX].min
      slot.respawn_at = monotonic + delay
      return if @stopping

      @logger.warn('worker exited, respawning', index: slot.index, pid: pid,
                                                status: status && (status.exitstatus || status.termsig),
                                                uptime: uptime.round(3), respawn_in: delay)
    end

    def begin_stop(signal)
      return if @stopping

      @stopping = true
      @stop_deadline = monotonic + Worker.stop_grace + 0.5
      @logger.info('stopping workers', signal: signal)
      signal_workers('TERM')
    end

    def stop_overdue
      return unless monotonic >= @stop_deadline && running_pids.any?

      @logger.warn('workers did not stop in time, killing', pids: running_pids)
      signal_workers('KILL')
      @stop_deadline = Float::INFINITY
    end

    def running_pids
      @slots.filter_map(&:pid)
    end

    def signal_workers(signal)
      running_pids.each { |pid| send_signal(pid, signal) }
    end

    def send_signal(pid, signal)
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      nil
    end

    def cleanup
      @listener&.close
      File.unlink(socket_path) if socket_path && File.socket?(socket_path)
    rescue SystemCallError => e
      @logger.warn('socket cleanup failed', socket: socket_path, error: e.message)
    end
  end
end
