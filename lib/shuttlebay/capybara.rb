# frozen_string_literal: true

require 'capybara'
require_relative 'attached'

Capybara.register_server(:shuttlebay) do |app, port, host, **options|
  Shuttlebay::Attached.new(app, Host: host, Port: port, Silent: true, trap_signals: false, **options).run
end
