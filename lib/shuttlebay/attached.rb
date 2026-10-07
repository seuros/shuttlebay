# frozen_string_literal: true

require 'fileutils'
require 'socket'
require 'tmpdir'
require_relative 'runtime'

module Shuttlebay
  class Attached
    # sun_path holds 104 bytes on macOS (108 on Linux), terminator included
    SOCKET_PATH_MAX = 103

    attr_reader :host, :port, :threads

    def initialize(app, trap_signals: true, mothership: Attached.mothership_binary, logger: nil, **options)
      @app = app
      @host = options.fetch(:Host, '127.0.0.1').to_s
      @port = Integer(options.fetch(:Port, 9292))
      @threads = Attached.threads(options[:Threads])
      @silent = options.fetch(:Silent, false)
      @trap_signals = trap_signals
      @mothership = mothership
      @logger = logger || (@silent ? Logger.new(File.open(File::NULL, 'w')) : Shuttlebay.logger)
    end

    def run
      @dir, socket = Attached.socket_dir
      listener = UNIXServer.new(socket)
      manifest = File.join(@dir, 'ship-manifest.toml')
      File.write(manifest, manifest_toml(socket))

      @worker = Worker.new(app: @app, listener: listener, threads: threads, workers: 0, ship: 'app',
                           logger: @logger)
      Shuttlebay.running = true
      @mothership_pid = spawn_mothership(manifest)
      watch_mothership
      at_exit { stop_mothership } unless @trap_signals
      @logger.info('serving through mothership', url: url, threads: threads)
      @worker.run(trap_signals: @trap_signals)
      raise Error, "mothership exited (#{@mothership_exit}); see its output above" if @mothership_exit
    ensure
      stop_mothership
      FileUtils.rm_rf(@dir) if @dir
    end

    def stop
      @worker&.stop!
    end

    def self.mothership_binary(env = ENV)
      env.fetch('MOTHERSHIP_BIN') do
        Gem.bin_path('guardship', 'mothership')
      rescue Gem::Exception
        'mothership'
      end
    end

    # A private directory for the app socket: under $TMPDIR (Dir.tmpdir),
    # unless that makes the socket path too long for a Unix socket.
    def self.socket_dir(roots = [Dir.tmpdir, '/tmp'])
      roots.uniq.each do |root|
        dir = Dir.mktmpdir('sb', root)
        socket = File.join(dir, 'app.sock')
        return [dir, socket] if socket.bytesize <= SOCKET_PATH_MAX

        FileUtils.rm_rf(dir)
      rescue SystemCallError
        next
      end
      raise Error, "no temp directory gives a Unix socket path under #{SOCKET_PATH_MAX} bytes; " \
                   'set TMPDIR to a shorter one'
    end

    def self.threads(option, env = ENV)
      value = option || env.fetch('MS_BAY_THREADS', '3')
      count = Integer(value.to_s, 10)
      raise ArgumentError, "Threads must be at least 1 (got #{value.inspect})" if count < 1

      count
    end

    private

    def url
      "http://#{address}"
    end

    def address
      "#{host.include?(':') ? "[#{host}]" : host}:#{port}"
    end

    def manifest_toml(socket)
      <<~TOML
        [mothership.bind]
        http = #{address.dump}

        [[mothership.upstreams]]
        name = "app"
        bind = #{"unix://#{socket}".dump}
        protocol = "docking"
        routes = [{ bind = "http", pattern = "/.*" }]
      TOML
    end

    def spawn_mothership(manifest)
      output = @silent ? File::NULL : $stdout
      Process.spawn(@mothership, 'run', '-c', manifest, out: output, err: @silent ? File::NULL : $stderr)
    rescue SystemCallError => e
      raise Error, "cannot start mothership (#{@mothership}): #{e.message}. " \
                   'Install the guardship gem or set MOTHERSHIP_BIN.'
    end

    def watch_mothership
      pid = @mothership_pid
      @watcher = Thread.new do
        _, status = Process.wait2(pid)
        next unless @mothership_pid

        @mothership_pid = nil
        @mothership_exit = status.exitstatus ? "exit #{status.exitstatus}" : "signal #{status.termsig}"
        @logger.error('mothership exited', status: @mothership_exit)
        stop
      rescue Errno::ECHILD
        nil
      end
    end

    def stop_mothership
      pid = @mothership_pid
      @mothership_pid = nil
      return unless pid

      Process.kill('TERM', pid)
      @watcher&.join(30) || Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end
