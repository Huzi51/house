# :house
##### Minimal asynchronous Common Lisp web server

`:house` started out as part of [the `:deal` project](https://github.com/Inaimathi/deal) ("deal"? "house"? get it?). I hacked it out in an attempt to generalize it and use it other projects with similar objectives. It's intentionally minimal, single-threaded and stresses readability over efficiency both in its internals and in the interfacing code it requires.

### News

- Fixed the buffering system so that slow POST requests that pause between headers and body are now handled properly
- `define-closing-handler` and `define-stream-handler` have now been merged into `define-handler`. The new macro now has a `:close-socket?` keyword param that defaults to `t`.
- House now depends on [:session-token](https://github.com/Inaimathi/session-token) and generates tokens without exhausting entropy
- House exports `path->uri`

### Installation

- If you haven't already done so, install [`quicklisp`](http://www.quicklisp.org/beta/).
- Clone [this repo](https://github.com/Inaimathi/house) into `quicklisp/local-projects/`.
- Hop into your lisp and run `(ql:quickload :house)`

### Usage
##### Quick start

    (define-handler (hello-world :content-type "text/plain") ()
      "Hello world!")
	(house:start 4040)

You should then be able to hop over to a browser and visit `http://localhost:4040/hello-world` to see the plaintext `"Hello world!"` response.

##### Threaded quick start

Because `:house` is single-threaded, using `house:start` directly as above will monopolize your REPL. You might not care about that in certain circumstances, or perhaps your deployment environment can't afford the extra thread. If you do and it can, you should start `:house` in a separate thread to retain your ability to evaluate things against the running system. You can do that the usual way:

    (defparameter *server* (bordeaux-threads:make-thread (lambda () (house:start 4040))))

##### Static Files

**House is not a file server**. Static file serving capability is provided for ease of testing, and maybe for *very* small-scale deployment. If you're going to be taking any significant traffic, get a reverse proxy going with something like [`nginx`](http://www.cyberciti.biz/tips/using-nginx-as-reverse-proxy.html).

You can define a static file handler with

    (define-file-handler [file-or-directory])

It'll handle individual files by serving them, and it'll handle directories by serving all contained files recursively.

##### Redirecting

You can set up re-directors with

    (define-redirect-handler (name :permanent? t) "/static/name.html")

Requests for `"/name"` will now instead serve a `301 Moved Permanently` response with a target of `"/static/name.html"` (if you leave out `:permanent? t`, it'll be a `307 Temporary Redirect` instead). House isn't optimized for redirecting, either from the performance or the notation perspective. If you're going to be re-directing any significant number of pages, consider having your reverse proxy handling that too.

##### Using the type annotations

You can specify desired argument types for your handlers. For example:

    (define-handler (handler) ((foo :json) (bar :integer)))
       ...)

You can then use `bar` as an integer and `foo` as a parsed JSON s-expression in the body of that handler. The built-in types are `:string`, `:integer`, `:json`, `:keyword`, `:list-of-keyword` and `:list-of-integer`. If you need a more specific type, you can use `define-http-type`. For example:

    (define-http-type (:game)
	     :type-expression `(gethash ,parameter *game-table*)
	     :type-assertion `(typep ,parameter 'game))

Once that's done, you can annotate parameters with the `:game` label.

    (define-handler (handler) ((foo :game) ...) ...)

`foo` will then be looked up in `*game-table*`, and `assert-http`-ed to be of type `'game` before the handler body is evaluated.

It's also possible to enforce arbitrary properties of parsed parameters. For instance

    (define-handler (handler) ((foo :integer (>= 64 foo 2) (evenp foo)))
       ...)

ensures that `foo` will be an even integer between 2 and 64 (inclusive).

All this is entirely optional. If you don't care about it, just pass un-annotated arguments to your handlers, and they'll do exactly what you'd expect. You'll then be able to handle the type-conversion/assertions entirely manually.

### External API
#### Basics
###### `start`

Takes a port-number and starts the server listening on that port.

#### Handlers
###### `define-handler`

Defines a handler. The handler body has access to three bound symbols in addition to its parameters:

- `sock`: the requesting socket (should only really be used for `subscribe!` calls, but you can also write things to it if you need to send stuff before the request proper)
- `session`: the session belonging to the requesting user
- `parameters`: the raw parameters `alist` (note that each expected parameter is also bound to the corresponding symbol)

Depending on the keyword parameter `:close-socket?`, it may or may not close the incoming TCP stream after it responds.

###### `define-json-handler`

Defines a closing `handler` that responds with `"application/json"`, and automatically JSON-encodes its response.

###### `define-redirect-handler`

Defines a handler that sends either `301` or `307` HTTP responses (permanent redirect and temporary redirect respectively).

###### `define-file-handler`

Defines a handler that very inefficiently responds with static files.

#### Event Streams
###### `subscribe!`

Subscribes the specified socket to the specified channel. Should only be used with stream handlers, since the socket will need to be kept open for a subscription to be relevant.

###### `publish!`

Publishes a message to all subscribers of the specified channel.

*The rest is still TODO.*

#### Session
###### `new-session!`
###### `new-session-hook!`
###### `clear-session-hooks!`
###### `get-session!`
###### `lookup`

#### Handler types
###### `define-http-type`

#### Macro-symbols
###### `parameter`
###### `restrictions`
###### `assert-http`
###### `root`
###### `sock`
###### `session`
###### `parameters`

