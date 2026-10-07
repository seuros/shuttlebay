# frozen_string_literal: true

require 'json'

module Shuttlebay
  class Logger
    LEVELS = %i[debug info warn error].freeze

    def initialize(io = $stdout, ship: ENV.fetch('MS_SHIP', 'rack'))
      @io = io
      @io.sync = true
      @ship = ship
    end

    LEVELS.each do |level|
      define_method(level) { |msg, **fields| log(level, msg, **fields) }
    end

    def log(level, msg, **fields)
      line = JSON.generate({ level: level, msg: msg, ship: @ship, pid: Process.pid, **fields })
      @io.write("#{line}\n")
    end

    def self.error_fields(error)
      { error: error.class.name, message: error.message, backtrace: error.backtrace.first(10) }
    end
  end
end
