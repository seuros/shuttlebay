# frozen_string_literal: true

require 'stringio'
require_relative 'version'
require_relative 'engine'
require_relative 'logger'

module Shuttlebay
  class Error < StandardError; end

  HOOKS = %i[before_fork worker_boot worker_shutdown out_of_band].freeze

  class << self
    attr_accessor :config

    attr_writer :running, :logger

    def running?
      @running == true
    end

    def logger
      @logger ||= Logger.new
    end

    def before_fork(&block)
      register_hook(:before_fork, block)
    end

    def on_worker_boot(&block)
      register_hook(:worker_boot, block)
    end

    def on_worker_shutdown(&block)
      register_hook(:worker_shutdown, block)
    end

    def out_of_band(&block)
      register_hook(:out_of_band, block)
    end

    attr_reader :fiber_scheduler_factory, :fiber_reactors

    def fiber_scheduler(reactors: 1, &factory)
      raise ArgumentError, 'Shuttlebay.fiber_scheduler needs a block that builds a Fiber scheduler' unless factory

      count = Integer(reactors)
      raise ArgumentError, "Shuttlebay.fiber_scheduler needs reactors >= 1 (got #{reactors.inspect})" if count < 1

      @fiber_reactors = count
      @fiber_scheduler_factory = factory
    end

    def run_hooks(name, *)
      hooks.fetch(name).each { |hook| hook.call(*) }
    end

    def clear_hooks!
      HOOKS.each { |name| hooks[name].clear }
      @fiber_scheduler_factory = @fiber_reactors = nil
    end

    private

    def hooks
      @hooks ||= HOOKS.to_h { |name| [name, []] }
    end

    def register_hook(name, block)
      raise ArgumentError, "Shuttlebay.#{name} needs a block" unless block

      hooks.fetch(name) << block
      block
    end
  end
end

require_relative 'stream'
require_relative 'tunnel'
require_relative 'handler'
require_relative 'process_control'
require_relative 'worker'
require_relative 'server'
