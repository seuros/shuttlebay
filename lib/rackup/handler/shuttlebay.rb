# frozen_string_literal: true

require 'rackup/handler'
require 'shuttlebay/attached'

module Rackup
  module Handler
    module Shuttlebay
      def self.run(app, **)
        server = ::Shuttlebay::Attached.new(app, **)
        yield server if block_given?
        server.run
      end

      def self.valid_options
        {
          'Host=HOST' => 'Address Mothership listens on (default: 127.0.0.1)',
          'Port=PORT' => 'Port Mothership listens on (default: 9292)',
          'Threads=N' => 'Threads running the app (default: MS_BAY_THREADS or 3)'
        }
      end
    end

    register :shuttlebay, Shuttlebay
  end
end
