# frozen_string_literal: true

require 'socket'

module Shuttlebay
  class Tunnel
    MAX_HEAD = 64 * 1024
    HEAD_TIMEOUT = 10
    READ_CHUNK = 16 * 1024
    HEAD_END = /\r?\n\r?\n/

    class InvalidHead < StandardError; end

    attr_reader :app_io

    def initialize(logger: Shuttlebay.logger)
      @app_io, @engine_io = UNIXSocket.pair
      @logger = logger
    end

    def discard
      [@app_io, @engine_io].each(&:close)
    end

    def start(io, codec)
      status, headers, rest = read_head
      codec.reply(io, status, headers, :tunnel)
      codec.flush(io)
      codec.tunnel_write(io, rest) unless rest.empty?
      relay(io, codec)
    rescue InvalidHead, *Handler::LINK_LOST, Engine::ProtocolError => e
      @logger.warn('hijacked connection ended before its tunnel opened', **Logger.error_fields(e))
      close(io)
    end

    private

    def relay(io, codec)
      to_client = Thread.new do
        begin
          loop { codec.tunnel_write(io, @engine_io.readpartial(READ_CHUNK)) }
        rescue EOFError
          codec.tunnel_close(io)
        end
      rescue *Handler::LINK_LOST, Engine::ProtocolError
        nil
      end
      Thread.new do
        while (data = codec.tunnel_read(io))
          @engine_io.write(data)
        end
        @engine_io.close_write
      rescue *Handler::LINK_LOST, Engine::ProtocolError
        nil
      ensure
        to_client.join(1)
        close(io)
      end
    end

    def read_head
      buffer = +''.b
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HEAD_TIMEOUT
      until (split = buffer =~ HEAD_END)
        raise InvalidHead, "no response head within #{MAX_HEAD} bytes" if buffer.bytesize > MAX_HEAD

        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise InvalidHead, "app wrote no response head within #{HEAD_TIMEOUT}s" unless left.positive? &&
                                                                                       @engine_io.wait_readable(left)

        buffer << @engine_io.readpartial(READ_CHUNK)
      end
      [*parse_head(buffer.byteslice(0, split)), buffer.byteslice((split + Regexp.last_match(0).bytesize)..)]
    rescue EOFError
      raise InvalidHead, 'app closed the hijacked connection without a response head'
    end

    def parse_head(head)
      status_line, *lines = head.split(/\r?\n/)
      status = status_line[%r{\AHTTP/1\.[01] (\d{3})}, 1] or raise InvalidHead, "bad status line #{status_line.inspect}"
      headers = Hash.new { |hash, key| hash[key] = [] }
      lines.each do |line|
        name, value = line.split(':', 2)
        raise InvalidHead, "bad header line #{line.inspect}" unless value

        headers[name.strip.downcase] << value.strip
      end
      [Integer(status, 10), headers.to_h]
    end

    def close(io)
      [@engine_io, io].each(&:close)
    end
  end
end
