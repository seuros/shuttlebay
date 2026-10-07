# frozen_string_literal: true

require 'rack/sendfile'

module Shuttlebay
  class Railtie < ::Rails::Railtie
    initializer 'shuttlebay.mothership_serves_files' do |app|
      app.config.middleware.delete(::Rack::Sendfile) if Shuttlebay.running?
    end
  end
end
