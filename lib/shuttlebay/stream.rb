# frozen_string_literal: true

module Shuttlebay
  class Stream
    def initialize(io, codec)
      @io = io
      @codec = codec
      @write_closed = false
      @read_closed = false
    end

    def write(data)
      raise IOError, 'closed stream' if @write_closed

      data = String(data)
      @codec.write(@io, data)
      @codec.flush(@io)
      data.bytesize
    end

    def <<(data)
      write(data)
      self
    end

    def flush
      @codec.flush(@io) unless @write_closed
      self
    end

    def read(_length = nil, _buffer = nil)
      raise IOError, 'closed stream' if @read_closed

      nil
    end

    def close_read
      @read_closed = true
      nil
    end

    def close_write
      @write_closed = true
      nil
    end

    def close
      close_read
      close_write
    end

    def closed?
      @read_closed && @write_closed
    end
  end
end
