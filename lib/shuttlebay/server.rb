# frozen_string_literal: true

require 'json'
require 'socket'

module Shuttlebay
  class Server
    include ProcessControl

    RESPAWN_MIN = 0.1
    RESPAWN_MAX = 5.0
    STABLE_AFTER = 30.0
    SIGNALS = { 'TERM' => 'T', 'INT' => 'I', 'QUIT' => 'Q', 'CHLD' => 'C' }.freeze

    Group = Struct.new(:ship, :app_path, :socket_path, :workers, :threads, :app, :listener)
    Slot = Struct.new(:group, :index, :pid, :started_at, :backoff, :respawn_at)

    attr_reader :app_path, :socket_path, :workers, :threads, :ship, :forks

    def self.from_env(argv, env = ENV)
      socket_path = env.fetch('MS_SOCKET_PATH') do
        raise ArgumentError, 'MS_SOCKET_PATH is not set: shuttlebay runs as a mothership [[bays.http]] bay'
      end
      new(
        app_path: argv.first || 'config.ru',
        socket_path: socket_path,
        workers: Integer(env.fetch('MS_BAY_WORKERS', '0'), 10),
        threads: Integer(env.fetch('MS_BAY_THREADS', '3'), 10),
        ship: env.fetch('MS_SHIP', 'rack'),
        forks: parse_forks(env.fetch('MS_BAY_FORKS', '[]'))
      )
    end

    def self.parse_forks(json)
      JSON.parse(json).map do |fork|
        Group.new(fork.fetch('ship'), fork.fetch('app'), fork.fetch('socket'),
                  Integer(fork.fetch('workers')).clamp(1..), Integer(fork.fetch('threads')))
      end
    end

    def initialize(app_path:, socket_path:, workers:, threads:, ship:, forks: [], logger: Shuttlebay.logger)
      raise ArgumentError, "workers must be >= 0 (got #{workers})" if workers.negative?
      raise ArgumentError, "threads must be >= 1 (got #{threads})" if threads < 1
      forks.each { |fork| raise ArgumentError, "#{fork.ship}: threads must be >= 1" if fork.threads < 1 }

      @app_path = app_path
      @socket_path = socket_path
      @workers = workers
      @threads = threads
      @ship = ship
      @forks = forks
      @logger = logger
      @master_pid = Process.pid
    end

    def run
      Shuttlebay.running = true
      primary = Group.new(ship, app_path, socket_path, workers.clamp(1..), threads, load_app(app_path))
      forked = load_forks
      Process.warmup if Shuttlebay.warmup?
      [primary, *forked].each do |group|
        group.listener = bind(group.socket_path)
        @logger.info('app loaded, socket bound', ship: group.ship, app: group.app_path, socket: group.socket_path,
                                                 workers: group.workers, threads: group.threads)
      end

      if workers.zero? && forked.empty?
        worker(primary, index: nil).run
      else
        supervise([primary, *forked])
      end
    ensure
      cleanup if Process.pid == @master_pid
    end

    private

    def load_app(app_path)
      require 'rack'
      require 'rack/builder'
      path = File.expand_path(app_path)
      raise ArgumentError, "Rack app not found: #{path}" unless File.file?(path)

      Rack::Builder.parse_file(path)
    end

    def load_forks
      forks.filter_map do |group|
        group.app = load_app(group.app_path)
        group
      rescue StandardError, ScriptError => e
        @logger.error('fork app failed to load, skipped', ship: group.ship, app: group.app_path,
                                                          **Logger.error_fields(e))
        nil
      end
    end

    def bind(socket_path)
      if File.exist?(socket_path)
        raise ArgumentError, "#{socket_path} exists and is not a socket" unless File.socket?(socket_path)

        File.unlink(socket_path)
      end
      UNIXServer.new(socket_path).tap do |server|
        server.listen(1024)
        bound << [server, socket_path]
      end
    end

    def bound
      @bound ||= []
    end

    def worker(group, index:)
      Worker.new(app: group.app, listener: group.listener, threads: group.threads, workers: group.workers,
                 ship: group.ship, index: index, master_pid: index && @master_pid, logger: @logger)
    end

    def supervise(groups)
      wake_r, wake_w = IO.pipe
      previous = trap_signals(SIGNALS, wake_w)
      Shuttlebay.run_hooks(:before_fork)
      @slots = groups.flat_map do |group|
        Array.new(group.workers) { |index| Slot.new(group, index, nil, nil, RESPAWN_MIN, monotonic) }
      end
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

        slot.pid = spawn_worker(slot)
        slot.started_at = now
      end
    end

    def spawn_worker(slot)
      fork do
        become(slot.group)
        run_worker_process(slot.index, SIGNALS) { worker(slot.group, index: slot.index) }
      end
    end

    # In a freshly forked worker of `group`: it serves that bay alone, so the
    # other bays' listening sockets are closed, and a fork's worker logs (and
    # sees in MS_SHIP) the fork's name rather than its parent's.
    def become(group)
      bound.each { |server, path| server.close unless path == group.socket_path }
      return if group.ship == ship

      ENV['MS_SHIP'] = group.ship
      @logger = @logger.respond_to?(:for_ship) ? @logger.for_ship(group.ship) : @logger
      Shuttlebay.logger = @logger
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

      @logger.warn('worker exited, respawning', ship: slot.group.ship, index: slot.index, pid: pid,
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
      bound.each do |server, path|
        server.close
        File.unlink(path) if File.socket?(path)
      rescue SystemCallError => e
        @logger.warn('socket cleanup failed', socket: path, error: e.message)
      end
    end
  end
end
