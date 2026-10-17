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

    attr_writer :running, :logger, :warmup

    def running?
      @running == true
    end

    def warmup?
      @warmup != false
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

    # Whether Mothership does `concern` for this app, so its Rack middleware
    # for it can go (the Railtie does this for Rails; elsewhere, in
    # config.ru):
    #
    #   use Rack::ETag unless Shuttlebay.offloaded?(:conditional_get)
    #   use Rack::Static, urls: [""], root: "public" unless Shuttlebay.offloaded?(:static, "public")
    #
    # - :sendfile: `to_path` bodies are streamed by Mothership (Rack::Sendfile)
    # - :conditional_get: ETags and 304s (Rack::ETag, Rack::ConditionalGet)
    # - :static, dir: `dir` is served at `/`, pages by name included
    #   (Rack::Static, ActionDispatch::Static)
    #
    # Always false outside Mothership.
    def offloaded?(concern, dir = nil)
      return false unless running?

      case concern
      when :sendfile then true
      when :conditional_get then ENV['MS_CONDITIONAL_GET'] == '1'
      when :static then static_root?(dir)
      else raise ArgumentError, "unknown concern #{concern.inspect} (:sendfile, :conditional_get, :static)"
      end
    end

    # Whether Mothership serves `dir` at `/` (it lists those in MS_STATIC_ROOTS).
    def static_root?(dir, roots = ENV.fetch('MS_STATIC_ROOTS', ''))
      raise ArgumentError, 'Shuttlebay.offloaded?(:static, dir) needs the directory' if dir.nil?

      roots.split("\n").include?(File.realpath(dir))
    rescue SystemCallError
      false
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
