# frozen_string_literal: true

require_relative 'test_helper'

class CodecTest < Minitest::Test
  include EngineHarness

  def setup
    @ours, @theirs = UNIXSocket.pair
    @codec = Shuttlebay::Engine::Codec.new
    @mothership = FakeMothership.new(@ours)
  end

  def teardown
    [@ours, @theirs].each { |io| io.close unless io.closed? }
  end

  def test_dock_announces_ship_and_returns_moored_config
    dock = Thread.new { @codec.dock(@theirs, 'web', 4) }
    announced = @mothership.accept_dock({ 'database_url' => 'postgres://db' })

    assert_equal({ 'version' => 3, 'ship' => 'web', 'pid' => Process.pid, 'threads' => 4 }, announced)
    assert_equal({ 'database_url' => 'postgres://db' }, dock.value)
  end

  def test_dock_rejects_a_pre_v3_mothership
    dock = Thread.new do
      Thread.current.report_on_exception = false
      @codec.dock(@theirs, 'web', 1)
    end
    @mothership.accept_dock({}, version: 2)

    error = assert_raises(Shuttlebay::Engine::ProtocolError) { dock.value }
    assert_match(/v2/, error.message)
  end

  def test_read_request_builds_env_from_params_and_hauled_body
    body = 'name=mothership&kind=rack'
    @mothership.send_request(
      params('REQUEST_METHOD' => 'POST', 'CONTENT_TYPE' => 'application/x-www-form-urlencoded',
             'CONTENT_LENGTH' => body.bytesize.to_s, 'HTTP_X_OPAQUE' => "\xFF\x00raw".b),
      body: body, chunk: 7
    )
    template = Shuttlebay::Worker.template(threads: 5, workers: 2)

    env = @codec.read_request(@theirs, template)

    assert_equal 'POST', env['REQUEST_METHOD']
    assert_equal 'http', env['rack.url_scheme'], 'no HTTPS param means plain http'
    assert_equal "\xFF\x00raw".b, env['HTTP_X_OPAQUE']
    assert_equal Encoding::BINARY, env['PATH_INFO'].encoding
    assert_equal body, env['rack.input'].read
    assert_equal Encoding::BINARY, env['rack.input'].string.encoding
    assert env['rack.multithread']
    assert env['rack.multiprocess']
    refute env['rack.hijack?']
    assert_equal 1, @codec.request_id
    refute template.key?('REQUEST_METHOD'), 'template must not be mutated'
  end

  def test_https_param_sets_the_rack_url_scheme
    @mothership.send_request(params('HTTPS' => 'on'))

    env = @codec.read_request(@theirs, {})

    assert_equal 'https', env['rack.url_scheme']
    assert_equal 'on', env['HTTPS'], 'the CGI variable stays for apps that read it'
  end

  def test_env_keys_and_fixed_values_are_shared_frozen_strings
    envs = Array.new(2) do
      @mothership.send_request(params('HTTP_ACCEPT' => 'text/html'))
      env = @codec.read_request(@theirs, {})
      @codec.reply(@theirs, 204, {}, :empty)
      @codec.finish(@theirs)
      @codec.ready(@theirs)
      env
    end

    first, second = envs.map { |env| env.keys.to_h { |key| [key, key] } }
    assert(first.keys.all? { |key| first[key].equal?(second[key]) }, 'env keys are reused, not reallocated')
    assert(first.keys.all?(&:frozen?))
    assert_same envs[0]['REQUEST_METHOD'], envs[1]['REQUEST_METHOD']
    assert_predicate envs[0]['REQUEST_METHOD'], :frozen?
    assert_equal Encoding::BINARY, envs[0]['REQUEST_METHOD'].encoding
    refute_predicate envs[0]['HTTP_ACCEPT'], :frozen?, 'header values stay fresh Strings'
    refute_same envs[0]['PATH_INFO'], envs[1]['PATH_INFO']
  end

  def test_bodiless_requests_share_the_null_input
    @mothership.send_request(params)

    input = @codec.read_request(@theirs, {})['rack.input']

    assert_same Shuttlebay::Engine::NULL_INPUT, input
    assert_equal '', input.read
    assert_equal Encoding::BINARY, input.read.encoding
    assert_nil input.read(10)
    assert_equal '', input.read(0)
    assert_nil input.gets
    buffer = +'stale'
    assert_same buffer, input.read(nil, buffer)
    assert_empty buffer
    input.close
    assert_equal '', input.read, 'closing the shared input is a no-op'
  end

  def test_read_request_returns_nil_on_clean_eof
    @ours.close

    assert_nil @codec.read_request(@theirs, {})
  end

  def test_eof_inside_a_frame_is_a_protocol_error
    @ours.write(FakeMothership.hail(1, params, 0).byteslice(0, 9))
    @ours.close

    assert_raises(Shuttlebay::Engine::ProtocolError) { @codec.read_request(@theirs, {}) }
  end

  def test_protocol_violations_raise_protocol_error
    hail = FakeMothership.hail(1, params, 4)
    cases = {
      'HAUL for another request' => hail + FakeMothership.haul(2, 'body', fin: true),
      'body shorter than CONTENT_LENGTH' => hail + FakeMothership.haul(1, 'abc', fin: true),
      'HAUL before any HAIL' => FakeMothership.haul(1, 'x', fin: true),
      'unknown frame type' => [0x7f, 0].pack('CN')
    }

    cases.each do |name, bytes|
      setup
      @ours.write(bytes)
      assert_raises(Shuttlebay::Engine::ProtocolError, name) { @codec.read_request(@theirs, {}) }
      teardown
    end
  end

  def test_reply_state_machine_guards_misuse
    assert_raises(Shuttlebay::Engine::ProtocolError) { @codec.reply(@theirs, 200, {}, :empty) }

    @mothership.send_request(params)
    @codec.read_request(@theirs, {})
    assert_raises(ArgumentError) { @codec.reply(@theirs, 99, {}, :empty) }
    assert_raises(ArgumentError) { @codec.reply(@theirs, 200, {}, :file) }
    assert_raises(ArgumentError) { @codec.reply(@theirs, 200, {}, :teleport) }
    assert_raises(TypeError) { @codec.reply(@theirs, 200, { 'x-count' => 1 }, :empty) }

    @codec.reply(@theirs, 200, {}, :empty)
    assert_raises(Shuttlebay::Engine::ProtocolError) { @codec.reply(@theirs, 200, {}, :empty) }
    assert_raises(Shuttlebay::Engine::ProtocolError) { @codec.write(@theirs, 'body') }
    assert_raises(Shuttlebay::Engine::ProtocolError) { @codec.ready(@theirs) }
    @codec.finish(@theirs)
    refute_nil @codec.request_id, 'the request owns the thread until ready'
    assert_raises(Shuttlebay::Engine::ProtocolError) { @codec.read_request(@theirs, {}) }
    @codec.ready(@theirs)
    assert_nil @codec.request_id
  end

  def test_a_finished_stream_takes_no_more_body
    @mothership.send_request(params)
    @codec.read_request(@theirs, {})
    @codec.reply(@theirs, 200, {}, :stream)
    @codec.finish(@theirs)

    error = assert_raises(Shuttlebay::Engine::ProtocolError) { @codec.write(@theirs, 'late') }
    assert_equal 'write needs a :stream reply first', error.message
    assert_raises(Shuttlebay::Engine::ProtocolError) { @codec.finish(@theirs) }
    @codec.ready(@theirs)
  end

  def test_reply_whole_sends_head_body_and_fin_in_one_write
    counting = CountingIO.new(@theirs)
    page = 'p' * 200_000
    @mothership.send_request(params)
    @codec.read_request(counting, {})

    writer = Thread.new { @codec.reply_whole(counting, 200, { 'content-type' => 'text/html' }, [page]) }
    reply = @mothership.read_reply
    chunks = @mothership.read_chunks(reply.id)
    writer.join

    assert_equal 1, counting.writes, 'a page past the flush threshold still leaves in one write'
    assert_equal :stream, reply.kind
    assert_equal [page], chunks
    assert_raises(Shuttlebay::Engine::ProtocolError) { @codec.write(counting, 'late') }
    @codec.ready(counting)
  end

  def test_reply_whole_frames_several_chunks_and_ends_with_fin
    @mothership.send_request(params)
    @codec.read_request(@theirs, {})

    @codec.reply_whole(@theirs, 200, {}, ['a', '', 'b' * 10, ''])
    reply = @mothership.read_reply

    assert_equal "a#{'b' * 10}", @mothership.read_chunks(reply.id).join
    @codec.ready(@theirs)
  end

  def test_reply_whole_with_no_chunks_is_an_empty_stream
    @mothership.send_request(params)
    @codec.read_request(@theirs, {})

    @codec.reply_whole(@theirs, 200, {}, [])
    reply = @mothership.read_reply

    assert_equal [], @mothership.read_chunks(reply.id)
  end

  def test_reply_whole_rejects_non_string_chunks_before_replying
    @mothership.send_request(params)
    @codec.read_request(@theirs, {})

    error = assert_raises(TypeError) { @codec.reply_whole(@theirs, 200, {}, ['ok', 42]) }
    assert_match(/Integer/, error.message)
    @codec.reply(@theirs, 500, {}, :empty)
    @codec.finish(@theirs)
    assert_equal 500, @mothership.read_reply.status, 'the link can still answer the request'
  end

  def test_large_chunks_are_split_at_the_haul_limit
    @mothership.send_request(params)
    @codec.read_request(@theirs, {})
    big = 'x' * ((Shuttlebay::Engine::HAUL_CHUNK_LEN * 2) + 10)

    writer = Thread.new do
      @codec.reply(@theirs, 200, {}, :stream)
      @codec.write(@theirs, big)
      @codec.finish(@theirs)
    end
    reply = @mothership.read_reply
    chunks = @mothership.read_chunks(reply.id)
    writer.join

    assert_equal [Shuttlebay::Engine::HAUL_CHUNK_LEN, Shuttlebay::Engine::HAUL_CHUNK_LEN, 10],
                 chunks.map(&:bytesize)
  end
end
