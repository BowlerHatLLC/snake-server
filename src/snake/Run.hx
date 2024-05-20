package snake;

import hxargs.Args;
import snake.http.BaseHTTPRequestHandler;
import snake.http.HTTPServer;
import snake.http.SimpleHTTPRequestHandler;
import snake.socket.BaseRequestHandler;
import sys.net.Host;
import sys.net.Socket;

/**
	Run `haxelib run snake-server` to start a local HTTP server that serves
	static files from the current directory.
**/
class Run {
	private static final DEFAULT_PROTOCOL = "HTTP/1.0";
	private static final DEFAULT_ADDRESS = "127.0.0.1";
	private static final DEFAULT_PORT = 8000;

	/**
		Entry point.
	**/
	public static function main():Void {
		var args = Sys.args();
		if (Sys.getEnv("HAXELIB_RUN") == "1" && Sys.getEnv("HAXELIB_RUN_NAME") == "snake-server") {
			var cwd = args.pop();
			Sys.setCwd(cwd);
		}

		var address:String = DEFAULT_ADDRESS;
		var port:Int = DEFAULT_PORT;
		var directory:String = null;
		var protocol:String = DEFAULT_PROTOCOL;
		var corsEnabled:Bool = false;
		var cacheEnabled:Bool = true;
		var argHandler:ArgHandler = null;
		argHandler = Args.generate([
			@doc('bind to this address (default: 127.0.01')
			["--bind"] => function(host:String) {
				address = host;
			},
			@doc('serve this directory (default: current directory)')
			["--directory"] => function(path:String) {
				directory = path;
			},
			@doc('conform to this HTTP version (default: HTTP/1.0)')
			["--protocol"] => function(version:String) {
				protocol = version;
			},
			@doc('bind to this port (default: 8000)')
			["--port"] => function(tcpPort:Int) {
				port = tcpPort;
			}, @doc('enable CORS header')
			["--cors"] => function() {
				corsEnabled = true;
			}, @doc('disable caching')
			["--no-cache"] => function() {
				cacheEnabled = false;
			},
			@doc('print this help message')
			["--help"] => function() {
				Sys.println("Usage: haxelib run snake-server [options]");
				Sys.println("Options:");
				Sys.println(argHandler.getDoc());
				Sys.exit(0);
			},
		]);
		argHandler.parse(args);
		BaseHTTPRequestHandler.protocolVersion = protocol;
		RunHTTPRequestHandler.corsEnabled = corsEnabled;
		RunHTTPRequestHandler.cacheEnabled = cacheEnabled;
		var httpServer = new RunHTTPServer(new Host(address), port, RunHTTPRequestHandler, true, directory);
		httpServer.threading = true;
		httpServer.serveForever();
	}
}

private class RunHTTPRequestHandler extends SimpleHTTPRequestHandler {
	public static var corsEnabled = false;
	public static var cacheEnabled = true;

	override private function setup():Void {
		super.setup();
		serverVersion = 'SnakeServer/${BaseHTTPRequestHandler.getLibraryVersion()}';
	}

	override public function endHeaders() {
		if (corsEnabled) {
			sendHeader('Access-Control-Allow-Origin', '*');
		}
		if (!cacheEnabled) {
			sendHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
		}
		super.endHeaders();
	}
}

private class RunHTTPServer extends HTTPServer {
	private var directory:String;

	public function new(serverHost:Host, serverPort:Int, requestHandlerClass:Class<BaseRequestHandler>, bindAndActivate:Bool = true, ?directory:String) {
		this.directory = directory;
		super(serverHost, serverPort, requestHandlerClass, bindAndActivate);
		Sys.print('Serving HTTP on ${serverAddress.host} port ${serverAddress.port} (http://${serverAddress.host}:${serverAddress.port})\n');
	}

	override private function finishRequest(request:Socket, clientAddress:{host:Host, port:Int}):Void {
		Type.createInstance(requestHandlerClass, [request, clientAddress, this, directory]);
	}
}
