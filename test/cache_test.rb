# frozen_string_literal: true

require_relative 'test_helper'

class CacheTest < Minitest::Test
  def test_tags_add_to_the_cache_tag_header
    headers = {}
    Shuttlebay::Cache.tag(headers, 'book-1', ['books', ' ', nil])
    Shuttlebay::Cache.tag(headers, :'file-2')

    assert_equal 'book-1, books, file-2', headers['cache-tag']
    assert_same headers, Shuttlebay::Cache.tag(headers), 'no tags, nothing added'
  end

  def test_purge_posts_what_it_selects_to_the_admin_endpoint
    seen = Queue.new
    with_admin(seen, 200, '{"purged":3}') do |url|
      purged = Shuttlebay::Cache.purge(tags: %w[book-1 books], urls: ['/api/v1/books?page=2'], soft: true, admin_url: url)
      assert_equal 3, purged
    end
    method, target = seen.pop
    assert_equal 'POST', method
    assert_equal '/cache/purge?tag=book-1&tag=books&url=%2Fapi%2Fv1%2Fbooks%3Fpage%3D2&soft=true', target
  end

  def test_purge_outside_mothership_is_a_no_op_but_a_refusal_raises
    assert_nil Shuttlebay::Cache.purge(all: true, admin_url: nil)
    assert_raises(ArgumentError) { Shuttlebay::Cache.purge(admin_url: nil) }

    with_admin(Queue.new, 404, 'The response cache is not enabled') do |url|
      error = assert_raises(Shuttlebay::Error) { Shuttlebay::Cache.purge(all: true, admin_url: url) }
      assert_match(/404/, error.message)
    end
  end

  private

  # MOCKED: Mothership's admin endpoint, answering every request with
  # `status` and `body` and reporting each request line to `seen`.
  def with_admin(seen, status, body)
    server = TCPServer.new('127.0.0.1', 0)
    thread = Thread.new do
      client = server.accept
      method, target, = client.gets.split
      seen << [method, target]
      nil while (line = client.gets) && line != "\r\n"
      client.write("HTTP/1.1 #{status} X\r\ncontent-length: #{body.bytesize}\r\nconnection: close\r\n\r\n#{body}")
      client.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    thread&.join(5)
    server&.close
  end
end
