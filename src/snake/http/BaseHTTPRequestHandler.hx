package snake.http;

import haxe.Exception;
import haxe.Json;
import haxe.io.Input;
import haxe.io.Path;
import snake.socket.BaseServer;
import snake.socket.StreamRequestHandler;
import sys.io.File;
import sys.net.Host;
import sys.net.Socket;

class BaseHTTPRequestHandler extends StreamRequestHandler {
	private static macro function getLibraryVersion():haxe.macro.Expr {
		var posInfos = haxe.macro.Context.getPosInfos(haxe.macro.Context.currentPos());
		var directory = Path.directory(posInfos.file);
		var haxelibPath = Path.join([directory, "..", "..", "..", "haxelib.json"]);
		var json:Dynamic = Json.parse(File.getContent(haxelibPath));
		return macro $v{json.version};
	}

	private static final DEFAULT_ERROR_CONTENT_TYPE = "text/html;charset=utf-8";

	/**

		The default request version.  This only affects responses up until
		the point where the request line is parsed, so it mainly decides what
		the client gets back when sending a malformed request line.
		Most web servers default to HTTP 0.9, i.e. don't send a status line.
	**/
	private static final DEFAULT_REQUEST_VERSION = "HTTP/0.9";

	private static final EREG_TRAILING_CR_AND_LEFT = ~/^(.*)[\r\n]+$/;
	private static final EREG_LEADING_SLASHES = ~/^\/\/+(.*)$/;
	private static final MAX_HEADERS = 100;
	private static final MAX_LINE = 65536;

	/**
		The server software version.  You may want to override this.
		The format is multiple whitespace-separated strings,
		where each string is of the form name[\/version].
	**/
	private var serverVersion:String = 'BaseHTTP/${getLibraryVersion()}';

	/**
		The Haxe system version.
	**/
	private var sysVersion:String = 'Haxe/${haxe.macro.Compiler.getDefine("haxe")}';

	private var commandHandlers:Map<String, () -> Void> = [];
	private var command:String;
	private var path:String;
	private var closeConnection:Bool = false;
	private var headersBuffer:String;
	private var headers:Map<String, String>;
	private var rawRequestLine:String;
	private var requestLine:String;
	private var requestVersion:String;
	private var errorContentType:String = DEFAULT_ERROR_CONTENT_TYPE;

	/**
		The version of the HTTP protocol we support.
		set this to HTTP/1.1 to enable automatic keepalive
	**/
	public static var protocolVersion:String = "HTTP/1.0";

	public function new(request:Socket, clientAddress:{host:Host, port:Int}, server:BaseServer) {
		super(request, clientAddress, server);
	}

