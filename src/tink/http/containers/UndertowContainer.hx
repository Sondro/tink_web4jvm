package tink.http.containers;

import tink.http.Container;
import tink.http.Request;
import tink.http.Header;
import tink.http.Handler;
import tink.io.*;
import io.undertow.server.HttpServerExchange;

using tink.CoreApi;

class Runnable implements java.lang.Runnable {
	var f:Void->Void;

	public function new(f) {
		this.f = f;
	}

	public function run() {
		f();
	}
}

class TinkHttpHandler implements io.undertow.server.HttpHandler {
	var handler:Handler;
	var errorListener:SignalTrigger<tink.http.ContainerFailure>;

	public function new(tinkHttpHandler:Handler, errorListener) {
		this.handler = tinkHttpHandler;
		this.errorListener = errorListener;
	}

	public function handleRequest(exchange:HttpServerExchange) {
		try {
			var undertowHandler = UndertowContainer.toUndertowHandler(this.handler);
			exchange.dispatch(io.undertow.util.SameThreadExecutor.INSTANCE, new Runnable(() -> {
				undertowHandler(exchange).handle(() -> {
					trace('End exchange.');
					exchange.endExchange();
				});
			}));
		} catch (e:Dynamic) {
			this.errorListener.trigger({
				error: Error.withData("Error handling HTTP Request", e),
				request: UndertowContainer.incomingRequestFromExchange(exchange),
				response: null
			});
		}
	}
}

class UndertowContainer implements Container {
	public function new(host, port) {
		this.host = host;
		this.port = port;
	}

	var host:String;
	var port:Null<Int>;

	static public function incomingRequestFromExchange(exchange:HttpServerExchange) {
		var body = function(exchange:HttpServerExchange) return Plain(tink.io.java.UndertowSource.wrap("incoming undertow request",
			cast exchange.getRequestReceiver(), () -> {}));
		var b = body(exchange);
		var req = new IncomingRequest(exchange.getSourceAddress().toString(),
			new IncomingRequestHeader(cast exchange.getRequestMethod().toString(), exchange.getRequestURL(), exchange.getProtocol().toString(), [
				for (header in exchange.getRequestHeaders())
					new HeaderField(header.getHeaderName().toString(), [for (i in 0...header.size()) header.get(i)].join(', '))
			]), b);
		return req;
	}

	static public function toUndertowHandler(handler:Handler) {
		return (exchange:HttpServerExchange) -> Future.async(cb -> handler.process(incomingRequestFromExchange(exchange)).handle(out -> {
			// sys.io.File.saveContent("./request-callstack.out", haxe.CallStack.toString(haxe.CallStack.callStack()));
			var headers = new Map();
			for (h in out.header) {
				if (!headers.exists(h.name))
					headers[h.name] = [];
				headers[h.name].push(h.value);
			}
			var responseHeaders = exchange.getResponseHeaders();
			for (name in headers.keys()) {
				for (val in headers[name]) {
					responseHeaders.add(new io.undertow.util.HttpString(name), val);
				}
			}
			var sink = tink.io.java.UndertowSink.wrap("async-sender", exchange.getResponseSender());
			out.body.pipeTo(sink).handle(() -> {});
		}));
	}

	public function run(handler:Handler) {
		return Future.async(cb -> {
			var failures = Signal.trigger();
			var server = io.undertow.Undertow.builder()
				.addListener(port != null ? port : 8080, host != null ? host : "localhost")
				.setHandler(new TinkHttpHandler(handler, failures))
				.build();
			server.start();
			cb(Running({
				shutdown: (hard:Bool) -> {
					if (hard)
						trace("Warning: hard shutdown not implemented");
					return Future.async(cb -> {
						server.stop();
						cb(true);
					});
				},
				failures: failures.asSignal()
			}));
		});
	}
}
