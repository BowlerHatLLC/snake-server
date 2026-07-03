package snake._internal.net;

#if (eval && (haxe_ver >= 4.2))
import eval.luv.Buffer;
import eval.luv.Handle;
import eval.luv.Loop;
import eval.luv.Loop.RunMode;
import eval.luv.SockAddr;
import eval.luv.Stream;
import eval.luv.Tcp;
import haxe.Exception;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Eof;
import haxe.io.Input;
import haxe.io.Output;
import sys.net.Host;
import sys.net.Socket as SysSocket;

using eval.luv.Result.ResultTools;

class Socket extends SysSocket {
	private static final POLL_INTERVAL = 0.001;

	private var loop:Loop;
	private var tcp:Tcp;
	private var pending:Array<Socket>;
	private var readBuffer:BytesBuffer;
	private var readOffset = 0;
	private var listening:Bool;
	private var reading:Bool;
	private var closed:Bool;
	private var readClosed:Bool;
	private var timeout:Null<Float> = null;
	private var localAddress:{host:Host, port:Int};
	private var peerAddress:{host:Host, port:Int};

	public function new() {
		super();
		super.close();
		var loop = Loop.defaultLoop();
		initLuv(loop, Tcp.init(loop).resolve());
	}

	private function initLuv(loop:Loop, tcp:Tcp):Void {
		this.loop = loop;
		this.tcp = tcp;
		pending = [];
		readBuffer = new BytesBuffer();
		readOffset = 0;
		listening = false;
		reading = false;
		closed = false;
		readClosed = false;
		input = new LuvSocketInput(this);
		output = new LuvSocketOutput(this);
	}

	private static function fromTcp(loop:Loop, tcp:Tcp):Socket {
		var socket = Type.createEmptyInstance(Socket);
		socket.initLuv(loop, tcp);
		return socket;
	}

	override public function close():Void {
		if (closed) {
			return;
		}
		closed = true;
		Handle.close(tcp, () -> {});
	}

	override public function read():String {
		return input.readAll().toString();
	}

	override public function write(content:String):Void {
		output.writeString(content);
	}

	override public function connect(host:Host, port:Int):Void {
		var done = false;
		var failure:Dynamic = null;
		tcp.connect(sockAddr(host, port), result -> {
			try {
				result.resolve();
			} catch (e:Dynamic) {
				failure = e;
			}
			done = true;
		});
		waitUntil(() -> done, timeout);
		if (failure != null) {
			throw failure;
		}
		localAddress = null;
		peerAddress = {host: host, port: port};
		startRead();
	}

	override public function listen(connections:Int):Void {
		listening = true;
		Stream.listen(tcp, result -> {
			result.resolve();
			var client = Socket.fromTcp(loop, Tcp.init(loop).resolve());
			Stream.accept(tcp, client.tcp).resolve();
			client.localAddress = client.readLocalAddress();
			client.peerAddress = client.readPeerAddress();
			client.startRead();
			pending.push(client);
		}, connections);
	}

	override public function shutdown(read:Bool, write:Bool):Void {
		if (write) {
			Stream.shutdown(tcp, _ -> close());
		}
		if (read) {
			readClosed = true;
		}
	}

	override public function bind(host:Host, port:Int):Void {
		tcp.bind(sockAddr(host, port)).resolve();
		localAddress = readLocalAddress();
	}

	override public function accept():Socket {
		if (pending.length == 0) {
			select([this], null, null, timeout);
		}
		if (pending.length == 0) {
			throw new Exception("No pending connection");
		}
		return pending.shift();
	}

	override public function peer():{host:Host, port:Int} {
		if (peerAddress == null) {
			peerAddress = readPeerAddress();
		}
		return peerAddress;
	}

	override public function host():{host:Host, port:Int} {
		if (localAddress == null) {
			localAddress = readLocalAddress();
		}
		return localAddress;
	}

	override public function setTimeout(timeout:Float):Void {
		this.timeout = timeout;
	}

	override public function waitForRead():Void {
		select([this], null, null, timeout);
	}

	override public function setBlocking(b:Bool):Void {}

	override public function setFastSend(b:Bool):Void {
		tcp.noDelay(b).resolve();
	}

	public static function select(read:Array<sys.net.Socket>, write:Array<sys.net.Socket>, others:Array<sys.net.Socket>,
			?timeout:Float):{read:Array<sys.net.Socket>, write:Array<sys.net.Socket>, others:Array<sys.net.Socket>} {
		var loop = findLoop(read, write, others);
		var deadline = timeout == null || timeout < 0 ? -1.0 : haxe.Timer.stamp() + timeout;
		while (true) {
			var readyRead = ready(read);
			var readyWrite = writable(write);
			var readyOthers:Array<sys.net.Socket> = [];
			var nativeRead = nativeSockets(read);
			var nativeWrite = nativeSockets(write);
			var nativeOthers = nativeSockets(others);
			if (nativeRead.length > 0 || nativeWrite.length > 0 || nativeOthers.length > 0) {
				var selected = sys.net.Socket.select(nativeRead, nativeWrite, nativeOthers, 0);
				readyRead = readyRead.concat(selected.read);
				readyWrite = readyWrite.concat(selected.write);
				readyOthers = selected.others;
			}
			if (readyRead.length > 0 || readyWrite.length > 0 || readyOthers.length > 0) {
				return {read: readyRead, write: readyWrite, others: readyOthers};
			}
			if (timeout == 0 || (deadline >= 0 && haxe.Timer.stamp() >= deadline)) {
				return {read: [], write: [], others: []};
			}
			if (loop != null) {
				loop.run(RunMode.NOWAIT);
			}
			Sys.sleep(POLL_INTERVAL);
		}
	}

