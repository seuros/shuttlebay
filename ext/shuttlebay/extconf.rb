# frozen_string_literal: true

require 'mkmf'

abort "shuttlebay: the native engine needs CRuby (running #{RUBY_ENGINE})" unless RUBY_ENGINE == 'ruby'
abort 'shuttlebay: cargo not found; install Rust (mise use rust) or use a platform gem' unless find_executable('cargo')

begin
  require 'rb_sys/mkmf'
rescue LoadError => e
  abort "shuttlebay: rb_sys is required to build the native engine (#{e.message})"
end

create_rust_makefile('shuttlebay/shuttlebay') do |r|
  ext_dir = Pathname(__dir__)
  r.ext_dir = begin
    ext_dir.relative_path_from(Pathname(Dir.pwd)).to_s
  rescue ArgumentError
    ext_dir.expand_path.to_s
  end
  r.profile = ENV.fetch('RB_SYS_CARGO_PROFILE', :release).to_sym
end
