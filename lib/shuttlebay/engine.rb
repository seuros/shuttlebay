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
  end
end
