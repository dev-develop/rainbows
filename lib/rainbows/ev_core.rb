# -*- encoding: binary -*-
# :enddoc:
# base module for evented models like Rev and EventMachine
module Rainbows::EvCore
  include Rainbows::Const
  include Rainbows::Response
  NULL_IO = Unicorn::HttpRequest::NULL_IO
  HttpParser = Rainbows::HttpParser
  autoload :CapInput, 'rainbows/ev_core/cap_input'
  RBUF = ""
  Rainbows.config!(self, :client_header_buffer_size)

  # Apps may return this Rack response: AsyncResponse = [ -1, {}, [] ]

  def write_async_response(response)
    status, headers, body = response
    if alive = @hp.next?
      # we can't do HTTP keepalive without Content-Length or
      # "Transfer-Encoding: chunked", and the async.callback stuff
      # isn't Rack::Lint-compatible, so we have to enforce it here.
      headers = Rack::Utils::HeaderHash.new(headers) unless Hash === headers
      alive = headers.include?('Content-Length'.freeze) ||
              !!(%r{\Achunked\z}i =~ headers['Transfer-Encoding'.freeze])
    end
    @deferred = nil
    ev_write_response(status, headers, body, alive)
  end

  def post_init
    @hp = HttpParser.new
    @env = @hp.env
    @buf = @hp.buf
    @state = :headers # [ :body [ :trailers ] ] :app_call :close
  end

  # graceful exit, like SIGQUIT
  def quit
    @state = :close
  end

  def want_more
  end

  def handle_error(e)
    msg = Rainbows::Error.response(e) and write(msg)
    ensure
      quit
  end

  # returns whether to enable response chunking for autochunk models
  # returns nil if request was hijacked in response stage
  def stream_response_headers(status, headers, alive, body)
    headers = Rack::Utils::HeaderHash.new(headers) unless Hash === headers
    if headers.include?('Content-Length'.freeze)
      write_headers(status, headers, alive, body) or return
      return false
    end

    case @env['HTTP_VERSION']
    when "HTTP/1.0" # disable HTTP/1.0 keepalive to stream
      write_headers(status, headers, false, body) or return
      @hp.clear
      false
    when nil # "HTTP/0.9"
      false
    else
      rv = !!(headers['Transfer-Encoding'] =~ %r{\Achunked\z}i)
      rv = false unless @env["rainbows.autochunk"]
      write_headers(status, headers, alive, body) or return
      rv
    end
  end

  def prepare_request_body
    # since we don't do streaming input, we have no choice but
    # to take over 100-continue handling from the Rack application
    if @env['HTTP_EXPECT'] =~ /\A100-continue\z/i
      write("HTTP/1.1 100 Continue\r\n\r\n".freeze)
      @env.delete('HTTP_EXPECT'.freeze)
    end
    @input = mkinput
    @hp.filter_body(@buf2 = "", @buf)
    @input << @buf2
    on_read(''.freeze)
  end

  # TeeInput doesn't map too well to this right now...
  def on_read(data)
    case @state
    when :headers
      @hp.add_parse(data) or return want_more
      @state = :body
      if 0 == @hp.content_length
        app_call NULL_IO # common case
      else # nil or len > 0
        prepare_request_body
      end
    when :body
      if @hp.body_eof?
        if @hp.content_length
          @input.rewind
          app_call @input
        else
          @state = :trailers
          on_read(data)
        end
      elsif data.size > 0
        @hp.filter_body(@buf2, @buf << data)
        @input << @buf2
        on_read(''.freeze)
      else
        want_more
      end
    when :trailers
      if @hp.add_parse(data)
        @input.rewind
        app_call @input
      else
        want_more
      end
    end
    rescue => e
      handle_error(e)
  end

  def err_413(msg)
    write("HTTP/1.1 413 Request Entity Too Large\r\n\r\n".freeze)
    quit
    # zip back up the stack
    raise IOError, msg, []
  end

  TmpIO = Unicorn::TmpIO
  CBB = Unicorn::TeeInput.client_body_buffer_size

  def io_for(bytes)
    bytes <= CBB ? StringIO.new("") : TmpIO.new
  end

  def mkinput
    max = Rainbows.server.client_max_body_size
    len = @hp.content_length
    if len
      if max && (len > max)
        err_413("Content-Length too big: #{len} > #{max}")
      end
      io_for(len)
    else
      max ? CapInput.new(io_for(max), self, max) : TmpIO.new
    end
  end
end
