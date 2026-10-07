# frozen_string_literal: true

require_relative 'lib/shuttlebay/version'

Gem::Specification.new do |spec|
  spec.name = 'shuttlebay'
  spec.version = Shuttlebay::VERSION
  spec.authors = ['Abdelkader Boudih']
  spec.email = ['oss@seuros.com']

  spec.summary = 'Run Rack apps as Mothership bays'
  spec.description = <<~DESC
    Shuttlebay serves a Rack app (Rails, Sinatra, Roda) as a Mothership
    [[bays.http]] bay. Mothership owns HTTP; a native engine turns docking
    protocol frames into Rack calls on preforked, threaded workers.
  DESC
  spec.homepage = 'https://github.com/seuros/shuttlebay'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 4.0'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['cargo_crate_name'] = 'shuttlebay'
  spec.metadata['cargo_manifest_path'] = 'ext/shuttlebay/Cargo.toml'

  spec.files = Dir['lib/**/*.rb'] + Dir['ext/shuttlebay/**/*.{rs,rb,toml}'] +
               %w[Cargo.toml Cargo.lock exe/shuttlebay README.md LICENSE.txt]
  spec.extensions = ['ext/shuttlebay/extconf.rb']
  spec.bindir = 'exe'
  spec.executables = ['shuttlebay']
  spec.require_paths = ['lib']

  spec.add_dependency 'rack', '>= 3.0'
  spec.add_dependency 'rb_sys', '~> 0.9'

  spec.add_development_dependency 'async', '~> 2.46'
  spec.add_development_dependency 'capybara', '>= 3.40'
  spec.add_development_dependency 'minitest', '~> 6.0'
  spec.add_development_dependency 'railties', '>= 8.1'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rake-compiler', '~> 1.3'
end