	/**
		Parse a request (internal).

		The request should be stored in rawRequestLine; the results
		are in command, path, requestVersion and headers.

		@return true for success, false for failure; on failure, any relevant
		error response has already been sent back.
	**/
	private function parseRequest():Bool {
		command = null;
		var version = DEFAULT_REQUEST_VERSION;
		requestVersion = DEFAULT_REQUEST_VERSION;
		closeConnection = true;
		// TODO: iso-8859-1
		requestLine = rawRequestLine;
		if (EREG_TRAILING_CR_AND_LEFT.match(requestLine)) {
			requestLine = EREG_TRAILING_CR_AND_LEFT.matched(1);
		}

		var baseVersionNumber:String = null;
		// Enough to determine protocol version
		var words = ~/\s/g.split(requestLine);
		if (words.length >= 3) {
			version = words[words.length - 1];
			var parsedVersionNumber:Array<Int> = null;
			try {
				if (!StringTools.startsWith(version, 'HTTP/')) {
					throw new Exception("http version must start with HTTP/");
				}
				baseVersionNumber = version.split("/")[1];
				var versionNumber = baseVersionNumber.split(".");
				// RFC 2145 section 3.1 says there can be only one "." and
				//   - major and minor numbers MUST be treated as
				//      separate integers;
				//   - HTTP/2.4 is a lower version than HTTP/2.13, which in
				//      turn is lower than HTTP/12.3;
				//   - Leading zeros MUST be ignored by recipients.
				if (versionNumber.length != 2) {
					throw new Exception("too many . separators in http version");
				}
				if (Lambda.exists(versionNumber, component -> !~/^\d+$/.match(component))) {
					throw new Exception("non digit in http version");
				}
				if (Lambda.exists(versionNumber, component -> component.length > 10)) {
					throw new Exception("unreasonable length http version");
				}
				parsedVersionNumber = [Std.parseInt(versionNumber[0]), Std.parseInt(versionNumber[1])];
			} catch (e:Exception) {
				sendError(HTTPStatus.BAD_REQUEST, 'Bad request version (${version})');
				return false;
			}
			if ((parsedVersionNumber[0] > 1 || (parsedVersionNumber[0] == 1 && parsedVersionNumber[1] >= 1))
				&& protocolVersion >= "HTTP/1.1") {
				closeConnection = false;
			}
			if (parsedVersionNumber[0] >= 2) {
				sendError(HTTPStatus.HTTP_VERSION_NOT_SUPPORTED, 'Invalid HTTP version (%s)" (${baseVersionNumber})');
				return false;
			}
			requestVersion = version;
		}

		if (!(2 <= words.length && words.length <= 3)) {
			sendError(HTTPStatus.BAD_REQUEST, 'Bad request syntax (${requestLine})');
			return false;
		}

		var parsedCommand = words[0];
		var parsedPath = words[1];

		if (words.length == 2) {
			closeConnection = true;
			if (parsedCommand != 'GET') {
				sendError(HTTPStatus.BAD_REQUEST, 'Bad HTTP/0.9 request type (${parsedCommand})');
				return false;
			}
		}

		command = parsedCommand;
		path = parsedPath;

		// gh-87389: The purpose of replacing '//' with '/' is to protect
		// against open redirect attacks possibly triggered if the path starts
		// with '//' because http clients treat //path as an absolute URI
		// without scheme (similar to http://path) rather than a path.
		if (EREG_LEADING_SLASHES.match(path)) {
			path = '/' + EREG_LEADING_SLASHES.matched(1);
		}

		// Examine the headers and look for a Connection directive.
		try {
			headers = HeaderParser.parseHeaders(rfile);
		} catch (e:Exception) {
			sendError(HTTPStatus.REQUEST_HEADER_FIELDS_TOO_LARGE, "Line too long or too many headers");
		}

		var connType = headers.get('Connection');
		if (connType == null) {
			connType = "";
		}
		if (connType.toLowerCase() == "close") {
			closeConnection = true;
		} else if (connType.toLowerCase() == 'keep-alive' && protocolVersion >= "HTTP/1.1") {
			closeConnection = false;
		}

		// Examine the headers and look for an Expect directive
		var expect = headers.get('Expect');
		if (expect == null) {
			expect = "";
		}
		if (expect.toLowerCase() == "100-continue" && protocolVersion >= "HTTP/1.1" && requestVersion >= "HTTP/1.1") {
			if (!handleExpect100()) {
				return false;
			}
		}

		return true;
	}

	/**
		Decide what to do with an "Expect: 100-continue" header.

		If the client is expecting a 100 Continue response, we must
		respond with either a 100 Continue or a final response before
		waiting for the request body. The default is to always respond
		with a 100 Continue. You can behave differently (for example,
		reject unauthorized requests) by overriding this method.

		@return This method should either return true (possibly after sending
		a 100 Continue response) or send an error response and return
		false.
	**/
	private function handleExpect100():Bool {
		sendResponseOnly(HTTPStatus.CONTINUE);
		endHeaders();
		return true;
	}

	/**
		Handle a single HTTP request.

		You normally don't need to override this method; see the class
		doc string for information on how to handle specific HTTP
		commands such as GET and POST.
	**/
	private function handleOneRequest():Void {
		try {
			rawRequestLine = "";
			var lineLength = 0;
			var char:String = null;
			// can't seem to rely on Haxe socket input readLine() because it
			// sometimes blocks until the connection is dropped
			while (true) {
				char = rfile.readString(1);
				if (char == "\r") {
					continue;
				} else if (char == "\n") {
					break;
				} else {
					rawRequestLine += char;
					if (lineLength > MAX_LINE) {
						break;
					}
				}
			}
			if (lineLength > MAX_LINE) {
				requestLine = '';
				requestVersion = '';
				command = '';
				sendError(HTTPStatus.REQUEST_URI_TOO_LONG);
				return;
			}
			if (rawRequestLine.length == 0) {
				closeConnection = true;
				return;
			}
			if (!parseRequest()) {
				// An error code has been sent, just exit
				return;
			}
			if (commandHandlers.exists(command)) {
				commandHandlers.get(command)();
			} else {
				sendError(HTTPStatus.NOT_IMPLEMENTED, 'Unsupported method ($command)');
				return;
			}
			// actually send the response if not already done.
			wfile.flush();
		} catch (e:Exception) {
			logError("Unknown exception: " + e.toString());
			closeConnection = true;
			return;
		}
	}

