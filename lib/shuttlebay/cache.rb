# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Shuttlebay
  # Mothership's edge cache, from the app: tag responses with the data they
  # show, and purge the tags when that data changes, so entries live until
  # purged instead of until a guessed TTL runs out.
  #
  #   # in a controller
  #   Shuttlebay::Cache.tag(response.headers, "book-#{@book.id}", 'books')
  #   # in a model
  #   after_commit { Shuttlebay::Cache.purge(tags: ["book-#{id}", 'books']) }
  #
  # Purging works from any process Mothership runs (web workers, job
  # workers): it posts to the admin endpoint in MS_ADMIN_URL, which
  # Mothership sets when it has a metrics port.
  module Cache
    HEADER = 'cache-tag'

    module_function

    # Add `tags` to the response's Cache-Tag (Mothership keeps it from clients).
    def tag(headers, *tags)
      tags = tags.flatten.map { |tag| tag.to_s.strip }.reject(&:empty?)
      return headers if tags.empty?

      headers[HEADER] = [headers[HEADER], *tags].compact.reject(&:empty?).join(', ')
      headers
    end

    # Purge the entries tagged with any of `tags`, for any of `urls` (path and
    # query), under any of `prefixes`, or `all`. `soft: true` marks them stale
    # instead: still served while one request refreshes them. Returns how many
    # were purged; nil outside Mothership (no MS_ADMIN_URL), where there is no
    # cache to purge. A purge Mothership refuses raises Shuttlebay::Error.
    def purge(tags: [], urls: [], prefixes: [], all: false, soft: false, admin_url: ENV.fetch('MS_ADMIN_URL', nil),
              timeout: 2)
      params = Array(tags).map { |tag| ['tag', tag.to_s] } + Array(urls).map { |url| ['url', url.to_s] } +
               Array(prefixes).map { |prefix| ['prefix', prefix.to_s] }
      params << %w[all true] if all
      raise ArgumentError, 'purge needs tags, urls, prefixes or all: true' if params.empty?
      return nil if admin_url.nil? || admin_url.empty?

      params << %w[soft true] if soft
      post_purge(URI.join(admin_url, '/cache/purge').tap { |uri| uri.query = URI.encode_www_form(params) }, timeout)
    end

    def post_purge(uri, timeout)
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: timeout, read_timeout: timeout) do |http|
        http.post(uri.request_uri, '')
      end
      raise Error, "cache purge failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body).fetch('purged')
    end
    private_class_method :post_purge
  end
end
