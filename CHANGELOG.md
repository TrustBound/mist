# Changelog

# dream_http_server 1.3.0

Two more changes to mist:

- Keep an HTTP/1.1 connection open after a `chunked` response. The last
  chunk marks the end of the body, so the connection now reads the next
  request, as it does after any other response. Before this, the server
  closed the connection after the last chunk and sent no `connection: close`
  header, so a client that sent its next request on that connection lost it
- Send `server_sent_events` on HTTP/1.1 with `transfer-encoding: chunked`,
  one chunk for each event, and keep the connection open after the last
  chunk. Before this, the events had no length and no chunks, so only the
  close of the connection marked their end, and a client could not tell a
  stream that ended from a connection that broke. The response said
  `connection: keep-alive` and the server closed the connection

For both, the connection keeps the socket and waits until the process that
sends the body stops. A watcher process starts before that process can
stop, and tells the connection how it stopped. When it stops with an error,
the response has no last chunk, and the server closes the connection. A
`chunked` response with a `connection: close` header closes the connection
after the last chunk. HTTP/2 is unchanged

Tests: 104 run, 0 failed. Mac: Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1,
OTP 29, Gleam 1.19.2, about 12 seconds with the build check, 5 of 5 runs
passed. Linux: the mist CI steps in Ubuntu 24.04 (aarch64, Docker), OTP
28.0, Gleam 1.14.0, format check passed, 6 of 6 runs passed.

# dream_http_server 1.2.0

One more change to mist:

- Add `server_sent_events_with_selector`. Its `init` returns the state and an
  optional selector, so the server-sent events process can receive messages
  from other parts of the application. mist 5 allowed this and mist 6
  dropped it. `server_sent_events` is unchanged

Tests: 100 run, 0 failed. Mac: Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1,
OTP 29, Gleam 1.17.0, about 3.5 seconds, 3 of 3 runs passed. Linux: the
mist CI steps in Ubuntu 24.04 (aarch64, Docker), OTP 28.0, Gleam 1.14.0,
format check passed, 6 of 6 runs passed.

# dream_http_server 1.1.0

Four more changes to mist, each its own commit:

- Offer HTTP/2 in the TLS handshake (ALPN) when TLS is on. Clients that ask
  for `h2` get HTTP/2, and the rest get HTTP/1.1. Before this, TLS clients,
  browsers included, always got HTTP/1.1
- Stream HTTP/2 request bodies with `stream`, which crashed on every HTTP/2
  request
- Forward HTTP/2 request bodies to `chunked` and `server_sent_events`
  responses, which run in their own process and got no body data
- Let `chunked` and `server_sent_events` processes stop before they take the
  socket. The hand-over then failed, and a 500 response was written after
  the body

A test also checks that a request with `Upgrade: h2c` gets an HTTP/1.1
answer: the upgrade is deprecated by RFC 9113 and allows h2c smuggling.

Tests: 98 run, 0 failed. Mac: Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1,
OTP 29, Gleam 1.17.0, about 3.5 seconds, 3 of 3 runs passed. Linux: the
mist CI steps in Ubuntu 24.04 (aarch64, Docker), OTP 28.0, Gleam 1.14.0,
format check passed, 6 of 6 runs passed.

# dream_http_server 1.0.0

First release of the dream_http_server fork. It is mist 6.0.3 with the
changes below and nothing else.

Package changes:

- The package is named `dream_http_server`. The modules keep their names
  (`mist`, `mist/internal/...`)
- Depend on `dream_socket_server` in place of `glisten`
- Add `test/dream_http_server_test.gleam` so that `gleam test` runs the
  existing tests under the new package name

Changes to mist, each its own commit on the branch `http2-review-fixes`:

- Read remaining request data before closing so the response is not lost to a
  connection reset