	/**
		Handle multiple requests if necessary.
	**/
	override private function handle():Void {
		closeConnection = true;
		handleOneRequest();
		while (!closeConnection) {
			handleOneRequest();
		}
	}

	/**
		Send and log an error reply.

		@param code an HTTP error code
					3 digits
		@param message a simple optional 1 line reason phrase.
				*( HTAB / SP / VCHAR / %x80-FF )
				defaults to short entry matching the response code

		This sends an error response (so it must be called before any
		output has been generated), logs the error, and finally sends
		a piece of HTML explaining the error to the user.
	**/
	private function sendError(status:HTTPStatus, ?message:String):Void {
		if (message == null) {
			message = status.message;
		}
		logError('code ${status.code} message ${message}');
		sendResponse(status, message);
		sendHeader('Connection', 'close');

		// Message body is omitted for cases described in:
		//  - RFC7230: 3.3. 1xx, 204(No Content), 304(Not Modified)
		//  - RFC7231: 6.3.6. 205(Reset Content)
		var body:String = null;
		if (status.code >= 200 && ![HTTPStatus.NO_CONTENT, HTTPStatus.RESET_CONTENT, HTTPStatus.NOT_MODIFIED].contains(status)) {
			// HTML encode to prevent Cross Site Scripting attacks
			// (see bug #1100201)

			var contentMessage = StringTools.htmlEscape(status.message);
			body = '<!DOCTYPE HTML>
<html lang="en">
	<head>
		<meta charset="utf-8">
		<title>Error response</title>
	</head>
	<body>
		<h1>Error response</h1>
		<p>Error code: ${status.code}</p>
		<p>Message: ${contentMessage}.</p>
	</body>
</html>';
			sendHeader("Content-Type", errorContentType);
			sendHeader('Content-Length', Std.string(body.length));
		}

		if (command != 'HEAD' && body != null) {
			wfile.writeString(body);
		}
	}

	/**
		Add the response header to the headers buffer and log the
		response code.

		Also send two standard headers with the server software
		version and the current date.
	**/
	private function sendResponse(status:HTTPStatus, ?message:String):Void {
		logRequest(status);
		sendResponseOnly(status, message);
		sendHeader('Server', versionString());
		sendHeader('Date', dateTimeString());
	}

	/**
		Send the response header only.
	**/
	private function sendResponseOnly(status:HTTPStatus, ?message:String):Void {
		if (requestVersion != 'HTTP/0.9') {
			if (message == null) {
				message = status.message;
			}
			if (headersBuffer == null) {
				headersBuffer = "";
			}
			headersBuffer += '${protocolVersion} ${status.code} ${message}\r\n';
		}
	}

	/**
		Send a MIME header to the headers buffer.
	**/
	private function sendHeader(keyword:String, value:String):Void {
		if (requestVersion != 'HTTP/0.9') {
			if (headersBuffer == null) {
				headersBuffer = "";
			}
			headersBuffer += '${keyword}: ${value}\r\n';
		}

		if (keyword.toLowerCase() == 'connection') {
			if (value.toLowerCase() == 'close') {
				closeConnection = true;
			} else if (value.toLowerCase() == 'keep-alive') {
				closeConnection = false;
			}
		}
	}

	/**
		Send the blank line ending the MIME headers.
	**/
	private function endHeaders():Void {
		if (requestVersion != "HTTP/0.9") {
			headersBuffer += "\r\n";
			flushHeaders();
		}
	}

	private function flushHeaders():Void {
		if (headersBuffer != null && headersBuffer.length > 0) {
			wfile.writeString(headersBuffer);
			headersBuffer = "";
		}
	}

	/**
		Log an accepted request.

		This is called by sendResponse().
	**/
	private function logRequest(code:Any = "-", size:Any = "-"):Void {
		if ((code is HTTPStatus)) {
			code = (code : HTTPStatus).code;
		}
		logMessage('"${requestLine}" ${code} ${size}');
	}

	/**
		Log an error.

		This is called when a request cannot be fulfilled.  By
		default it passes the message on to logMessage().

		Arguments are the same as for logMessage().

		XXX This should go to the separate error log.
	**/
	private function logError(message:String):Void {
		logMessage(message);
	}

