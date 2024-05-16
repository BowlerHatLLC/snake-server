package snake.socket;

import sys.net.Host;
import sys.net.Socket;
import haxe.Exception;

/**
	Base class for request handler classes.
**/
class BaseRequestHandler {
	private var request:Socket;
	private var clientAddress:{host:Host, port:Int};
	private var server:BaseServer;

	public function new(request:Socket, clientAddress:{host:Host, port:Int}, server:BaseServer) {
		this.request = request;
		this.clientAddress = clientAddress;
		this.server = server;
		setup();
		try {
			handle();
		} catch (e:Exception) {
			finish();
			throw e;
		}
		finish();
	}

	private function setup():Void {}

	private function handle():Void {}

	private function finish():Void {}
}
