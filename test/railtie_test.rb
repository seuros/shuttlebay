# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'open3'

class RailtieTest < Minitest::Test
  include SubprocessHarness

  APP = <<~RUBY
    require "bundler/setup"
    require "logger"
    require "rails"
    require "action_controller/railtie"
    require "shuttlebay/runtime"
    Shuttlebay.running = ARGV.first == "under-shuttlebay"
    require "shuttlebay"
    Shuttlebay.logger = Shuttlebay::Logger.new($stderr)

    class MiddlewareProbe < Rails::Application
      config.root = Dir.pwd
      config.eager_load = false
      config.logger = Logger.new(nil)
      config.secret_key_base = "x" * 64
      config.action_dispatch.x_sendfile_header = "X-Sendfile"
      config.public_file_server.enabled = true
      config.public_file_server.headers = { "Cache-Control" => "public, max-age=31536000", "X-Served" => "app" }
    end
    MiddlewareProbe.initialize!
    print MiddlewareProbe.middleware.map(&:name).grep(/Sendfile|Static|ETag|ConditionalGet/).sort.join(",")
  RUBY

  ALL = 'ActionDispatch::Static,Rack::ConditionalGet,Rack::ETag,Rack::Sendfile'

  def test_rack_sendfile_is_removed_only_under_shuttlebay
    assert_equal 'ActionDispatch::Static,Rack::ConditionalGet,Rack::ETag', boot('under-shuttlebay'),
                 'mothership serves to_path bodies itself'
    assert_equal ALL, boot('plain-rails'), "other servers keep the app's Rack::Sendfile"
  end

  def test_what_mothership_announces_it_does_leaves_the_stack
    env = ->(dir) { { 'MS_CONDITIONAL_GET' => '1', 'MS_STATIC_ROOTS' => "/elsewhere\n#{File.realpath(dir)}/public" } }
    assert_equal '', boot('under-shuttlebay', env), 'static files and revalidation are done by Mothership'
    assert_equal ALL, boot('plain-rails', env), 'only a bay trusts what Mothership announces'

    other_root = ->(_dir) { { 'MS_STATIC_ROOTS' => '/srv/another-app/public' } }
    assert_equal 'ActionDispatch::Static,Rack::ConditionalGet,Rack::ETag', boot('under-shuttlebay', other_root),
                 "another directory being served is not the app's public/"
  end

  def test_public_file_server_headers_mothership_does_not_send_are_reported
    announce = lambda do |headers|
      lambda do |dir|
        public = "#{File.realpath(dir)}/public"
        { 'MS_STATIC_ROOTS' => public, 'MS_STATIC_HEADERS' => JSON.generate(public => headers) }
      end
    end

    boot('under-shuttlebay', announce.call('cache-control' => 'public, max-age=31536000'))
    warning = JSON.parse(@log.lines.grep(/public_file_server/).fetch(0))
    assert_equal 'warn', warning['level']
    assert_equal({ 'x-served' => 'app' }, warning['missing'], 'only what Mothership does not send as given')

    boot('under-shuttlebay', announce.call('cache-control' => 'public, max-age=31536000', 'x-served' => 'app'))
    assert_empty @log.lines.grep(/public_file_server/), 'nothing to report when Mothership sends them all'

    boot('plain-rails', announce.call({}))
    assert_empty @log.lines.grep(/public_file_server/), 'outside Mothership the app serves its own files'
  end

  private

  def boot(mode, env = ->(_dir) { {} })
    Dir.mktmpdir('shuttlebay-railtie') do |dir|
      Dir.mkdir(File.join(dir, 'public'))
      out, @log, status = Open3.capture3(env.call(dir), *ruby_script(APP, mode), chdir: dir)
      assert status.success?, "#{mode} app failed to boot:\n#{@log}"
      out
    end
  end
end