	/**
		Log an arbitrary message.

		This is used by all other logging functions.  Override
		it if you have specific logging wishes.

		The client ip and current date/time are prefixed to
		every message.

		Unicode control characters are replaced with escaped hex
		before writing the output to stderr.
	**/
	private function logMessage(message:String):Void {
		// TODO: handle unicode control characters
		Sys.print('${addressString()} - - [${dateTimeStringForLog()}] ${message}\n');
	}

	/**
		Return the server software version string.
	**/
	private function versionString():String {
		return '${serverVersion} ${sysVersion}';
	}

	/**
		Return the current date and time formatted for a message header.
	**/
	private function dateTimeString(?timestamp:Date):String {
		if (timestamp == null) {
			timestamp = Date.now();
		}
		// TODO: rfc 2822 format
		return timestamp.toString();
	}

	/**
		Return the current time formatted for logging.
	**/
	private function dateTimeStringForLog():String {
		return Date.now().toString();
	}

	/**
		Return the client address.
	**/
	private function addressString():String {
		return '${clientAddress.host.toString()}';
	}
}

class HTTPStatus {
	// informational
	public static final CONTINUE = new HTTPStatus(100, 'Continue');
	public static final SWITCHING_PROTOCOLS = new HTTPStatus(101, 'Switching Protocols');
	public static final PROCESSING = new HTTPStatus(102, 'Processing');
	public static final EARLY_HINTS = new HTTPStatus(103, 'Early Hints');

	// success
	public static final OK = new HTTPStatus(200, 'OK');
	public static final CREATED = new HTTPStatus(201, 'Created');
	public static final ACCEPTED = new HTTPStatus(202, 'Accepted');
	public static final NON_AUTHORITATIVE_INFORMATION = new HTTPStatus(203, 'Non-Authoritative Information');
	public static final NO_CONTENT = new HTTPStatus(204, 'No Content');
	public static final RESET_CONTENT = new HTTPStatus(205, 'Reset Content');
	public static final PARTIAL_CONTENT = new HTTPStatus(206, 'Partial Content');
	public static final MULTI_STATUS = new HTTPStatus(207, 'Multi-Status');
	public static final ALREADY_REPORTED = new HTTPStatus(208, 'Already Reported');
	public static final IM_USED = new HTTPStatus(226, 'IM Used');

	// redirection
	public static final MULTIPLE_CHOICES = new HTTPStatus(300, 'Multiple Choices');
	public static final MOVED_PERMANENTLY = new HTTPStatus(301, 'Moved Permanently');
	public static final FOUND = new HTTPStatus(302, 'Found');
	public static final SEE_OTHER = new HTTPStatus(303, 'See Other');
	public static final NOT_MODIFIED = new HTTPStatus(304, 'Not Modified');
	public static final USE_PROXY = new HTTPStatus(305, 'Use Proxy');
	public static final TEMPORARY_REDIRECT = new HTTPStatus(307, 'Temporary Redirect');
	public static final PERMANENT_REDIRECT = new HTTPStatus(308, 'Permanent Redirect');

	// client error
	public static final BAD_REQUEST = new HTTPStatus(400, 'Bad Request');
	public static final UNAUTHORIZED = new HTTPStatus(401, 'Unauthorized');
	public static final PAYMENT_REQUIRED = new HTTPStatus(402, 'Payment Required');
	public static final FORBIDDEN = new HTTPStatus(403, 'Forbidden');
	public static final NOT_FOUND = new HTTPStatus(404, 'Not Found');
	public static final METHOD_NOT_ALLOWED = new HTTPStatus(405, 'Method Not Allowed');
	public static final NOT_ACCEPTABLE = new HTTPStatus(406, 'Not Acceptable');
	public static final PROXY_AUTHENTICATION_REQUIRED = new HTTPStatus(407, 'Proxy Authentication Required');
	public static final REQUEST_TIMEOUT = new HTTPStatus(408, 'Request Timeout');
	public static final CONFLICT = new HTTPStatus(409, 'Conflict');
	public static final GONE = new HTTPStatus(410, 'Gone');