	private static function ready(sockets:Array<sys.net.Socket>):Array<sys.net.Socket> {
		if (sockets == null) {
			return [];
		}
		return sockets.filter(socket -> isLuvSocket(socket) && luv(socket).isReadyToRead());
	}

	private static function writable(sockets:Array<sys.net.Socket>):Array<sys.net.Socket> {
		if (sockets == null) {
			return [];
		}
		return sockets.filter(socket -> isLuvSocket(socket) && !luv(socket).listening && !luv(socket).closed);
	}

	private static function nativeSockets(sockets:Array<sys.net.Socket>):Array<sys.net.Socket> {
		if (sockets == null) {
			return [];
		}
		return sockets.filter(socket -> !isLuvSocket(socket));
	}

	private static function findLoop(read:Array<sys.net.Socket>, write:Array<sys.net.Socket>, others:Array<sys.net.Socket>):Loop {
		for (group in [read, write, others]) {
			if (group != null && group.length > 0) {
				for (socket in group) {
					if (isLuvSocket(socket)) {
						return luv(socket).loop;
					}
				}
			}
		}
		return null;
	}

	private static function isLuvSocket(socket:sys.net.Socket):Bool {
		return Std.isOfType(socket, Socket);
	}

	private static function luv(socket:sys.net.Socket):Socket {
		return cast socket;
	}

	private function isReadyToRead():Bool {
		pump();
		return listening ? pending.length > 0 : available() > 0 || readClosed;
	}

	private function startRead():Void {
		if (reading) {
			return;
		}
		reading = true;
		Stream.readStart(tcp, result -> {
			switch (result) {
				case Ok(buffer):
					if (buffer.size() > 0) {
						readBuffer.add(buffer.toBytes());
					}
				case Error(_):
					readClosed = true;
			}
		});
	}

	public function readBytesInto(bytes:Bytes, pos:Int, len:Int):Int {
		waitUntil(() -> available() > 0 || readClosed, timeout);
		var availableBytes = available();
		if (availableBytes == 0) {
			throw new Eof();
		}
		var count = len < availableBytes ? len : availableBytes;
		bytes.blit(pos, readBuffer.getBytes(), readOffset, count);
		readOffset += count;
		return count;
	}

	public function writeBytesFrom(bytes:Bytes, pos:Int, len:Int):Int {
		var chunk = bytes.sub(pos, len);
		var done = false;
		var failure:Dynamic = null;
		var queued = Stream.write(tcp, [chunk], (result, _) -> {
			switch (result) {
				case Error(e):
					failure = e;
				case Ok(_) | null:
			}
			done = true;
		});
		switch (queued) {
			case Error(e):
				throw e;
			case Ok(_) | null:
		}
		waitUntil(() -> done, timeout);
		if (failure != null) {
			throw failure;
		}
		return len;
	}

	private function waitUntil(condition:() -> Bool, timeout:Null<Float>):Void {
		var deadline = timeout == null || timeout < 0 ? -1.0 : haxe.Timer.stamp() + timeout;
		while (!condition()) {
			if (deadline >= 0 && haxe.Timer.stamp() >= deadline) {
				return;
			}
			pump();
			Sys.sleep(POLL_INTERVAL);
		}
	}

	private function pump():Void {
		if (!closed) {
			loop.run(RunMode.NOWAIT);
		}
	}

	private function available():Int {
		return readBuffer.length - readOffset;
	}

	private function readLocalAddress():{host:Host, port:Int} {
		return socketAddress(tcp.getSockName().resolve());
	}

	private function readPeerAddress():{host:Host, port:Int} {
		return socketAddress(tcp.getPeerName().resolve());
	}

	private static function sockAddr(host:Host, port:Int):SockAddr {
		var address:String = host.toString();
		if (address.indexOf(":") == -1) {
			var ipv4:String = address;
			return SockAddr.ipv4(ipv4, port).resolve();
		}
		var ipv6:String = address;
		return SockAddr.ipv6(ipv6, port).resolve();
	}

	private static function socketAddress(address:SockAddr):{host:Host, port:Int} {
		var text = address.toString();
		var colon = text.lastIndexOf(":");
		var host = colon == -1 ? text : text.substr(0, colon);
		var port = address.port == null ? 0 : address.port;
		return {host: new Host(host), port: port};
	}
}

private class LuvSocketInput extends Input {
	private final socket:Socket;

	public function new(socket:Socket) {
		this.socket = socket;
	}

	override public function readBytes(buf:Bytes, pos:Int, len:Int):Int {
		return socket.readBytesInto(buf, pos, len);
	}

	override public function close():Void {
		socket.close();
	}
}

private class LuvSocketOutput extends Output {
	private final socket:Socket;

	public function new(socket:Socket) {
		this.socket = socket;
	}

	override public function writeBytes(buf:Bytes, pos:Int, len:Int):Int {
		return socket.writeBytesFrom(buf, pos, len);
	}

	override public function writeByte(c:Int):Void {
		var bytes = Bytes.alloc(1);
		bytes.set(0, c);
		socket.writeBytesFrom(bytes, 0, 1);
	}

	override public function close():Void {
		socket.close();
	}
}
#else
typedef Socket = sys.net.Socket;
#end
