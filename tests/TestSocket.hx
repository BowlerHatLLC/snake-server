import snake.http.BaseHTTPRequestHandler;
import snake._internal.net.Socket as InternalSocket;
import snake.socket.BaseRequestHandler;
import snake.socket.BaseServer;
import sys.net.Host;
import sys.net.Socket;

class TestSocket {
	public static function main():Void {
		#if sys
		testInternalSocketIsSysSocket();
		testSocketBehavior();
		testImmediateRebindAfterConnection();
		testRealSocketHandler();
		#else
		assert(true, "non-sys target");
		#end
	}

	private static function testInternalSocketIsSysSocket():Void {
		var socket:Socket = new InternalSocket();
		socket.close();
	}

	private static function testSocketBehavior():Void {
		var server = new InternalSocket();
		var host = new Host("127.0.0.1");
		server.bind(host, 0);
		server.listen(1);
		var port = server.host().port;
		assert(port > 0, "bound port");

		var client = new InternalSocket();
		client.connect(host, port);
		assert(client.input != null, "client input");
		assert(client.output != null, "client output");

		var selected = InternalSocket.select([server], [server], [server], 0.01);
		equals(1, selected.read.length, "server select read");
		equals(0, selected.write.length, "server select write");
		equals(0, selected.others.length, "server select others");

		selected = InternalSocket.select([server], [server], [server], 0.01);
		equals(1, selected.read.length, "server select read repeat");
		equals(0, selected.write.length, "server select write repeat");
		equals(0, selected.others.length, "server select others repeat");

		var accepted = server.accept();
		assert(accepted != null, "accepted socket");
		assert(accepted.input != null, "accepted input");
		assert(accepted.output != null, "accepted output");
		accepted.setFastSend(true);
		server.setBlocking(false);

		selected = InternalSocket.select([server], [server], [server], 0.01);
		equals(0, selected.read.length, "server select read after accept");
		equals(0, selected.write.length, "server select write after accept");
		equals(0, selected.others.length, "server select others after accept");

		accepted.output.writeByte(97);
		accepted.output.writeByte(98);
		accepted.output.writeByte(99);
		accepted.close();

		client.waitForRead();
		selected = InternalSocket.select([client], [client], [client]);
		equals(1, selected.read.length, "client select read");
		equals(1, selected.write.length, "client select write");
		equals(0, selected.others.length, "client select others");
		equals("abc", client.read(), "client read");

		client.close();
		server.close();
	}

	private static function testImmediateRebindAfterConnection():Void {
		var host = new Host("127.0.0.1");
		var first = new InternalSocket();
		first.bind(host, 0);
		first.listen(1);
		var port = first.host().port;

		var client = new InternalSocket();
		client.connect(host, port);
		var accepted = first.accept();
		client.close();
		accepted.close();
		first.close();

		var second = new InternalSocket();
		second.bind(host, port);
		second.listen(1);
		second.close();
	}

	private static function testRealSocketHandler():Void {
		var host = new Host("127.0.0.1");
		var server = new Socket();
		server.bind(host, 0);
		server.listen(1);

		var client = new Socket();
		client.connect(host, server.host().port);
		client.output.writeString("GET / HTTP/1.0\r\n\r\n");
		client.output.flush();

		var accepted = server.accept();
		new RealSocketHTTPHandler(accepted, {host: host, port: 0}, null);

		client.close();
		server.close();
	}

	private static function assert(condition:Bool, label:String):Void {
		if (!condition) {
			throw label;
		}
	}

	private static function equals<T>(expected:T, actual:T, label:String):Void {
		if (actual != expected) {
			throw '$label: expected $expected, got $actual';
		}
	}
}

private class SysSocketHandler extends BaseRequestHandler {
	public function new(request:Socket, clientAddress:{host:Host, port:Int}, server:BaseServer) {
		super(request, clientAddress, server);
	}
}

private class RealSocketHTTPHandler extends BaseHTTPRequestHandler {
	public function new(request:Socket, clientAddress:{host:Host, port:Int}, server:BaseServer) {
		super(request, clientAddress, server);
	}

	override private function logMessage(message:String):Void {}
}
