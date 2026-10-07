# frozen_string_literal: true

require 'English'
require_relative 'test_helper'

class ServerTest < Minitest::Test
  include EngineHarness
  include SubprocessHarness

  BOOT_TIMEOUT = 20

  CONFIG_RU = <<~RUBY
    Shuttlebay.on_worker_boot { |index| $worker_index = index }
    Shuttlebay.out_of_band { File.write(File.join(ENV["HOOK_DIR"], "oob-\#{Process.pid}"), "ran") }
    Shuttlebay.on_worker_shutdown { |index| File.write(File.join(ENV["HOOK_DIR"], "shutdown-\#{index.inspect}"), Process.pid.to_s) }
    run ->(env) { [200, { "content-type" => "text/plain" }, ["\#{Process.pid}:\#{$worker_index}:\#{Shuttlebay.config['role']}"]] }
  RUBY

  FIBER_CONFIG_RU = <<~RUBY
    require "async"
    Shuttlebay.fiber_scheduler { Async::Scheduler.new }
    run lambda { |env|
      File.write(File.join(ENV["HOOK_DIR"], "started"), env["PATH_INFO"])
      sleep Float(env["QUERY_STRING"])
      [200, {}, ["\#{Process.pid}:\#{Thread.current.object_id}:\#{Fiber.current.object_id}"]]
    }
  RUBY

  def setup
    @dir = Dir.mktmpdir('shuttlebay')
    @socket = File.join(Dir.tmpdir, "gs-#{Process.pid}-#{rand(1 << 16)}.sock")
    @config_ru = File.join(@dir, 'config.ru')
    File.write(@config_ru, CONFIG_RU)
    @log = File.join(@dir, 'shuttlebay.log')
    @links = []
  end

  def teardown
    @links.each { |link| link.io.close unless link.io.closed? }
    kill_leftover_group if @pid
    FileUtils.rm_rf(@dir)
    FileUtils.rm_f(@socket)
  end

  def test_preforked_workers_serve_every_link_and_stop_cleanly_on_term
    boot(workers: 2, threads: 2)

    4.times { dock_link }
    bodies = @links.map { |link| link.request(params).body }
    pids = bodies.map { |body| body.split(':').first.to_i }
    worker_indexes = bodies.map { |body| body.split(':')[1] }

    assert_equal 2, pids.uniq.size, "links should spread across both workers: #{bodies}"
    assert_equal [2, 2], pids.tally.values.sort, 'each worker holds threads-many links'
    refute_includes pids, @pid, 'the master only supervises'
    assert_equal %w[0 1], worker_indexes.uniq.sort, 'on_worker_boot ran in each worker'
    assert(bodies.all? { |body| body.end_with?(':ship-config') }, 'Moored config reaches Shuttlebay.config')

    stop_master
    assert_equal 2, log_messages.count('worker stopped'), 'workers drain, not SIGKILL'
    refute(log_messages.any? { |msg| msg.include?('killing') }, 'no worker needed SIGKILL')
    refute File.exist?(@socket), 'socket must be removed on shutdown'
    pids.uniq.each do |worker_pid|
      assert_raises(Errno::ESRCH, "worker #{worker_pid} survived") { Process.kill(0, worker_pid) }
    end
    assert(@links.all? { |link| link.read_frame.nil? }, 'idle links are closed on shutdown')

    pids.uniq.each do |worker_pid|
      assert File.exist?(File.join(@dir, "oob-#{worker_pid}")), "out_of_band ran in idle worker #{worker_pid}"
    end
    shutdowns = %w[0 1].map { |index| File.read(File.join(@dir, "shutdown-#{index}")).to_i }
    assert_equal pids.uniq.sort, shutdowns.sort, 'on_worker_shutdown ran in each worker with its index'
  end

  def test_master_respawns_a_crashed_worker
    boot(workers: 1, threads: 1)
    first = dock_link
    crashed_pid, = served_by(first)

    Process.kill('KILL', crashed_pid)
    assert_nil first.read_frame, "the crashed worker's link closes"

    respawned_pid, = served_by(dock_link)

    refute_equal crashed_pid, respawned_pid
    respawn = log_lines(File.read(@log)).find { |line| line['msg'] == 'worker exited, respawning' }
    assert_equal crashed_pid, respawn['pid']
  end

  def test_single_process_mode_serves_from_the_master
    boot(workers: 0, threads: 2)

    pid, = served_by(dock_link)

    assert_equal @pid, pid
    stop_master
  end

  def test_fiber_scheduler_overlaps_slow_requests_and_drains_on_term
    boot(workers: 1, threads: 2, config: FIBER_CONFIG_RU)
    links = [dock_link, dock_link]

    pids, threads, fibers = concurrent_sleeps(links, 0.5)

    assert_equal 1, pids.uniq.size, 'one forked worker holds both links'
    refute_includes pids, @pid.to_s, 'the scheduler runs in the worker, not the master'
    assert_equal 1, threads.uniq.size, "both requests ran on the worker's reactor thread"
    assert_equal 2, fibers.uniq.size, 'each link is served by its own fiber'

    drain, idle = links
    id = drain.send_request(params('PATH_INFO' => '/drain', 'QUERY_STRING' => '0.3'))
    started = File.join(@dir, 'started')
    Timeout.timeout(5) { sleep 0.01 until File.exist?(started) && File.read(started) == '/drain' }
    Process.kill('TERM', @pid)

    assert_nil idle.read_frame, 'the idle fiber link is closed right away'
    assert_equal 200, drain.read_reply.status, 'the in-flight request finishes after TERM'
    drain.read_chunks(id)
    drain.read_ready(id)
    assert_nil drain.read_frame, 'the drained link closes once its request is done'
    stop_master
    log = File.read(@log)
    assert_includes log, '"msg":"worker stopped"'
    refute_includes log, 'killing', 'the reactor drains on TERM'
  end

  def test_fiber_reactors_split_a_workers_links_across_threads
    boot(workers: 0, threads: 4,
         config: FIBER_CONFIG_RU.sub('Shuttlebay.fiber_scheduler {', 'Shuttlebay.fiber_scheduler(reactors: 2) {'))
    links = Array.new(4) { dock_link }

    _pids, threads, fibers = concurrent_sleeps(links, 0.5)

    assert_equal [2, 2], threads.tally.values, 'two reactor threads with two links each'
    assert_equal 4, fibers.uniq.size, 'each link is served by its own fiber'
    stop_master
  end

  def test_fiber_scheduler_rejects_a_reactor_count_below_one
    error = assert_raises(ArgumentError) { Shuttlebay.fiber_scheduler(reactors: 0) { Object.new } }
    assert_match(/reactors >= 1/, error.message)
    assert_nil Shuttlebay.fiber_scheduler_factory, 'a rejected call registers nothing'
  end

  def test_a_broken_fiber_scheduler_stops_shuttlebay_loudly
    File.write(@config_ru, "Shuttlebay.fiber_scheduler { Object.new }\nrun ->(_env) { [200, {}, []] }\n")
    env = { 'MS_SOCKET_PATH' => @socket, 'MS_BAY_WORKERS' => '0', 'MS_BAY_THREADS' => '1' }

    out = Timeout.timeout(10) { IO.popen(env, [RbConfig.ruby, EXE, @config_ru], err: %i[child out], &:read) }

    refute_predicate $CHILD_STATUS, :success?
    assert_match(/shuttlebay stopped.*Scheduler must implement #block/, out)
  end

  def test_missing_socket_path_fails_fast
    out = IO.popen({ 'MS_SOCKET_PATH' => nil }, [RbConfig.ruby, EXE, @config_ru], err: %i[child out], &:read)

    refute_predicate $CHILD_STATUS, :success?
    assert_match(/MS_SOCKET_PATH is not set/, out)
  end

  private

  def kill_leftover_group
    Process.kill('KILL', -@pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def concurrent_sleeps(links, seconds)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ids = links.map { |link| link.send_request(params('QUERY_STRING' => seconds.to_s)) }
    bodies = links.zip(ids).map do |link, id|
      link.read_reply
      link.read_chunks(id).join.tap { link.read_ready(id) }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, seconds * 1.8,
                    "#{links.size} #{seconds}s requests should overlap, took #{elapsed.round(2)}s"
    bodies.map { |body| body.split(':') }.transpose
  end

  def served_by(link)
    link.request(params).body.split(':').map(&:to_i)
  end

  def log_messages
    log_lines(File.read(@log)).map { |line| line['msg'] }
  end

  def stop_master(timeout: 10)
    Process.kill('TERM', @pid)
    _, status = Timeout.timeout(timeout) { Process.wait2(@pid) }
    @pid = nil
    assert status.success?, "master should exit 0 on TERM, got #{status.inspect}\n#{File.read(@log)}"
  end

  def boot(workers:, threads:, config: CONFIG_RU)
    File.write(@config_ru, config)
    env = {
      'MS_SOCKET_PATH' => @socket,
      'MS_BAY_WORKERS' => workers.to_s,
      'MS_BAY_THREADS' => threads.to_s,
      'MS_SHIP' => 'server-test',
      'MS_BAY_TYPE' => 'http',
      'HOOK_DIR' => @dir
    }
    @pid = Process.spawn(env, RbConfig.ruby, EXE, @config_ru, out: @log, err: @log, pgroup: true)
    Timeout.timeout(BOOT_TIMEOUT) { sleep 0.05 until File.socket?(@socket) }
  rescue Timeout::Error
    flunk "shuttlebay did not bind #{@socket} within #{BOOT_TIMEOUT}s:\n#{File.read(@log)}"
  end

  def dock_link
    link = FakeMothership.new(UNIXSocket.new(@socket))
    @links << link
    Timeout.timeout(10) { link.accept_dock({ 'role' => 'ship-config' }) }
    link
  end
end
