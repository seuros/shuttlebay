# frozen_string_literal: true

require_relative 'test_helper'

class OffloadedTest < Minitest::Test
  def setup
    @running = Shuttlebay.running?
    @env = ENV.to_h.slice('MS_CONDITIONAL_GET', 'MS_STATIC_ROOTS')
    @dir = Dir.mktmpdir('sb-offloaded')
    Dir.mkdir(File.join(@dir, 'public'))
  end

  def teardown
    Shuttlebay.running = @running
    %w[MS_CONDITIONAL_GET MS_STATIC_ROOTS].each { |key| ENV.delete(key) }
    ENV.update(@env)
    FileUtils.rm_rf(@dir)
  end

  def test_what_mothership_announces_is_offloaded_only_under_mothership
    ENV['MS_CONDITIONAL_GET'] = '1'
    ENV['MS_STATIC_ROOTS'] = "/elsewhere\n#{File.realpath(@dir)}/public"
    public = File.join(@dir, 'public')

    Shuttlebay.running = false
    refute Shuttlebay.offloaded?(:sendfile), 'other servers keep their middleware'
    refute Shuttlebay.offloaded?(:conditional_get)
    refute Shuttlebay.offloaded?(:static, public)

    Shuttlebay.running = true
    assert Shuttlebay.offloaded?(:sendfile)
    assert Shuttlebay.offloaded?(:conditional_get)
    assert Shuttlebay.offloaded?(:static, public)
    assert Shuttlebay.offloaded?(:static, File.join(@dir, 'public', '..', 'public')), 'compared as real paths'
    refute Shuttlebay.offloaded?(:static, File.join(@dir, 'missing'))

    ENV['MS_CONDITIONAL_GET'] = '0'
    refute Shuttlebay.offloaded?(:conditional_get), "a bay's own env can turn it off"
  end

  def test_unknown_concerns_and_a_missing_dir_are_mistakes
    Shuttlebay.running = true
    assert_raises(ArgumentError) { Shuttlebay.offloaded?(:compression) }
    assert_raises(ArgumentError) { Shuttlebay.offloaded?(:static) }
  end
end