- Apply HTTP/2 pseudo-headers to the request
- Respond with HTTP 400 on missing `host` header over HTTP/2
- Fix encoding and decoding of some HTTP/2 frames and ignore unknown frames
- Fix HTTP/2 responses to requests with a body and stop stream processes
- Handle HTTP/2 frames received with the client preface
- Split HTTP/2 responses into frames of the maximum frame size
- Reset HTTP/2 streams on stream errors instead of closing the connection
- Respond to HTTP/2 `Ping` frames and stop streams reset by the client
- Apply HTTP/2 settings from the client and ignore unknown settings
- Respect HTTP/2 flow control windows when sending response bodies
- Send HTTP/2 `GoAway` on connection errors and close normally on `GoAway`
- Support `server_sent_events` over HTTP/2
- Support `chunked` responses over HTTP/2
- Fix reading a file at its end returning an invalid value
- Support `send_file` responses over HTTP/2
- Respond with HTTP 500 when the handler fails over HTTP/2
- Send HTTP/2 response headers and body in a single write
- Skip the HTTP/2 stream window update when the stream has ended
- Stop copying the whole HTTP/2 request body for every `Data` frame
- Read HTTP/2 request bodies until the end of the stream, not by `content-length`
- Read HTTP/2 request headers split into `Continuation` frames
- End the HTTP/2 request body on trailers instead of starting a second request
- Reject HTTP/2 frames larger than the maximum frame size
- Wait for HTTP/2 `chunked` and `server_sent_events` data to be sent before returning
- Stop the HTTP/2 handler when its stream is reset
- Cancel HTTP/2 `chunked` and `server_sent_events` sends that time out
- Reject HTTP/2 requests that reuse a stream identifier
- Close the HTTP/2 connection on `Continuation` without a header block
- Limit the size of HTTP/2 header blocks to 64 KiB
- Reset HTTP/2 streams whose body does not match `content-length`
- Reset HTTP/2 requests that declare `content-length` but have no body
- Reset HTTP/2 streams that receive data after the client ended them
- Grant the HTTP/2 stream receive window as the request body is read
- Reset HTTP/2 streams answered before the request body ended
- Count HTTP/2 `Data` frame padding against the flow control windows
- Advertise and enforce the HTTP/2 limit of 100 concurrent streams
- Wait up to 15 seconds for each part of an HTTP/2 request body
- Add `with_read_timeout` to set how long to wait for request data
- Add `with_send_timeout` to set how long to wait for HTTP/2 data to be sent
- Advertise an HTTP/2 stream receive window of 1 MiB
- Add `with_initial_window_size` to set the HTTP/2 stream receive window

# v6.0.3

- Continue handling frames after receiving `Ping`
- Bump `stdlib` to `>=1.0.0`
- Respond with HTTP 400 on missing `host` header instead of abnormal exit

# v6.0.2

- Properly send close frame when user handler stops its loop
- Use correct content length header when sending a file with offset

# v6.0.1

- Revert `clock` supervisor change to allow multiple mist servers in the same VM

# v6.0.0

- Rename `get_client_info` to `get_connection_info`
- Use factory supervisor pattern
- Rename `get_client_info` to better match record name
- Update SSE and chunked encoding to use `actor`-ish pattern
- Remove some `string.inspect` on errors for better logging and performance
- Remove `application_start_module` in favor of static supervisor child for
clock process

# v5.0.4

- Removed usage of deprecated `result.unwrap_both`

# v5.0.3
- Replace custom `rescue` with the `exception` package
- Bump `gramps` version for better WebSocket compression support

# v5.0.2
- Re-add `supervised` method

# v5.0.1
- Revert clock change from named process back to erlang application
    - Running multiple mist supervisors would cause issues with starting the
    ETS table

# v5.0.0
- Refine API for starting and TLS

# v5.0.0-rc1
- Support `gleam_erlang` and `gleam_otp` v1
- Add `supervised` and `supervised_ssl` methods to help integrating with
existing supervisors
- Simply starting APIs
- Add `mist.Next` helper functions for websockets to abstract over
`gleam_otp/actor.Next` type

## v4.1.0
- Bump `stdlib` version requirement to >=0.50.0

## v4.0.7
- Tighten `gleam_http` constraint for new function

## v4.0.6
- Relaxed `gleam_http` constraint to permit v4.

## v4.0.5
- Migrate to `gleam/dynamic/decode` API

## v4.0.4
- Open files in `binary` mode to fix SSL file send bug

## v4.0.3
- Properly handle `content-length` and drop body on response when appropriate

## v4.0.2
- Replace `birl` with manual date methods (Thank you, @giacomocavalieri)

## v4.0.1
- Remove some code that produces a warning when compiling

## v4.0.0
- Bump `stdlib` version requirement to >=0.44.0

## v3.0.0
- Allow binding to an interface
- Disable IPv6 by default
- Pass `IpAddress` to `after_start`

## v2.0.0

- Return `Server` type from `start_*` methods to get OS-assigned port.  Will
also eventually provide graceful shutdown options
- Move client IP / port access from `Connection` to public function
- Don't keep HTTP/1.0 connection open
- Fix bug reading large requests from socket

## v1.2.0

- Bump gleam version requirement
- Use `erlang` application start module for clock

## v1.1.0

- Don't pull or `let assert` from websocket when more data is needed
- Don't use `uri.parse` because it's a bit slow
- Don't use the `request.set_<property>` methods, because I'm already setting
basically everything and they are kinda slow
- Support `permessage-deflate` WebSocket extension
- Pull some stuff out of `mist` into `gramps` and use its updated API
- Allow returning multiple headers with the same name
    - Currently there are no checks on which headers you do this with

## v1.0.0

- Internal API refactor along with (absolutely not ready) initial HTTP/2
"support" included but disabled
- Bumped some dependency versions
- Fix performance regression with `Date: ` header

