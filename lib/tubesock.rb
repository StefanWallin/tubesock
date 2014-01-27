require "tubesock/version"
require "tubesock/hijack" if defined?(ActiveSupport)
require "websocket"

# Easily interact with WebSocket connections over Rack.
# TODO: Example with pure Rack
class Tubesock
  HijackNotAvailable = Class.new RuntimeError

  def initialize(socket, version)
    @socket     = socket
    @version    = version
    @num_valid_timeouts = 5

    @open_handlers    = []
    @message_handlers = []
    @close_handlers   = []

    @ping_frames = {}
  end

  def self.hijack(env)
    if env['rack.hijack']
      env['rack.hijack'].call
      socket = env['rack.hijack_io']

      handshake = WebSocket::Handshake::Server.new
      handshake.from_rack env

      socket.write handshake.to_s

      self.new socket, handshake.version
    else
      raise Tubesock::HijackNotAvailable
    end
  end

  def setTimeouts(new_timeout)
    @num_valid_timeouts = new_timeout if new_timeout.is_a? Integer
  end

  def send_data data, type = :text
    frame = WebSocket::Frame::Outgoing::Server.new(
      version: @version,
      data: data,
      type: type
    )
    @socket.write frame.to_s
  rescue IOError
    close('Sending: IOError')
  rescue Errno::EPIPE
    close('Sending: Errno::EPIPE')
  end

  def onopen(&block)
    @open_handlers << block
  end

  def onmessage(&block)
    @message_handlers << block
  end

  def onclose(&block)
    @close_handlers << block
  end

  def listen
    keepalive
    Thread.new do
      Thread.current.abort_on_exception = true
      @open_handlers.each(&:call)
      each_frame do |data|
        @message_handlers.each{ |h| h.call(data) }
      end
      close("listened enough")
    end
  end

  def close(cause)
    cause = "unknown" if cause.nil?
    @close_handlers.each{ |h| h.call(cause) }
    @socket.close unless @socket.closed?
  end

  def closed?
    @socket.closed?
  end

  def keepalive
    keepaliveThread = Thread.new do
      Thread.current.abort_on_exception = true
      loop do
        sleep 5
        stamp = Time.now.to_i.to_s
        send_data stamp, :ping
        @ping_frames[stamp.to_sym] = 1
        if @ping_frames.length > @num_valid_timeouts
          close("Keepalive: Timed out")
        end
      end
    end

    onclose do
      keepaliveThread.kill unless keepaliveThread.nil?
    end
  end

  private
  def each_frame
    framebuffer = WebSocket::Frame::Incoming::Server.new(version: @version)
    while IO.select([@socket])
      data, addrinfo = @socket.recvfrom(2000)
      break if data.empty?
      framebuffer << data
      while frame = framebuffer.next
        case frame.type
        when :pong
          @ping_frames.delete(frame.data.to_sym)
        when :close
          return
        when :text, :binary
          yield frame.data
        end
      end
    end
  rescue Errno::ETIMEDOUT
    close('Recieve: Errno::ETIMEDOUT')
  rescue Errno::ECONNRESET
    close('Recieve: Errno::ECONNRESET')
  rescue Errno::EHOSTUNREACH
    close('Recieve: Errno::EHOSTUNREACH')
  end
end
