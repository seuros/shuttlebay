# frozen_string_literal: true

module Shuttlebay
  class Handler
    BODYLESS_STATUS = ->(status) { status < 200 || status == 204 || status == 304 }

    LINK_LOST = [IOError, Errno::EPIPE, Errno::ECONNRESET, Errno::ENOTCONN, Errno::EBADF].freeze

    INTERNAL_ERROR_BODY = 'Internal Server Error'

    def initialize(app, template:, logger: Shuttlebay.logger)
      @app = app
      @template = template
      @logger = logger
    end

    def serve(io, codec, stopping: -> { false }, after_request: -> {})
      until stopping.call
        env = codec.read_request(io, @template)
        break unless env

        outcome = handle(io, codec, env)
        return :detached if outcome == :detached
        break unless outcome

        run_after_request(after_request)
        codec.ready(io)
      end
    end

    def handle(io, codec, env)
      env['rack.response_finished'] = finished = []
      status = headers = body = error = nil
      tunnel = offer_hijack(env)

      begin
        status, headers, body = @app.call(env)
        return detach(io, codec, tunnel.tap { tunnel = nil }) if tunnel && env['rack.hijack_io']

        status = Integer(status)
      rescue StandardError, ScriptError => e
        error = e
        @logger.error('request failed', path: env['PATH_INFO'], **Logger.error_fields(e))
        return internal_error(io, codec)
      end

      kept, error = respond(io, codec, env, status, headers, body)
      kept
    ensure
      tunnel&.discard
      close_body(body)
      run_finished(finished, env, status, headers, error)
      close_input(env)
    end

    private

    def offer_hijack(env)
      return unless env['HTTP_UPGRADE']

      tunnel = Tunnel.new(logger: @logger)
      env['rack.hijack?'] = true
      env['rack.hijack'] = lambda do
        env['rack.hijack_io'] = tunnel.app_io
      end
      tunnel
    end

    def detach(io, codec, tunnel)
      Thread.new { tunnel.start(io, codec) }
      :detached
    end

    def respond(io, codec, env, status, headers, body)
      head_sent = false
      kind, path = reply_kind(env, status, body)
      chunks = body.to_ary if kind == :stream && body.respond_to?(:to_ary)

      codec.reply(io, status, headers, kind, path)
      head_sent = true
      write_body(io, codec, body, chunks) if kind == :stream
      codec.finish(io)
      [true, nil]
    rescue *LINK_LOST => e
      @logger.debug('link lost mid-response', **Logger.error_fields(e))
      [false, e]
    rescue StandardError, ScriptError => e
      @logger.error('response failed', path: env['PATH_INFO'], head_sent: head_sent, **Logger.error_fields(e))
      [head_sent ? false : internal_error(io, codec), e]
    end

    def reply_kind(env, status, body)
      return [:empty, nil] if env['REQUEST_METHOD'] == 'HEAD' || BODYLESS_STATUS.call(status)

      if status == 200 && body.respond_to?(:to_path)
        path = File.expand_path(body.to_path)
        return [:file, path] if File.file?(path) && File.readable?(path)
      end

      [:stream, nil]
    end

    def write_body(io, codec, body, chunks)
      if chunks
        chunks.each { |chunk| codec.write(io, chunk) }
      elsif body.respond_to?(:each)
        body.each do |chunk|
          codec.write(io, chunk)
          codec.flush(io)
        end
      else
        body.call(Stream.new(io, codec))
      end
    end

    def internal_error(io, codec)
      codec.reply(io, 500, { 'content-type' => 'text/plain' }, :stream)
      codec.write(io, INTERNAL_ERROR_BODY)
      codec.finish(io)
      true
    rescue *LINK_LOST, Engine::ProtocolError
      false
    end

    def close_input(env)
      input = env['rack.input']
      input.close if input.respond_to?(:close)
    rescue StandardError => e
      @logger.error('rack.input close failed', **Logger.error_fields(e))
    end

    def close_body(body)
      body.close if body.respond_to?(:close)
    rescue StandardError => e
      @logger.error('body close failed', **Logger.error_fields(e))
    end

    def run_after_request(hook)
      hook.call
    rescue StandardError => e
      @logger.error('after-request hook failed', **Logger.error_fields(e))
    end

    def run_finished(callbacks, env, status, headers, error)
      callbacks.reverse_each do |callback|
        callback.call(env, status, headers, error)
      rescue StandardError => e
        @logger.error('rack.response_finished callback failed', **Logger.error_fields(e))
      end
    end
  end
end