## v1.0.0-rc2

- Second pass at Server-Sent Events
    - This API more closely follows the `gleam/otp/actor` API

## v1.0.0-rc1

- Parse `Host` header to set `host` and `port` fields on `Request`
- Bump `glisten` version
- Remove deprecated `function.compose` usage
- Support sending files over SSL
    - This does not use `sendfile` as that's not supported
    - Currently, it will naively read the whole file into memory
- Changed error type returned from `mist.start_https`
    - This now checks for the presence of the key and certificate files
- Bump `glisten` version again!
- First pass at support for Server-Sent Events

## v0.17.0

- Bump dep versions to get access to `Subject` from `glisten.serve(_ssl)`

## v0.16.0

- Updated for Gleam v0.33.0.
- Log error from `rescue` in WebSocket handlers
- WebSocket `Text` frame is now a `String`, since the spec notes that this type
  of message must be valid UTF-8

## v0.15.0

- Lots of WebSocket changes around spec correctness (still not 100% there)
- Fixed a few bugs around WebSocket handlers and user selectors

## v0.14.3

- Fix regression in WebSocket handler

## v0.14.2

- Pass scheme to `after_start` to allow building valid URLs

## v0.14.1

- Pass WebSocket state to `on_close` handler
- Fix socket active mode bug in WebSocket actor
- Update packages and change `bit_string` to `bit_array` and `bit_builder` to
  `bytes_builder`

## v0.14.0

- Remove WebSocket builder in favor of plain function
- Adds `on_init` and `on_close` to WebSocket upgrade function
- Fix an issue where websocket crashes on internal control close frame
- Upgrade to `glisten` v0.9

## v0.13.2

- Upgrade `glisten` and `gleam_otp` versions

## v0.13.1

- Improve file sending ergonomics

## v0.13.0

- Big API refactor
- Add `client_ip` to `Connection` construct
- Fix reading chunked encoding
- Add method for streaming request body

## v0.12.0

- Correctly handle query strings (@Johann150)
- Add constructor for opaque `Body` type for testing handlers
- Handle WebSocket `ping` frames and reply correctly
- Fix incorrect pattern match in `file_open` (@avdgaag)

## v0.11.0

- Big public API refactoring and docs clean-up
- Fixed erroneous extra CRLF after response body

## v0.10.0

- Support chunked responses, via `Chunked(Iterator(BitBuilder))`
- Convert syntax for gleam v0.27 support

## v0.9.4

- Utilize `request.scheme` to determine which transport to use automatically
- Support the `Expect: 100-continue` header functionality

## v0.9.3

- Remove duplicate imports that errored on newer gleam versions

## v0.9.2

- Support more HTTP status codes

## v0.9.1

- Allow `state.transport` in handlers to abstract over `TCP`/`SSL`

## v0.9.0

- Add SSL support via the `run_service_ssl` and `serve_ssl` methods
- Some refactorings in the internal libraries, if you were depending on them

## v0.8.3

- Update `glisten` version

## v0.8.2

- Fixed up broken README examples

## v0.8.1

- Removed a `main` method I accidentally left in :(

## v0.8.0

- BREAKING:
  - refactor `http.handle` and `http.handle_func` into separate module

The `handler_func` implementation was about 250 lines. That seemed a little
excessive and unclear, so I just pulled that stuff out into separate functions.
I also thought it might be nice to have a separate `handler` module that housed
this code. The actual consumer changes are minimal.

## v0.7.1

- Revert `websocket.send` change
  - It should be a similar order to `process.send`

## v0.7.0

- Stop automatically reading body
  - `run_service` now accepts maximum body size
  - `http` module exports `read_body` to manually parse body
- Support `Transfer-Encoding: chunked` requests
- Properly support query parameters

## v0.6.1

- Fix `websocket.send` argument order
- Bump GitHub workflow versions

## v0.6.0

- Big WebSocket changes
  - Handle larger text messages
  - Support binary messages
  - Properly reply to `ping` messages
  - Add helper function for `send`ing

## v0.5.2

- Properly support (most) HTTP methods

## v0.5.1

- Use `Sender` in WS handler instead of raw socket

## v0.5.0

- Bump `glisten` version
- Add support for `on_init` and `on_close` events on WebSockets

## v0.4.5

- Make sure to include `"content-length"` header

## v0.4.4

- Wrap user handler function in `rescue` call
- Add `logger` support for error handling

## v0.4.3

- Remove default `"content-type"` header guessing
- Add `run_service` method for simple servers

## v0.4.2

- Update some handler response type names

## v0.4.1

- Support for sending files with `file:sendfile`

## v0.4.0

- Remove `router` module and move to `http`

## Note

I started this list way later and don't really feel like going back further
than this.
