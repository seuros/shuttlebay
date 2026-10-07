# frozen_string_literal: true

require_relative 'test_helper'
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

    class SendfileProbe < Rails::Application
      config.root = Dir.pwd
      config.eager_load = false
      config.logger = Logger.new(nil)
      config.secret_key_base = "x" * 64
      config.action_dispatch.x_sendfile_header = "X-Sendfile"
    end
    SendfileProbe.initialize!
    print SendfileProbe.middleware.map(&:name).include?("Rack::Sendfile")
  RUBY

  def test_rack_sendfile_is_removed_only_under_shuttlebay
    assert_equal 'false', boot('under-shuttlebay'), 'mothership serves to_path bodies itself'
    assert_equal 'true', boot('plain-rails'), "other servers keep the app's Rack::Sendfile"
  end

  private

  def boot(mode)
    Dir.mktmpdir('shuttlebay-railtie') do |dir|
      out, err, status = Open3.capture3(*ruby_script(APP, mode), chdir: dir)
      assert status.success?, "#{mode} app failed to boot:\n#{err}"
      out
    end
  end
end
