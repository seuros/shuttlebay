# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'minitest/test_task'
require 'rb_sys/extensiontask'

GEMSPEC = Gem::Specification.load('shuttlebay.gemspec')

NATIVE_PLATFORMS = %w[
  arm64-darwin
  x86_64-darwin
  aarch64-linux
  x86_64-linux
  x86_64-linux-musl
].freeze

RbSys::ExtensionTask.new('shuttlebay', GEMSPEC) do |ext|
  ext.lib_dir = 'lib/shuttlebay'
  ext.cross_compile = true
  ext.cross_platform = NATIVE_PLATFORMS
end

# Inside rb-sys-dock a platform gem lists the host's lib binary, so packing it
# would compile for the host, which inherits the image's CARGO_BUILD_TARGET and
# links the cross target with the host linker. The gem is packed from its stage
# dir, so the host chain is dead weight there.
host_binary = "lib/shuttlebay/shuttlebay.#{RbConfig::CONFIG['DLEXT']}"
Rake::Task[host_binary].clear if ENV['RUBY_TARGET'] && Rake::Task.task_defined?(host_binary)

Minitest::TestTask.create

task test: :compile
task default: :test

namespace :platforms do
  desc 'Build every platform gem with rb-sys-dock (Docker)'
  task :build do
    NATIVE_PLATFORMS.each do |platform|
      sh 'bundle', 'exec', 'rb-sys-dock', '--platform', platform, '--ruby-versions', '4.0', '--mount-toolchains', '--build'
    end
  end
end

namespace :gems do
  release_version = ->(tag) { (tag || "v#{GEMSPEC.version}").delete_prefix('v') }

  desc 'Download the gems CI attached to a GitHub release into pkg/ (default tag: v<version>)'
  task :fetch, [:tag] do |_task, args|
    version = release_version.call(args[:tag])
    sh 'gh', 'release', 'download', "v#{version}", '--repo', 'seuros/shuttlebay',
       '--pattern', "shuttlebay-#{version}*.gem", '--dir', 'pkg', '--clobber'
  end

  desc 'Fetch a release\'s gems, then push each to rubygems.org'
  task :push, [:tag] => :fetch do |_task, args|
    gems = Dir["pkg/shuttlebay-#{release_version.call(args[:tag])}*.gem"]
    abort 'no gems in pkg/ for this release' if gems.empty?

    failed = gems.reject { |gem| system('gem', 'push', gem) }
    abort "not pushed: #{failed.join(', ')}" if failed.any?
  end
end
