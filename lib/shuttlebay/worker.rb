# frozen_string_literal: true

module Shuttlebay
  class Worker
    include ProcessControl

    DEFAULT_STOP_GRACE = 4.0
    SIGNALS = { 'TERM' => '.', 'INT' => '.', 'QUIT' => '.' }.freeze

    def self.stop_grace(env = ENV)
      Float(env.fetch('MS_BAY_DRAIN_TIMEOUT', DEFAULT_STOP_GRACE))
    end

    def initialize(app:, listener:, threads:, workers:, ship:, index: nil, master_pid: nil,
                   logger: Shuttlebay.logger)
      @app = app
      @listener = listener
      @threads = threads
      @workers = workers
      @ship = ship
      @index = index
      @master_pid = master_pid
      @logger = logger
      @handler = Handler.new(app, template: Worker.template(threads: threads, workers: workers), logger: logger)
      @links = {}
      @links_lock = Mutex.new
      @stopping = false
    end

    def self.template(threads:, workers:)
      {
        'SCRIPT_NAME' => '',
        'rack.errors' => $stderr,
        'rack.multithread' => threads > 1,
        'rack.multiprocess' => workers > 1,
        'rack.run_once' => false,
        'rack.hijack?' => false
      }.freeze
    end

    def run(trap_signals: true)
      @wake_r, @wake_w = IO.pipe
      previous = trap_signals(SIGNALS, @wake_w) if trap_signals
      Shuttlebay.run_hooks(:worker_boot, @index) if forked?
      pool = spawn_pool
      @logger.info('worker serving', index: @index, threads: @threads, reactors: @reactors)

      wait_for_stop
      stop(pool)
      raise @reactor_error if @reactor_error
    ensure
      close_self_pipe(previous, @wake_r, @wake_w)
    end

    def stop!
      @wake_w&.write_nonblock('.', exception: false)
    rescue IOError
      nil
    end

    private

    def forked?
      !@master_pid.nil?
    end

    def spawn_pool
      factory = Shuttlebay.fiber_scheduler_factory
      return Array.new(@threads) { |slot| Thread.new { accept_loop(slot) } } unless factory

      reactors = (0...@threads).group_by { |slot| slot % Shuttlebay.fiber_reactors }.values
      @reactors = reactors.size
      reactors.map { |slots| Thread.new { run_fibers(factory, slots) } }
    end

    def run_fibers(factory, slots)
      Fiber.set_scheduler(factory.call)
      slots.each { |slot| Fiber.schedule { accept_loop(slot) } }
      Fiber.set_scheduler(nil)
    rescue StandardError, ScriptError => e
      @reactor_error = e
      stop!
    end

    def accept_loop(slot)
      until @stopping
        io = @listener.accept
        serve_link(io)
      end
    rescue IOError, Errno::EBADF, Errno::EINVAL
      nil
    rescue StandardError => e
      @logger.error('accept loop crashed', slot: slot, **Logger.error_fields(e))
      return if @stopping

      sleep 0.1
      retry
    end

    LINK_BUFFER = 512 * 1024

    def serve_link(io)
      widen_buffers(io)
      codec = Engine::Codec.new
      @links_lock.synchronize { @links[io] = codec }
      config = codec.dock(io, @ship, @threads)
      Shuttlebay.config ||= config
      outcome = @handler.serve(io, codec, stopping: -> { @stopping }, after_request: -> { out_of_band(codec) })
    rescue Engine::ProtocolError => e
      @logger.warn('docking link protocol error', **Logger.error_fields(e))
    rescue *Handler::LINK_LOST
      nil
    ensure
      @links_lock.synchronize { @links.delete(io) }
      io.close unless outcome == :detached
    end

    def widen_buffers(io)
      io.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, LINK_BUFFER)
      io.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, LINK_BUFFER)
    end

    def wait_for_stop
      loop do
        return if @wake_r.wait_readable(1.0)
        return @logger.warn('master is gone, stopping worker', index: @index) if orphaned?
      end
    end

    def orphaned?
      forked? && Process.ppid != @master_pid
    end

    def stop(pool)
      @stopping = true
      @listener.close
      close_idle_links
      deadline = monotonic + Worker.stop_grace
      pool.each do |thread|
        thread.join([deadline - monotonic, 0].max)
      end
      busy = @links_lock.synchronize { @links.count { |_io, codec| codec.request_id } }
      @logger.warn('stopping with requests still running', busy: busy) if busy.positive?
      run_shutdown_hooks
      @logger.info('worker stopped', index: @index)
    end

    def out_of_band(codec)
      others_busy = @links_lock.synchronize do
        @links.any? { |_io, other| !other.equal?(codec) && !other.request_id.nil? }
      end
      Shuttlebay.run_hooks(:out_of_band) unless others_busy
    end

    def close_idle_links
      idle = @links_lock.synchronize { @links.select { |_io, codec| codec.request_id.nil? }.keys }
      idle.each(&:close)
    end

    def run_shutdown_hooks
      Shuttlebay.run_hooks(:worker_shutdown, @index)
    rescue StandardError => e
      @logger.error('on_worker_shutdown hook failed', **Logger.error_fields(e))
    end
  end
end
