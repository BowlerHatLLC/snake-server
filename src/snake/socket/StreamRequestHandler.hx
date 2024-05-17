package snake.socket;

import sys.net.Host;
import haxe.Exception;
import haxe.io.Output;
import sys.net.Socket;
import haxe.io.Input;

/**
	Define self.rfile and self.wfile for stream sockets.
**/
class StreamRequestHandler extends BaseRequestHandler {
	private var connection:Socket;
	private var rfile:Input;
	private var wfile:Output;

	/**
		Constructor.
	**/
	public function new(request:Socket, clientAddress:{host:Host, port:Int}, server:BaseServer) {
		super(request, clientAddress, server);
	}

	override private function setup():Void {
		connection = cast(request, Socket);
		rfile = connection.input;
		wfile = connection.output;
	}

	override private function finish():Void {
		try {
			wfile.flush();
		} catch (e:Exception) {
			// A final socket error may have occurred here, such as
			// the local error ECONNABORTED.
		}
		connection.close();
	}
}
