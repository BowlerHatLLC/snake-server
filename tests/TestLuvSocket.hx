import sys.net.Host;
#if (eval && (haxe_ver >= 4.2))
import snake._internal.net.Socket as Socket;
#else
import sys.net.Socket;
#end

class TestLuvSocket {
	public static function main():Void {
		#if sys
		testSocketBehavior();
		testImmediateRebindAfterConnection();
		#else
		assert(true, "non-sys target");
		#end
	}

	private static function testSocketBehavior():Void {
		var server = new Socket();
		var host = new Host("127.0.0.1");
		server.bind(host, 0);
		server.listen(1);
		var port = server.host().port;
		assert(port > 0, "bound port");

		var client = new Socket();
		client.connect(host, port);
		assert(client.input != null, "client input");
		assert(client.output != null, "client output");

		var selected = Socket.select([server], [server], [server], 0.01);
		equals(1, selected.read.length, "server select read");
		equals(0, selected.write.length, "server select write");
		equals(0, selected.others.length, "server select others");

		selected = Socket.select([server], [server], [server], 0.01);
		equals(1, selected.read.length, "server select read repeat");
		equals(0, selected.write.length, "server select write repeat");
		equals(0, selected.others.length, "server select others repeat");

		var accepted = server.accept();
		assert(accepted != null, "accepted socket");
		assert(accepted.input != null, "accepted input");
		assert(accepted.output != null, "accepted output");
		accepted.setFastSend(true);
		server.setBlocking(false);

		selected = Socket.select([server], [server], [server], 0.01);
		equals(0, selected.read.length, "server select read after accept");
		equals(0, selected.write.length, "server select write after accept");
		equals(0, selected.others.length, "server select others after accept");

		accepted.output.writeByte(97);
		accepted.output.writeByte(98);
		accepted.output.writeByte(99);
		accepted.close();

		client.waitForRead();
		selected = Socket.select([client], [client], [client]);
		equals(1, selected.read.length, "client select read");
		equals(1, selected.write.length, "client select write");
		equals(0, selected.others.length, "client select others");
		equals("abc", client.read(), "client read");

		client.close();
		server.close();
	}

	private static function testImmediateRebindAfterConnection():Void {
		var host = new Host("127.0.0.1");
		var first = new Socket();
		first.bind(host, 0);
		first.listen(1);
		var port = first.host().port;

		var client = new Socket();
		client.connect(host, port);
		var accepted = first.accept();
		client.close();
		accepted.close();
		first.close();

		var second = new Socket();
		second.bind(host, port);
		second.listen(1);
		second.close();
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
