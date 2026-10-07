# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'shuttlebay'
require 'shuttlebay/attached'
require 'minitest/autorun'
require 'delegate'
require 'digest'
require 'json'
require 'rbconfig'
require 'socket'
require 'stringio'
require 'timeout'
require 'tmpdir'

class FakeMothership
  DOCK = 0x01
  MOORED = 0x02
  HAIL = 0x20
  HAUL = 0x21
  REPLY = 0x22
  READY = 0x23
  FIN = 0x01
  KINDS = { 0 => :empty, 1 => :stream, 2 => :file, 4 => :tunnel }.freeze

  Reply = Data.define(:id, :status, :headers, :kind, :path, :body) do
    def header(name)
      headers.select { |key, _| key == name }.map(&:last)
    end
  end

  attr_reader :io

  def initialize(io)
    @io = io
    @next_id = 0
  end

  def self.frame(type, payload)
    [type, payload.bytesize].pack('CN') + payload.b
  end

  def self.haul(id, data, fin:)
    frame(HAUL, [id, fin ? FIN : 0].pack('NC') + data.b)
  end

  def self.hail(id, params, content_length)
    pairs = params.map { |name, value| lp(name) + lp(value) }.join
    frame(HAIL, [id, content_length, params.size].pack('NQ>N') + pairs)
  end

  def self.lp(bytes)
    [bytes.bytesize].pack('N') + bytes.b
  end

  def accept_dock(config = {}, version: 3)
    payload = expect_frame(:DOCK)
    @io.write(self.class.frame(MOORED, JSON.generate(version: version, config: config)))
    JSON.parse(payload)
  end

  def send_request(params, body: '', chunk: nil)
    id = (@next_id += 1)
    @io.write(self.class.hail(id, params, body.bytesize))
    unless body.empty?
      pieces = body.b.scan(/.{1,#{chunk || body.bytesize}}/m)
      pieces.each_with_index do |piece, index|
        @io.write(self.class.haul(id, piece, fin: index == pieces.size - 1))
      end
    end
    id
  end

  def read_reply
    payload = expect_frame(:REPLY)
    id, status, flags, count = payload.unpack('NnCN')
    cursor = 11
    take = lambda do
      len = payload.byteslice(cursor, 4).unpack1('N')
      value = payload.byteslice(cursor + 4, len)
      cursor += 4 + len
      value
    end
    headers = Array.new(count) { [take.call, take.call] }
    path = flags == 2 ? take.call : nil
    Reply.new(id, status, headers, KINDS.fetch(flags), path, nil)
  end

  def read_haul(id)
    payload = expect_frame(:HAUL, id)
    [payload.byteslice(5..), payload.getbyte(4).anybits?(FIN)]
  end

  def read_tunnel(id)
    data, fin = read_haul(id)
    fin ? nil : data
  end

  def write_tunnel(id, data, fin: false)
    @io.write(self.class.haul(id, data, fin: fin))
  end

  def read_chunks(id)
    chunks = []
    loop do
      data, fin = read_haul(id)
      chunks << data unless data.empty?
      return chunks if fin
    end
  end

  def request(params, body: '', chunk: nil)
    id = send_request(params, body: body, chunk: chunk)
    reply = read_reply
    reply = reply.with(body: read_chunks(id).join) if reply.kind == :stream
    read_ready(id)
    reply
  end

  def read_ready(id)
    expect_frame(:READY, id)
  end

  def expect_frame(name, id = nil)
    type, payload = read_frame
    raise "expected #{name}, got #{type.inspect}" unless type == self.class.const_get(name)

    frame_id = id && payload.unpack1('N')
    raise "#{name} for #{frame_id}, expected #{id}" unless frame_id == id

    payload
  end

  def read_frame
    header = read_exact(5)
    return nil unless header

    type, len = header.unpack('CN')
    [type, read_exact(len) || raise('EOF inside a frame')]
  end

  def read_exact(len)
    buffer = +''.b
    buffer << @io.readpartial(len - buffer.bytesize) while buffer.bytesize < len
    buffer
  rescue EOFError
    raise "EOF after #{buffer.bytesize} of #{len} bytes" unless buffer.empty?

    nil
  end
end

class CountingIO < SimpleDelegator
  attr_reader :writes

  def initialize(io)
    super
    @writes = 0
  end

  def write(*)
    @writes += 1
    __getobj__.write(*)
  end
end

module EngineHarness
  BASE_ENV = {
    'REQUEST_METHOD' => 'GET',
    'SCRIPT_NAME' => '',
    'PATH_INFO' => '/',
    'QUERY_STRING' => '',
    'SERVER_NAME' => 'example.test',
    'SERVER_PORT' => '80',
    'SERVER_PROTOCOL' => 'HTTP/1.1'
  }.freeze

  def params(overrides = {})
    BASE_ENV.merge(overrides)
  end

  def log_io
    @log_io ||= StringIO.new
  end

  def log_lines(text = log_io.string)
    text.lines.map { |line| JSON.parse(line) }
  end

  def with_link(app, config: { 'role' => 'test' })
    ours, theirs = UNIXSocket.pair
    ship_io = CountingIO.new(theirs)
    logger = Shuttlebay::Logger.new(log_io, ship: 'test')
    handler = Shuttlebay::Handler.new(app, template: Shuttlebay::Worker.template(threads: 2, workers: 2),
                                           logger: logger)
    codec = Shuttlebay::Engine::Codec.new
    server = Thread.new do
      codec.dock(ship_io, 'test-ship', 2)
      outcome = handler.serve(ship_io, codec)
    rescue *Shuttlebay::Handler::LINK_LOST
      nil
    ensure
      theirs.close unless outcome == :detached || theirs.closed?
    end
    mothership = FakeMothership.new(ours)
    mothership.accept_dock(config)
    yield mothership, ship_io
  ensure
    ours&.close unless ours&.closed?
    server&.join(5)
  end
end

module SubprocessHarness
  LIB = File.expand_path('../lib', __dir__)
  EXE = File.expand_path('../exe/shuttlebay', __dir__)
  MOTHERSHIP_BIN = ENV.fetch('MOTHERSHIP_BIN') do
    File.expand_path('../../mothership/target/debug/mothership', __dir__)
  end

  def skip_without_mothership
    skip "no mothership binary at #{MOTHERSHIP_BIN} (set MOTHERSHIP_BIN)" unless File.executable?(MOTHERSHIP_BIN)
  end

  def ruby_script(script, *args)
    [RbConfig.ruby, '-I', LIB, '-e', script, *args]
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  def assert_dead(pid, message = nil, timeout: 10)
    Timeout.timeout(timeout) do
      loop do
        Process.kill(0, pid)
        sleep 0.1
      end
    end
  rescue Errno::ESRCH
    pass
  rescue Timeout::Error
    flunk message || "process #{pid} is still alive"
  end
end
