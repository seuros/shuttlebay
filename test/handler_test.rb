# frozen_string_literal: true

require_relative 'test_helper'
require 'tempfile'

class HandlerTest < Minitest::Test
  include EngineHarness

  def test_headers_flatten_rack2_newlines_and_rack3_arrays
    app = lambda do |_env|
      [201, { 'set-cookie' => "a=1\nb=2", 'x-multi' => %w[one two], 'content-type' => 'text/plain' }, ['ok']]
    end

    with_link(app) do |mothership, _io|
      reply = mothership.request(params)

      assert_equal 201, reply.status
      assert_equal %w[a=1 b=2], reply.header('set-cookie')
      assert_equal %w[one two], reply.header('x-multi')
      assert_equal 'ok', reply.body
    end
  end

  def test_to_ary_body_leaves_in_a_single_write
    app = ->(_env) { [200, { 'content-type' => 'text/html' }, ['<h1>', 'hi', '</h1>']] }

    with_link(app) do |mothership, io|
      writes_after_dock = io.writes
      reply = mothership.request(params)

      assert_equal '<h1>hi</h1>', reply.body
      assert_equal 2, io.writes - writes_after_dock, 'response in one write, then Ready'
    end
  end

  def test_each_body_streams_each_chunk_as_it_is_produced
    gate = Thread::Queue.new
    body = Object.new
    body.define_singleton_method(:each) do |&block|
      block.call('first ')
      gate.pop
      block.call('second')
    end
    app = ->(_env) { [200, { 'content-type' => 'text/event-stream' }, body] }

    with_link(app) do |mothership, _io|
      id = mothership.send_request(params)
      reply = mothership.read_reply

      assert_equal :stream, reply.kind
      assert_equal ['first ', false], mothership.read_haul(id)
      gate << :go
      assert_equal ['second'], mothership.read_chunks(id)
    end
  end

  def test_rack3_streaming_body_writes_through_the_stream
    streamed = lambda do |stream|
      stream.write('a')
      stream << 'b'
      stream.flush
      assert_nil stream.read
      stream.close
      assert stream.closed?
    end
    app = ->(_env) { [200, {}, streamed] }

    with_link(app) do |mothership, _io|
      assert_equal 'ab', mothership.request(params).body
    end
  end

  def test_to_path_bodies_are_offloaded_to_mothership_as_files
    file = Tempfile.new('shuttlebay')
    file.write('file contents')
    file.flush
    body = Object.new
    body.define_singleton_method(:to_path) { file.path }
    body.define_singleton_method(:each) { |&block| block.call(File.read(file.path)) }
    statuses = [200, 206]
    app = ->(_env) { [statuses.shift, { 'content-type' => 'text/plain' }, body] }

    with_link(app) do |mothership, _io|
      offloaded = mothership.request(params)
      assert_equal :file, offloaded.kind
      assert_equal File.expand_path(file.path), offloaded.path
      assert_nil offloaded.body

      partial = mothership.request(params)
      assert_equal :stream, partial.kind, 'only 200s may be served from disk as a whole file'
    end
  ensure
    file&.close!
  end

  def test_head_and_bodyless_statuses_never_iterate_the_body
    closed = []
    body = Object.new
    body.define_singleton_method(:each) { |*| raise 'body must not be iterated' }
    body.define_singleton_method(:close) { closed << true }
    statuses = [200, 204, 304]
    app = ->(_env) { [statuses.shift, { 'content-length' => '42' }, body] }

    with_link(app) do |mothership, _io|
      head = mothership.request(params('REQUEST_METHOD' => 'HEAD'))
      no_content = mothership.request(params)
      not_modified = mothership.request(params)

      assert_equal %i[empty empty empty], [head, no_content, not_modified].map(&:kind)
      assert_equal ['42'], head.header('content-length')
    end
    assert_equal 3, closed.size
  end

  def test_app_exception_becomes_a_500_and_is_logged
    seen = []
    app = lambda do |env|
      env['rack.response_finished'] << ->(*args) { seen << args }
      raise ArgumentError, 'boom'
    end

    with_link(app) do |mothership, _io|
      reply = mothership.request(params('PATH_INFO' => '/explode'))

      assert_equal 500, reply.status
      assert_equal 'Internal Server Error', reply.body
      assert_equal 500, mothership.request(params).status, 'link stays usable after a 500'
    end
    error = log_lines.find { |line| line['msg'] == 'request failed' }
    assert_equal 'ArgumentError', error['error']
    assert_equal '/explode', error['path']
    assert_kind_of ArgumentError, seen.first.last
  end

  def test_failure_after_head_aborts_the_link
    body = Object.new
    body.define_singleton_method(:each) do |&block|
      block.call('partial')
      raise 'stream broke'
    end
    app = ->(_env) { [200, {}, body] }

    with_link(app) do |mothership, _io|
      id = mothership.send_request(params)
      assert_equal :stream, mothership.read_reply.kind
      assert_equal ['partial', false], mothership.read_haul(id)

      assert_nil mothership.read_frame, 'link must close without FIN'
    end
  end

  def test_response_finished_runs_in_reverse_order_with_response
    calls = []
    app = lambda do |env|
      %i[first second].each do |name|
        env['rack.response_finished'] << ->(_env, status, _headers, error) { calls << [name, status, error] }
      end
      [202, {}, ['done']]
    end

    with_link(app) { |mothership, _io| mothership.request(params) }

    assert_equal [[:second, 202, nil], [:first, 202, nil]], calls
  end

  def test_ready_follows_the_response_finished_callbacks
    gate = Thread::Queue.new
    app = lambda do |env|
      env['rack.response_finished'] << proc { gate.pop }
      [200, {}, ['done']]
    end

    with_link(app) do |mothership, _io|
      id = mothership.send_request(params)
      assert_equal :stream, mothership.read_reply.kind
      assert_equal ['done'], mothership.read_chunks(id)
      assert_nil mothership.io.wait_readable(0.1), 'no Ready while the callback runs'

      gate << :go
      mothership.read_ready(id)
    end
  end

  def test_large_bodies_spool_to_an_unlinked_tempfile
    seen = {}
    app = lambda do |env|
      input = env['rack.input']
      seen[:class] = input.class
      seen[:path] = input.respond_to?(:path) ? input.path : :none
      seen[:digest] = Digest::SHA256.hexdigest(input.read)
      seen[:input] = input
      [200, {}, ['ok']]
    end
    small = 's' * 100
    large = Random.bytes(Shuttlebay::Engine::SPOOL_THRESHOLD + 12_345)

    with_link(app) do |mothership, _io|
      mothership.request(params, body: small)
      assert_equal StringIO, seen[:class], 'small bodies stay in memory'

      mothership.request(params('CONTENT_LENGTH' => large.bytesize.to_s), body: large, chunk: 100_000)
      assert_equal Tempfile, seen[:class], 'bodies over SPOOL_THRESHOLD go to disk'
      assert_nil seen[:path], 'the spool file is unlinked: nothing to clean up'
      assert_equal Digest::SHA256.hexdigest(large), seen[:digest], 'spooled bytes intact'
      assert seen[:input].closed?, 'rack.input is closed once the request is done'
    end
  end

  def test_upgrades_the_app_does_not_hijack_get_a_plain_reply
    app = ->(env) { [200, {}, ["plain #{env['rack.hijack?']}"]] }

    with_link(app) do |mothership, _io|
      upgrade = params('HTTP_UPGRADE' => 'websocket', 'HTTP_CONNECTION' => 'Upgrade')
      assert_equal 'plain true', mothership.request(upgrade).body, 'hijack offered, not taken'
      assert_equal 'plain false', mothership.request(params).body, 'the link keeps serving'
    end
  end

  def test_hijacked_upgrades_become_tunnels_and_free_the_thread
    hijacks = Queue.new
    app = lambda do |env|
      return [200, {}, ["plain #{env['rack.hijack?']}"]] unless env['HTTP_UPGRADE']

      io = env['rack.hijack'].call
      io.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: echo\r\nConnection: Upgrade\r\n\r\nhello")
      hijacks << Thread.new do
        while (data = io.readpartial(1024))
          io.write(data.upcase)
        end
      rescue EOFError
        io.close
      end
      [-1, {}, []]
    end

    with_link(app) do |mothership, _io|
      assert_equal 'plain false', mothership.request(params).body, 'no hijack offered without Upgrade'

      id = mothership.send_request(params('HTTP_UPGRADE' => 'echo', 'HTTP_CONNECTION' => 'Upgrade'))
      reply = mothership.read_reply
      assert_equal [:tunnel, 101], [reply.kind, reply.status]
      assert_equal ['echo'], reply.header('upgrade')
      assert_equal 'hello', mothership.read_tunnel(id), 'bytes written after the head are relayed'

      mothership.write_tunnel(id, 'ping')
      assert_equal 'PING', mothership.read_tunnel(id)

      mothership.write_tunnel(id, '', fin: true)
      assert_nil mothership.read_tunnel(id), 'the app closing its side sends FIN'
      assert_nil mothership.read_frame, 'the tunnel closes the link'
      hijacks.pop.join(2)
    end
  end

  def test_tunnel_accepts_a_head_with_bare_lf_line_endings
    app = lambda do |env|
      io = env['rack.hijack'].call
      io.write("HTTP/1.1 101 Switching Protocols\nUpgrade: echo\n\nafter-head")
      io.close
      [-1, {}, []]
    end

    with_link(app) do |mothership, _io|
      id = mothership.send_request(params('HTTP_UPGRADE' => 'echo'))
      reply = mothership.read_reply
      assert_equal [:tunnel, 101, ['echo']], [reply.kind, reply.status, reply.header('upgrade')]
      assert_equal 'after-head', mothership.read_tunnel(id)
      assert_nil mothership.read_tunnel(id), 'app closed: FIN'
    end
  end

  def test_sequential_requests_share_one_link_with_isolated_envs
    app = lambda do |env|
      env['rack.response_finished'] << proc {}
      [200, {}, ["#{env['PATH_INFO']}:#{env['rack.response_finished'].size}:#{env['rack.input'].read}"]]
    end

    with_link(app) do |mothership, _io|
      replies = %w[/a /b /c].map do |path|
        mothership.request(params('PATH_INFO' => path), body: "#{path}-body")
      end

      assert_equal %w[/a:1:/a-body /b:1:/b-body /c:1:/c-body], replies.map(&:body)
      assert_equal [1, 2, 3], replies.map(&:id)
    end
  end
end
