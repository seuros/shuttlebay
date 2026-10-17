# frozen_string_literal: true

begin
  ruby_abi = RUBY_VERSION[/\A\d+\.\d+/]
  require_relative "#{ruby_abi}/shuttlebay"
rescue LoadError
  begin
    require_relative 'shuttlebay'
  rescue LoadError => e
    raise LoadError, "shuttlebay native engine is missing (#{e.message}). " \
                     'Install a platform shuttlebay gem, or run `bundle exec rake compile` in a checkout.'
  end
end

require 'tempfile'

module Shuttlebay
  module Engine
    def self.spool_file
      Tempfile.new('shuttlebay-body', binmode: true).tap(&:unlink)
    end

    # The rack.input of a request without a body, like Puma's NullIO: always
    # at EOF and stateless, so one frozen instance serves every request.
    class NullInput
      def gets = nil
      def each = nil
      def rewind = 0
      def close = nil
      def closed? = false
      def eof? = true
      def size = 0
      def string = ''

      def read(length = nil, buffer = nil)
        raise ArgumentError, "negative length #{length} given" if length&.negative?

        buffer = buffer.nil? ? +''.b : String.try_convert(buffer)
        raise TypeError, 'buffer must be a String' unless buffer

        buffer.clear
        length&.positive? ? nil : buffer
      end
    end

    NULL_INPUT = NullInput.new.freeze
  end
end
