# frozen_string_literal: true

require_relative 'test_helper'
require 'net/http'
require 'open3'

class AttachedTest < Minitest::Test
  include SubprocessHarness

  MOTHERSHIP_ENV = { 'MOTHERSHIP_BIN' => MOTHERSHIP_BIN }.freeze

  SERVER = <<~RUBY
    require "rackup/handler"
    require "rackup/handler/shuttlebay"
    app = ->(env) { [200, { "content-type" => "text/plain" }, ["in-process \#{Process.pid} \#{env['SERVER_SOFTWARE']}"]] }
    Rackup::Handler.get("shuttlebay").run(app, Host: "127.0.0.1", Port: Integer(ARGV.first), Threads: "2", Silent: true)
  RUBY

  def test_rackup_handler_serves_the_in_process_app_through_mothership
    skip_without_mothership

    port = free_port
    stdin, out, server = Open3.popen2e(MOTHERSHIP_ENV, *ruby_script(SERVER, port.to_s))
    stdin.close
    body = await_ok { get(port) }

    assert_match(%r{\Ain-process #{server.pid} mothership/}, body,
                 "app runs in the handler's process, served by mothership")

    Process.kill('INT', server.pid)
    status = Timeout.timeout(30) { server.value }
    assert status.success?, "handler should exit cleanly on INT:\n#{out.read}"
    assert_refused(port, 'mothership must stop with the server')
  ensure
    if server&.alive?
      Process.kill('KILL', server.pid)
      server.join
    end
    out&.close
  end

  FIBER_SERVER = <<~RUBY
    require "async"
    require "rackup/handler"
    require "rackup/handler/shuttlebay"
    Shuttlebay.fiber_scheduler { Async::Scheduler.new }
    app = lambda do |env|
      sleep Float(env["QUERY_STRING"])
      [200, { "content-type" => "text/plain" }, ["\#{Thread.current.object_id}:\#{Fiber.current.object_id}"]]
    end
    Rackup::Handler.get("shuttlebay").run(app, Host: "127.0.0.1", Port: Integer(ARGV.first), Threads: "2", Silent: true)
  RUBY

  def test_attached_server_overlaps_requests_on_fibers
    skip_without_mothership

    port = free_port
    stdin, out, server = Open3.popen2e(MOTHERSHIP_ENV, *ruby_script(FIBER_SERVER, port.to_s))
    stdin.close
    await_ok { get(port, '0') }

    threads, _fibers, elapsed = Timeout.timeout(15) do
      loop do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        bodies = Array.new(2) { Thread.new { get(port, '0.3').body } }.map(&:value)
        pair = bodies.map { |body| body.split(':') }.transpose
        break [*pair, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started] if pair.last.uniq.size == 2
      end
    end

    assert_equal 1, threads.uniq.size, "both requests ran on the app's reactor thread"
    assert_operator elapsed, :<, 0.55, 'two 0.3s requests on two fibers overlap'
  ensure
    if server&.alive?
      Process.kill('INT', server.pid)
      Timeout.timeout(30) { server.value }
    end
    out&.close
  end

  CAPYBARA = <<~RUBY
    require "capybara"
    require "net/http"
    require "shuttlebay/capybara"
    Capybara.server = :shuttlebay
    app = ->(env) { [200, { "content-type" => "text/plain" }, ["system test \#{env['SERVER_SOFTWARE']}"]] }
    server = Capybara::Server.new(app).boot
    print server.port, " ", Net::HTTP.get(server.host, "/", server.port)
  RUBY

  def test_capybara_server_runs_through_mothership_and_stops_at_exit
    skip_without_mothership

    out, err, status = Timeout.timeout(60) { Open3.capture3(MOTHERSHIP_ENV, *ruby_script(CAPYBARA)) }
    assert status.success?, err
    port, body = out.split(' ', 2)
    assert_match(%r{\Asystem test mothership/}, body)
    assert_refused(port, 'mothership must not outlive the test process')
  end

  def test_handler_fails_fast_when_mothership_cannot_start
    skip_without_mothership

    taken = TCPServer.new('127.0.0.1', 0)
    port = taken.addr[1]
    _out, err, status = Timeout.timeout(30) { Open3.capture3(MOTHERSHIP_ENV, *ruby_script(SERVER, port.to_s)) }

    refute status.success?, 'the handler must not keep serving without a mothership'
    assert_match(/mothership exited/, err)
  ensure
    taken&.close
  end

  def test_socket_dir_uses_tmpdir_unless_the_socket_path_is_too_long
    Dir.mktmpdir('t', '/tmp') do |short|
      dir, socket = Shuttlebay::Attached.socket_dir([short])
      assert_equal short, File.dirname(dir)
      assert_equal File.join(dir, 'app.sock'), socket
    end

    Dir.mktmpdir('t', '/tmp') do |base|
      long = File.join(base, 'x' * 100)
      Dir.mkdir(long)
      dir, socket = Shuttlebay::Attached.socket_dir([long, base])
      assert_equal base, File.dirname(dir), 'falls back past a root too deep for sun_path'
      assert_operator socket.bytesize, :<=, Shuttlebay::Attached::SOCKET_PATH_MAX
    end
  end

  def test_threads_option_is_a_plain_count
    assert_equal 4, Shuttlebay::Attached.threads(4)
    assert_equal 5, Shuttlebay::Attached.threads('5')
    assert_equal 7, Shuttlebay::Attached.threads(nil, { 'MS_BAY_THREADS' => '7' })
    assert_equal 3, Shuttlebay::Attached.threads(nil, {})
    assert_raises(ArgumentError) { Shuttlebay::Attached.threads('0') }
    assert_raises(ArgumentError, 'no min:max ranges') { Shuttlebay::Attached.threads('1:5') }
  end

  private

  def await_ok
    Timeout.timeout(30) do
      loop do
        response = yield
        break response.body if response.code == '200'
      rescue SystemCallError, EOFError
        sleep 0.2
      end
    end
  end

  def assert_refused(port, message)
    assert_raises(Errno::ECONNREFUSED, message) { get(port) }
  end

  def get(port, query = nil) = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/#{"?#{query}" if query}"))
end
