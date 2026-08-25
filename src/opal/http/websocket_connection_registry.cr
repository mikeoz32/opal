require "http/web_socket"
require "sync/mutex"

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

    @lock = Sync::Mutex.new
    @connections = [] of Connection
    @closing = false

    def register(websocket : ::HTTP::WebSocket, io : IO) : Connection
      connection = Connection.new(websocket, io)
      close_immediately = @lock.synchronize do
        @connections << connection
        @closing
      end
      connection.close(::HTTP::WebSocket::CloseCode::GoingAway) if close_immediately
      connection
    end

    def unregister(connection : Connection) : Nil
      @lock.synchronize do
        if index = @connections.index(connection)
          @connections.delete_at(index)
        end
      end
    end

    def size : Int32
      @lock.synchronize { @connections.size }
    end

    def shutdown(timeout_ms : Int32) : Nil
      deadline = Time.instant + timeout_ms.milliseconds
      connections = @lock.synchronize do
        @closing = true
        @connections.dup
      end

      connections.each(&.close(::HTTP::WebSocket::CloseCode::GoingAway))
      return if wait_until_drained(deadline)

      force_close
      wait_until_drained(deadline)
    end

    private def force_close : Nil
      connections = @lock.synchronize { @connections.dup }
      connections.each(&.force_close)
    end

    private def wait_until_drained(deadline : Time::Instant) : Bool
      loop do
        return true if size == 0
        return false if Time.instant >= deadline

        sleep 1.millisecond
      end
    end
  end
end
