# frozen_string_literal: true

require_relative 'test_helper'

# Every way a Rack 3 app may answer, through a real Mothership and its
# Shuttlebay workers, with Rack::Lint checking the env Shuttlebay builds and
# the bodies it drives.
class RackConformanceTest < Minitest::Test
  include MothershipHarness

  CONFIG_RU = <<~'RUBY'
    require "digest"
    require "json"
    require "rack/lint"

    LINT_ERRORS = File.join(Dir.pwd, "lint-errors.log")
    FINISHED = File.join(Dir.pwd, "finished.log")

    class EachBody
      def each
        yield "one,"
        yield ""
        yield "two"
      end

      def close; end
    end

    class FileBody
      def initialize(path) = @path = path
      def to_path = @path
      def each = yield(File.binread(@path))
    end

    app = lambda do |env|
      text = { "content-type" => "text/plain" }
      case env["PATH_INFO"]
      when "/array" then [200, text, ["hello ", "world"]]
      when "/each" then [200, text, EachBody.new]
      when "/stream"
        [200, text, ->(stream) { stream.write("str"); stream.write("eam"); stream.close }]
      when "/file" then [200, text, FileBody.new(File.join(Dir.pwd, "config.ru"))]
      when "/headers" then [200, { "set-cookie" => ["a=1", "b=2"], "x-multi" => ["x", "y"] }, ["h"]]
      when "/empty" then [204, {}, []]
      when "/env"
        strings = env.select { |key, value| value.is_a?(String) && (key == key.upcase || key == "rack.url_scheme") }
        [200, { "content-type" => "application/json" }, [JSON.generate(strings)]]
      when "/echo"
        input = env["rack.input"]
        [200, text, [Digest::SHA256.hexdigest("#{input.gets}#{input.read}")]]
      when "/finished"
        env["rack.response_finished"] << ->(*) { File.write(FINISHED, "done") }
        [200, text, ["ok"]]
      else [404, text, ["no route"]]
      end
    end

    # A Lint error raised before the response is a 500 naming it; every
    # one is kept for the test, the ones raised while the body is read too.
    caught = lambda do |env|
      Rack::Lint.new(app).call(env)
    rescue Rack::Lint::LintError => e
      File.write(LINT_ERRORS, "#{env['PATH_INFO']}: #{e.message}\n", mode: "a")
      [500, { "content-type" => "text/plain" }, ["lint: #{e.message}"]]
    end

    map("/lint") { run caught }
    map("/pid") { run ->(_env) { [200, {}, [Process.pid.to_s]] } }
  RUBY

  def setup
    prepare_mothership(CONFIG_RU)
  end

  def test_every_rack_body_and_env_key_holds_up_under_lint
    start_mothership

    assert_equal 'hello world', ok('/lint/array').body
    assert_equal 'one,two', ok('/lint/each').body
    assert_equal 'stream', ok('/lint/stream').body
    assert_equal CONFIG_RU, ok('/lint/file').body

    headers = ok('/lint/headers')
    assert_equal %w[a=1 b=2], headers.get_fields('set-cookie'), 'array header values become repeated fields'
    assert_equal %w[x y], headers.get_fields('x-multi')

    empty = get('/lint/empty')
    assert_equal '204', empty.code
    assert_nil empty.body

    head = http.request(Net::HTTP::Head.new('/lint/array'))
    assert_equal '200', head.code
    assert_nil head.body

    env = JSON.parse(ok('/lint/env?q=1&r=%20').body)
    expected = {
      'REQUEST_METHOD' => 'GET', 'SCRIPT_NAME' => '/lint', 'PATH_INFO' => '/env', 'QUERY_STRING' => 'q=1&r=%20',
      'SERVER_NAME' => '127.0.0.1', 'SERVER_PORT' => @port.to_s, 'SERVER_PROTOCOL' => 'HTTP/1.1',
      'rack.url_scheme' => 'http', 'HTTP_HOST' => "127.0.0.1:#{@port}"
    }
    assert_equal expected, env.slice(*expected.keys)
    refute env.key?('HTTP_CONTENT_LENGTH'), 'content headers are never HTTP_ prefixed'

    body = "first line\n#{'x' * 100_000}\nlast"
    echoed = post('/lint/echo', body)
    assert_equal '200', echoed.code
    assert_equal Digest::SHA256.hexdigest(body), echoed.body

    assert_equal 'ok', ok('/lint/finished').body
    finished = File.join(@dir, 'finished.log')
    Timeout.timeout(5) { sleep 0.05 until File.exist?(finished) }

    lint_errors = File.join(@dir, 'lint-errors.log')
    assert_equal '', File.exist?(lint_errors) ? File.read(lint_errors) : ''
    assert_empty File.read(@log).lines.grep(/LintError/), 'no Lint error while bodies were read'
  end

  private

  def ok(path)
    response = get(path)
    assert_equal '200', response.code, "#{path}: #{response.body}"
    response
  end
end
