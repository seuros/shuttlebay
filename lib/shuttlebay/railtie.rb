# frozen_string_literal: true

require 'json'
require 'rack/sendfile'

module Shuttlebay
  # Under Mothership, some of a Rails app's middleware repeats work Mothership
  # already does for its HTTP bays: the app's copy is removed. Other servers
  # (rails server, Puma) keep the full stack.
  #
  # - Rack::Sendfile: Mothership serves `to_path` bodies itself.
  # - ActionDispatch::Static: when Mothership serves the app's public/ at `/`
  #   for everything routed to the bay (it lists those in MS_STATIC_ROOTS).
  #   The app's `public_file_server.headers` Mothership does not send (per
  #   MS_STATIC_HEADERS) are logged: they belong in the manifest now.
  # - Rack::ETag, Rack::ConditionalGet: when Mothership tags responses and
  #   answers revalidations (MS_CONDITIONAL_GET=1), off the app's GVL.
  class Railtie < ::Rails::Railtie
    initializer 'shuttlebay.mothership_serves_files' do |app|
      next unless Shuttlebay.running?

      middleware = app.config.middleware
      middleware.delete(::Rack::Sendfile) if Shuttlebay.offloaded?(:sendfile)
      public = app.paths['public'].first
      if Shuttlebay.offloaded?(:static, public)
        middleware.delete(::ActionDispatch::Static)
        Shuttlebay::Railtie.warn_unsent_headers(public, app.config.public_file_server.headers)
      end
      if Shuttlebay.offloaded?(:conditional_get)
        middleware.delete(::Rack::ETag)
        middleware.delete(::Rack::ConditionalGet)
      end
    end

    # The app's `headers` for public/ files that Mothership, serving them
    # now, does not send as given; logged once, at boot.
    def self.warn_unsent_headers(public, headers, announced = ENV.fetch('MS_STATIC_HEADERS', '{}'))
      unsent = unsent_headers(public, headers, announced)
      return if unsent.empty?

      Shuttlebay.logger.warn('public_file_server.headers are not sent by Mothership, which serves public/; ' \
                             'add them to the [[mothership.static_dirs]] headers', missing: unsent)
    end

    def self.unsent_headers(public, headers, announced)
      sent = JSON.parse(announced).fetch(File.realpath(public), {})
      (headers || {}).to_h { |name, value| [name.to_s.downcase, value.to_s] }.reject { |name, value| sent[name] == value }
    rescue JSON::ParserError, SystemCallError
      (headers || {}).to_h { |name, value| [name.to_s.downcase, value.to_s] }
    end
  end
end
