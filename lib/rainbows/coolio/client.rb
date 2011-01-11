# -*- encoding: binary -*-
# :enddoc:
class Rainbows::Coolio::Client < Coolio::IO
  include Rainbows::EvCore
  CONN = Rainbows::Coolio::CONN
  KATO = Rainbows::Coolio::KATO
  LOOP = Coolio::Loop.default

  def initialize(io)
    CONN[self] = false
    super(io)
    post_init
    @deferred = nil
  end

  def want_more
    enable unless enabled?
  end

  def quit
    super
    close if nil == @deferred && @_write_buffer.empty?
  end

  # override the Coolio::IO#write method try to write directly to the
  # kernel socket buffers to avoid an extra userspace copy if
  # possible.
  def write(buf)
    if @_write_buffer.empty?
      begin
        case rv = @_io.kgio_trywrite(buf)
        when nil
          return enable_write_watcher
        when :wait_writable
          break # fall through to super(buf)
        when String
          buf = rv # retry, skb could grow or been drained
        end
      rescue => e
        return handle_error(e)
      end while true
    end
    super(buf)
  end

  def on_readable
    buf = @_io.kgio_tryread(16384)
    case buf
    when :wait_readable
    when nil # eof
      close
    else
      on_read buf
    end
  rescue Errno::ECONNRESET
    close
  end

  # allows enabling of write watcher even when read watcher is disabled
  def evloop
    LOOP
  end

  def next!
    attached? or return
    @deferred = nil
    enable_write_watcher # trigger on_write_complete
  end

  def timeout?
    nil == @deferred && @_write_buffer.empty? and close.nil?
  end

  # used for streaming sockets and pipes
  def stream_response_body(body, io, chunk)
    # we only want to attach to the Coolio::Loop belonging to the
    # main thread in Ruby 1.9
    (chunk ? Rainbows::Coolio::ResponseChunkPipe :
             Rainbows::Coolio::ResponsePipe).new(io, self, body).attach(LOOP)
    @deferred = true
  end

  def write_response_path(status, headers, body, alive)
    io = body_to_io(body)
    st = io.stat

    if st.file?
      defer_file(status, headers, body, alive, io, st)
    elsif st.socket? || st.pipe?
      chunk = stream_response_headers(status, headers, alive)
      stream_response_body(body, io, chunk)
    else
      # char or block device... WTF?
      write_response(status, headers, body, alive)
    end
  end

  def ev_write_response(status, headers, body, alive)
    if body.respond_to?(:to_path)
      write_response_path(status, headers, body, alive)
    else
      write_response(status, headers, body, alive)
    end
    return quit unless alive && :close != @state
    @state = :headers
  end

  def coolio_write_async_response(response)
    write_async_response(response)
    @deferred = nil
  end

  def app_call
    KATO.delete(self)
    disable if enabled?
    @env[RACK_INPUT] = @input
    @env[REMOTE_ADDR] = @_io.kgio_addr
    @env[ASYNC_CALLBACK] = method(:coolio_write_async_response)
    status, headers, body = catch(:async) {
      APP.call(@env.merge!(RACK_DEFAULTS))
    }

    (nil == status || -1 == status) ? @deferred = true :
        ev_write_response(status, headers, body, @hp.next?)
  end

  def on_write_complete
    case @deferred
    when true then return # #next! will clear this bit
    when nil # fall through
    else
      begin
        return stream_file_chunk(@deferred)
      rescue EOFError # expected at file EOF
        close_deferred # fall through
      end
    end

    case @state
    when :close
      close if @_write_buffer.empty?
    when :headers
      if @buf.empty?
        unless enabled?
          enable
          KATO[self] = Time.now
        end
      else
        on_read("")
      end
    end
    rescue => e
      handle_error(e)
  end

  def handle_error(e)
    close_deferred
    if msg = Rainbows::Error.response(e)
      @_io.kgio_trywrite(msg) rescue nil
    end
    @_write_buffer.clear
    ensure
      quit
  end

  def close_deferred
    if @deferred
      begin
        @deferred.close if @deferred.respond_to?(:close)
      rescue => e
        Rainbows.server.logger.error("closing #@deferred: #{e}")
      end
      @deferred = nil
    end
  end

  def on_close
    close_deferred
    CONN.delete(self)
    KATO.delete(self)
  end

  if IO.method_defined?(:sendfile_nonblock)
    def defer_file(status, headers, body, alive, io, st)
      if r = sendfile_range(status, headers)
        status, headers, range = r
        write_headers(status, headers, alive)
        range and defer_file_stream(range[0], range[1], io, body)
      else
        write_headers(status, headers, alive)
        defer_file_stream(0, st.size, io, body)
      end
    end

    def stream_file_chunk(sf) # +sf+ is a Rainbows::StreamFile object
      sf.offset += (n = @_io.sendfile_nonblock(sf, sf.offset, sf.count))
      0 == (sf.count -= n) and raise EOFError
      enable_write_watcher
      rescue Errno::EAGAIN
        enable_write_watcher
    end
  else
    def defer_file(status, headers, body, alive, io, st)
      write_headers(status, headers, alive)
      defer_file_stream(0, st.size, io, body)
    end

    def stream_file_chunk(body)
      write(body.to_io.sysread(0x4000))
    end
  end

  def defer_file_stream(offset, count, io, body)
    @deferred = Rainbows::StreamFile.new(offset, count, io, body)
    enable_write_watcher
  end
end