require "http/web_socket"

module LF::HTTP
  class WebSocketConnectionRegistry
    class Connection
      getter websocket : ::HTTP::WebSocket
      getter io : IO

      def initialize(@websocket : ::HTTP::WebSocket, @io : IO)
      end

      def close(code : ::HTTP::WebSocket::CloseCode) : Nil
        @websocket.close(code)
      rescue Exception
      end

      def force_close : Nil
        @io.close unless @io.closed?
      rescue Exception
      end
    end

    @lock = Mutex.new
    @connections = [] of Connection
    @closing = false
    @drained = Channel(Nil).new

    def register(websocket : ::HTTP::WebSocket, io : IO) : Connection?
      connection = Connection.new(websocket, io)
      accepted = @lock.synchronize do
        next false if @closing

        @connections << connection
        true
      end
      return connection if accepted

      connection.close(::HTTP::WebSocket::CloseCode::GoingAway)
      nil
    end

    def unregister(connection : Connection) : Nil
      @lock.synchronize do
        if index = @connections.index(connection)
          @connections.delete_at(index)
        end
        close_drained_signal
      end
    end

    def size : Int32
      @lock.synchronize { @connections.size }
    end

    def closing? : Bool
      @lock.synchronize { @closing }
    end

    def shutdown(timeout_ms : Int32) : Int32
      deadline = Time.instant + timeout_ms.milliseconds
      connections = @lock.synchronize do
        @closing = true
        close_drained_signal
        @connections.dup
      end

      connections.each(&.close(::HTTP::WebSocket::CloseCode::GoingAway))
      return 0 if wait_until_drained(deadline)

      force_close
      wait_until_drained(deadline)
      size
    end

    private def force_close : Nil
      connections = @lock.synchronize { @connections.dup }
      connections.each(&.force_close)
    end

    private def wait_until_drained(deadline : Time::Instant) : Bool
      return true if @drained.closed?

      remaining = deadline - Time.instant
      return false unless remaining.positive?

      select
      when @drained.receive?
        true
      when timeout(remaining)
        false
      end
    end

    private def close_drained_signal : Nil
      @drained.close if @closing && @connections.empty? && !@drained.closed?
    end
  end
end
