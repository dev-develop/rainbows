# -*- encoding: binary -*-

# Rack response middleware wrapping any IO-like object with an
# OS-level file descriptor associated with it.  May also be used to
# create responses from integer file descriptors or existing +IO+
# objects.  This may be used in conjunction with the #to_path method
# on servers that support it to pass arbitrary file descriptors into
# the HTTP response without additional open(2) syscalls

class Rainbows::DevFdResponse < Struct.new(:app)

  # :stopdoc:
  FD_MAP = Rainbows::FD_MAP
  include Rack::Utils

  # Rack middleware entry point, we'll just pass through responses
  # unless they respond to +to_io+ or +to_path+
  def call(env)
    status, headers, body = response = app.call(env)

    # totally uninteresting to us if there's no body
    if STATUS_WITH_NO_ENTITY_BODY.include?(status.to_i) ||
       File === body ||
       (body.respond_to?(:to_path) && File.file?(body.to_path))
      return response
    end

    io = body.to_io if body.respond_to?(:to_io)
    io ||= File.open(body.to_path) if body.respond_to?(:to_path)
    return response if io.nil?

    headers = Rack::Utils::HeaderHash.new(headers) unless Hash === headers
    st = io.stat
    fileno = io.fileno
    FD_MAP[fileno] = io
    if st.file?
      headers['Content-Length'.freeze] ||= st.size.to_s
      headers.delete('Transfer-Encoding'.freeze)
    elsif st.pipe? || st.socket? # epoll-able things
      unless headers.include?('Content-Length'.freeze)
        if env['rainbows.autochunk']
          case env['HTTP_VERSION']
          when "HTTP/1.0", nil
          else
            headers['Transfer-Encoding'.freeze] = 'chunked'
          end
        else
          env['rainbows.autochunk'] = false
        end
      end

      # we need to make sure our pipe output is Fiber-compatible
      case env['rainbows.model']
      when :FiberSpawn, :FiberPool, :RevFiberSpawn, :CoolioFiberSpawn
        io.respond_to?(:kgio_wait_readable) or
          io = Rainbows::Fiber::IO.new(io)
      when :Revactor
        io = Rainbows::Revactor::Proxy.new(io)
      end
    else # unlikely, char/block device file, directory, ...
      return response
    end
    [ status, headers, Body.new(io, "/dev/fd/#{fileno}", body) ]
  end

  class Body < Struct.new(:to_io, :to_path, :orig_body) # :nodoc:
    # called by the webserver or other middlewares if they can't
    # handle #to_path
    def each
      to_io.each { |x| yield x }
    end

    # remain Rack::Lint-compatible for people with wonky systems :P
    unless File.directory?("/dev/fd")
      alias to_path_orig to_path
      undef_method :to_path
    end

    # called by the web server after #each
    def close
      to_io.close unless to_io.closed?
      orig_body.close if orig_body.respond_to?(:close) # may not be an IO
    rescue IOError # could've been IO::new()'ed and closed
    end
  end
  #:startdoc:
end # class
