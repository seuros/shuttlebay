# frozen_string_literal: true

require_relative 'test_helper'
require 'net/http'

class ForkTest < Minitest::Test
  include MothershipHarness

  WEB_RU = "run ->(_env) { [200, {}, [\"web:\#{Process.pid}:\#{Process.ppid}\"]] }\n"
  MCP_RU = "run ->(_env) { [200, {}, [\"mcp:\#{Process.pid}:\#{Process.ppid}\"]] }\n"

  def setup
    prepare_mothership(WEB_RU, ready_path: '/mcp')
    File.write(File.join(@dir, 'mcp.ru'), MCP_RU)
  end

  def manifest
    super.sub('[[bays.http]]', <<~TOML.chomp)
      [[bays.http]]
      name = "mcp"
      fork_from = "web"
      app = "mcp.ru"
      workers = 1
      threads = 2
      critical = false
      routes = [{ bind = "http", pattern = "/mcp", strip_prefix = "/mcp" }]

      [[bays.http]]
    TOML
  end

  def test_a_fork_is_served_by_its_parents_master_and_rolls_with_it
    start_mothership
    web, mcp = seen('/'), seen('/mcp')
    master = (web + mcp).map(&:last).uniq

    assert_equal 1, master.size, "web and mcp workers share one master: #{web} #{mcp}"
    assert_equal [2, 1], [web.size, mcp.size], 'two web workers, one mcp worker'

    Process.kill('USR1', @pid)
    wait_for_log('Phased restart complete', timeout: 60)

    rolled = seen('/') + seen('/mcp')
    assert_equal 1, rolled.map(&:last).uniq.size, 'the successor serves both bays'
    refute_equal master, rolled.map(&:last).uniq, 'the master was replaced'
    (web + mcp).each { |(_, pid, _)| assert_dead(pid, "worker #{pid} of the previous generation is still alive") }
  end

  def test_a_fork_redocks_once_its_parent_is_relaunched
    start_mothership
    master = seen('/mcp').first.last

    Process.kill('KILL', master)
    Timeout.timeout(60) do
      sleep 0.2 until (begin
        [get('/').code, get('/mcp').code]
      rescue StandardError
        nil
      end) == %w[200 200]
    end

    relaunched = seen('/') + seen('/mcp')
    assert_equal 1, relaunched.map(&:last).uniq.size
    refute_equal master, relaunched.first.last
  end

  private

  def seen(path)
    Array.new(12) { Thread.new { get(path).body.split(':') } }.map(&:value).uniq.map do |kind, pid, ppid|
      [kind, pid.to_i, ppid.to_i]
    end
  end
end
