# frozen_string_literal: true

require_relative 'test_helper'
require 'base64'
require 'net/http'

class MothershipTest < Minitest::Test
  include MothershipHarness

  CONFIG_RU = <<~RUBY
    require "digest"
    require "base64"
    WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    run lambda { |env|
      case env["PATH_INFO"]
      when "/ws"
        io = env["rack.hijack"].call
        accept = Base64.strict_encode64(Digest::SHA1.digest(env["HTTP_SEC_WEBSOCKET_KEY"] + WS_GUID))
        io.write("HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n" \\
                 "Sec-WebSocket-Accept: \#{accept}\\r\\n\\r\\n")
        Thread.new do
          loop { io.write(io.readpartial(1024).upcase) }
        rescue EOFError, IOError
          io.close
        end
        [-1, {}, []]
      when "/pid" then [200, {}, [Process.pid.to_s]]
      when "/upload" then [200, {}, [Digest::SHA256.hexdigest(env["rack.input"].read)]]
      when "/stuck" then sleep(600)
      else [404, {}, ["no route"]]
      end
    }
  RUBY

  def setup
    prepare_mothership(CONFIG_RU)
  end

  def test_serves_restarts_without_dropping_requests_and_recycles_stuck_workers
    start_mothership
    first_generation = pids_seen(20)
    assert_equal 2, first_generation.size, "both workers serve: #{first_generation}"

    body = Random.bytes((3 * 1024 * 1024) + 7)
    assert_equal Digest::SHA256.hexdigest(body), post('/upload', body).body

    statuses = Queue.new
    stop = false
    load = Array.new(4) do
      Thread.new do
        until stop
          statuses << begin
            get('/pid').code
          rescue StandardError => e
            e.class.name
          end
        end
      end
    end
    sleep 0.5
    Process.kill('USR1', @pid)
    wait_for_log('Phased restart complete', timeout: 60)
    sleep 0.5
    stop = true
    load.each(&:join)

    results = Array.new(statuses.size) { statuses.pop }
    assert results.size > 50, "load ran throughout the restart (#{results.size} requests)"
    assert_equal ['200'], results.uniq, "requests failed during the phased restart: #{results.tally}"

    second_generation = pids_seen(20)
    assert_equal 2, second_generation.size
    assert_empty first_generation & second_generation, 'every worker was replaced'
    first_generation.each { |pid| assert_dead(pid, "worker #{pid} of the previous generation is still alive") }

    stuck = Thread.new { get('/stuck').code }
    assert_equal '504', stuck.value
    wait_for_log('Recycling worker stuck on a request', timeout: 10)
    Timeout.timeout(30) do
      sleep 0.2 until (pids_seen(10) - second_generation).any?
    end
    assert_equal '200', get('/pid').code
  end

  def test_websocket_upgrades_reach_the_app_through_rack_hijack
    start_mothership
    key = Base64.strict_encode64(Random.bytes(16))
    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write("GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{@port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                 "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")

    head = +''
    Timeout.timeout(10) { head << socket.readpartial(1024) until head.include?("\r\n\r\n") }
    status_line, *headers = head.split("\r\n\r\n", 2).first.split("\r\n")
    assert_equal 'HTTP/1.1 101 Switching Protocols', status_line
    expected = Base64.strict_encode64(Digest::SHA1.digest("#{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    assert_includes headers.map(&:downcase), "sec-websocket-accept: #{expected.downcase}"

    socket.write('ping over mothership')
    echoed = +''
    Timeout.timeout(10) { echoed << socket.readpartial(1024) while echoed.bytesize < 20 }
    assert_equal 'PING OVER MOTHERSHIP', echoed

    assert_equal 2, pids_seen(10).size
  ensure
    socket&.close
  end

  private

  def pids_seen(count)
    Array.new(count) { Thread.new { get('/pid').body.to_i } }.map(&:value).uniq.sort
  end
end