	public static final LENGTH_REQUIRED = new HTTPStatus(411, 'Length Required');
	public static final PRECONDITION_FAILED = new HTTPStatus(412, 'Precondition Failed');
	public static final REQUEST_ENTITY_TOO_LARGE = new HTTPStatus(413, 'Request Entity Too Large');
	public static final REQUEST_URI_TOO_LONG = new HTTPStatus(414, 'Request-URI Too Long');
	public static final UNSUPPORTED_MEDIA_TYPE = new HTTPStatus(415, 'Unsupported Media Type');
	public static final REQUESTED_RANGE_NOT_SATISFIABLE = new HTTPStatus(416, 'Requested Range Not Satisfiable');
	public static final EXPECTATION_FAILED = new HTTPStatus(417, 'Expectation Failed');
	public static final IM_A_TEAPOT = new HTTPStatus(418, 'I\'m a Teapot');
	public static final MISDIRECTED_REQUEST = new HTTPStatus(421, 'Misdirected Request');
	public static final UNPROCESSABLE_ENTITY = new HTTPStatus(422, 'Unprocessable Entity');
	public static final LOCKED = new HTTPStatus(423, 'Locked');
	public static final FAILED_DEPENDENCY = new HTTPStatus(424, 'Failed Dependency');
	public static final TOO_EARLY = new HTTPStatus(425, 'Too Early');
	public static final UPGRADE_REQUIRED = new HTTPStatus(426, 'Upgrade Required');
	public static final PRECONDITION_REQUIRED = new HTTPStatus(428, 'Precondition Required');
	public static final TOO_MANY_REQUESTS = new HTTPStatus(429, 'Too Many Requests');
	public static final REQUEST_HEADER_FIELDS_TOO_LARGE = new HTTPStatus(431, 'Request Header Fields Too Large');
	public static final UNAVAILABLE_FOR_LEGAL_REASONS = new HTTPStatus(451, 'Unavailable For Legal Reasons');

	// server errors
	public static final INTERNAL_SERVER_ERROR = new HTTPStatus(500, 'Internal Server Error');
	public static final NOT_IMPLEMENTED = new HTTPStatus(501, 'Not Implemented');
	public static final BAD_GATEWAY = new HTTPStatus(502, 'Bad Gateway');
	public static final SERVICE_UNAVAILABLE = new HTTPStatus(503, 'Service Unavailable');
	public static final GATEWAY_TIMEOUT = new HTTPStatus(504, 'Gateway Timeout');
	public static final HTTP_VERSION_NOT_SUPPORTED = new HTTPStatus(505, 'HTTP Version Not Supported');
	public static final VARIANT_ALSO_NEGOTIATES = new HTTPStatus(506, 'Variant Also Negotiates');
	public static final INSUFFICIENT_STORAGE = new HTTPStatus(507, 'Insufficient Storage');
	public static final LOOP_DETECTED = new HTTPStatus(508, 'Loop Detected');
	public static final NOT_EXTENDED = new HTTPStatus(510, 'Not Extended');
	public static final NETWORK_AUTHENTICATION_REQUIRED = new HTTPStatus(511, 'Network Authentication Required');

	public var code:Int;
	public var message:String;

	private function new(code:Int, message:String) {
		this.code = code;
		this.message = message;
	}
}

private class HeaderParser {
	private static final MAX_HEADERS = 100;
	private static final MAX_LINE = 65536;

	public static function parseHeaders(input:Input):Map<String, String> {
		var headers = readHeaders(input);
		return parseHeaderLines(headers);
	}

	private static function readHeaders(input:Input):Array<String> {
		var headers:Array<String> = [];
		while (true) {
			var line = "";
			var lineLength = 0;
			var char:String = null;
			while (true) {
				char = input.readString(1);
				if (char == "\r") {
					continue;
				} else if (char == "\n") {
					break;
				} else {
					line += char;
					lineLength++;
					if (lineLength > MAX_LINE) {
						break;
					}
				}
			}
			if (lineLength > MAX_LINE) {
				throw new Exception("header line too long");
			}
			headers.push(line);
			if (headers.length > MAX_HEADERS) {
				throw new Exception('got more than ${MAX_HEADERS} headers');
			}
			if (line == "\r\n" || line == "\n" || line == "") {
				break;
			}
		}
		return headers;
	}

	private static function parseHeaderLines(headers:Array<String>):Map<String, String> {
		var result:Map<String, String> = [];
		for (header in headers) {
			if (header.length == 0) {
				return result;
			}
			var colonIndex = header.indexOf(":");
			if (colonIndex == -1) {
				// TODO: should probably do something more
				return result;
			}
			var name = StringTools.trim(header.substr(0, colonIndex));
			var value = StringTools.trim(header.substr(colonIndex + 1));
			result.set(name, value);
		}
		return result;
	}
}
