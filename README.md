# dream_http_server

> **This is a fork of [mist](https://github.com/rawhat/mist), published by the [Dream](https://github.com/TrustBound/dream) project. If you are not using Dream, use mist.**
>
> The package is named for what it does, an HTTP server, so that it does not appear when people search Hex for mist.

## Why this package exists

mist is the web server that Dream runs on. It is written by Alex Manning (rawhat) and its contributors, and it has given a great deal to us and to the rest of the Gleam community. This package is not a replacement for it and not a judgement of it.

We publish this fork for four reasons.

1. **Dream needed many fixes, not one.** HTTP/2 in mist 6.0.3 was not finished. Requests with a body got no response, every request left a process behind, large responses stalled, and several kinds of client input closed or crashed the whole connection. Making HTTP/2 correct for Dream took 42 changes, in 47 commits. They are listed below under "What is different from mist 6.0.3", and each one is on the branch `http2-review-fixes`.
2. **Giving that many changes back takes a long time.** Each change has to go upstream as its own small pull request, in the maintainer's style, and be reviewed and released on the maintainer's schedule. That is the right way to do it, and it cannot be hurried. We intend to send every one of them.
3. **Dream could not wait any longer.** This version of Dream has already been delayed too long, and its users need the fixes now.
4. **Hex and Gleam leave no other way to ship a fixed dependency.** A Hex package may depend only on other Hex packages, so Dream cannot depend on a git fork or a local path. A Gleam package is built only from the real files in its own `src/` folder, so Dream cannot use a git submodule as its source either: we tested it, and the published package comes out with the files in the wrong place. The choices left were to copy mist's source into Dream, or to publish the fork as its own package. Publishing the fork keeps mist's code, history and licence in one place, apart from Dream's.

## What you need to know before you use it

- **This package defines the same modules as mist** (`mist`, `mist/internal/...`). A project cannot depend on both `mist` and `dream_http_server`. Gleam stops the build with a duplicate module error.
- **The code is mist 6.0.3 plus our fixes, and nothing else.** We do not rename, reformat or restyle mist's source. What is published here is what we send upstream.
- **It is temporary.** When a mist release contains the fixes, Dream goes back to `mist`, and this package gets a final release that says so.
- **Report problems with this package to [TrustBound/mist](https://github.com/TrustBound/mist/issues), not to the mist maintainers.** They did not publish it and do not support it.

## What is different from mist 6.0.3

The package differs from mist 6.0.3 in four ways. Nothing else is changed:
no source file is renamed, reformatted or restyled.

1. **The package name.** It is `dream_http_server`. The modules are still
   `mist` and `mist/internal/...`.
2. **One dependency.** It depends on
   [`dream_socket_server`](https://github.com/TrustBound/glisten/tree/dream-socket-server),
   our fork of glisten, in place of `glisten`.
3. **The changes to the code, listed below.** Each one is its own commit
   with a test.
4. **Three files for the package itself.** This notice at the top of the
   README, the `dream_http_server 1.0.0` entry in `CHANGELOG.md`, and
   `test/dream_http_server_test.gleam`, which lets `gleam test` run the
   existing tests under the new package name.

To see every changed line, compare the branch with the upstream release:
<https://github.com/rawhat/mist/compare/v6.0.3...TrustBound:mist:dream-http-server>

### The changes

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

## Licence and credit

mist is licensed under Apache-2.0, and so is this fork. The copyright stays with Alex Manning and the mist contributors. Our changes are offered under the same licence.

---

*The original mist README follows.*

---

# mist

[![Package Version](https://img.shields.io/hexpm/v/mist)](https://hex.pm/packages/mist)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/mist/)

## A glistening Gleam web server.

To follow along with the example below, you can create a new project and add the
dependencies as follows:

```sh
$ gleam new <your_project>
$ cd <your_project>
$ gleam add mist logging gleam_erlang gleam_http
```

The main entrypoint for your application is `mist.start`. The argument to this
function is generated from the opaque `Builder` type. It can be constructed with
the `mist.new` function, and fed updated configuration options with the
associated methods (demonstrated in the examples below).

```gleam
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import logging
import mist.{type Connection, type ResponseData}

const index = "<html lang='en'>
  <head>
    <title>Mist Example</title>
  </head>
  <body>
    Hello, world!
  </body>
</html>"

pub fn main() {
  logging.configure()
  logging.set_level(logging.Debug)

  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_tree.new()))

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      let _ = case mist.get_connection_info(req.body) {
        Ok(info) -> {
          logging.log(
            logging.Info,
            "Got a request from: " <> mist.connection_info_to_string(info),
          )
        }
        Error(_nil) -> {
          logging.log(logging.Info, "Failed to get connection info")
        }
      }
      case request.path_segments(req) {
        [] ->
          response.new(200)
          |> response.prepend_header("my-value", "abc")
          |> response.prepend_header("my-value", "123")
          |> response.set_body(mist.Bytes(bytes_tree.from_string(index)))
        ["ws"] ->
          mist.websocket(
            request: req,
            on_init: fn(_conn) { #(Nil, None) },
            on_close: fn(_state) { io.println("goodbye!") },
            handler: handle_ws_message,
          )
        ["echo"] -> echo_body(req)
        ["chunk"] ->
          mist.chunked(
            req,
            response.new(200),
            fn(subj) {
              process.spawn(fn() { send_chunks(subj) })
              Nil
            },
            fn(state, msg, connection) {
              case msg {
                Data(str) -> {
                  let assert Ok(_nil) =
                    mist.send_chunk(connection, bit_array.from_string(str))
                  mist.chunk_continue(state)
                }
                Done -> {
                  mist.chunk_stop()
                }
              }
            },
          )
        ["file", ..rest] -> serve_file(req, rest)
        ["stream"] -> handle_stream(req)

        _ -> not_found
      }
    }
    |> mist.new
    |> mist.bind("localhost")
    |> mist.with_ipv6
    |> mist.port(4000)
    |> mist.start

  process.sleep_forever()
}

pub type MyMessage {
  Broadcast(String)
}

fn handle_ws_message(state, message, conn) {
  case message {
    mist.Text("ping") -> {
      let assert Ok(_) = mist.send_text_frame(conn, "pong")
      mist.continue(state)
    }
    mist.Text(msg) -> {
      logging.log(logging.Info, "Received text frame: " <> msg)
      mist.continue(state)
    }
    mist.Binary(msg) -> {
      logging.log(
        logging.Info,
        "Received binary frame ("
          <> int.to_string(bit_array.byte_size(msg))
          <> ")",
      )
      mist.continue(state)
    }
    mist.Custom(Broadcast(text)) -> {
      let assert Ok(_) = mist.send_text_frame(conn, text)
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn echo_body(request: Request(Connection)) -> Response(ResponseData) {
  let content_type =
    request
    |> request.get_header("content-type")
    |> result.unwrap("text/plain")

  mist.read_body(request, 1024 * 1024 * 10)
  |> result.map(fn(req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(req.body)))
    |> response.set_header("content-type", content_type)
  })
  |> result.lazy_unwrap(fn() {
    response.new(400)
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  })
}

type ChunkMessage {
  Data(data: String)
  Done
}

fn send_chunks(subject: Subject(ChunkMessage)) {
  ["one", "two", "three"]
  |> list.each(fn(data) {
    process.sleep(2000)
    process.send(subject, Data(data))
  })
  process.send(subject, Done)
}

fn serve_file(
  _req: Request(Connection),
  path: List(String),
) -> Response(ResponseData) {
  let file_path = string.join(path, "/")

  // Omitting validation for brevity
  mist.send_file(file_path, offset: 0, limit: None)
  |> result.map(fn(file) {
    let content_type = guess_content_type(file_path)
    response.new(200)
    |> response.prepend_header("content-type", content_type)
    |> response.set_body(file)
  })
  |> result.lazy_unwrap(fn() {
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  })
}

fn handle_stream(req: Request(Connection)) -> Response(ResponseData) {
  let failed =
    response.new(400) |> response.set_body(mist.Bytes(bytes_tree.new()))
  case mist.stream(req) {
    Ok(consume) -> {
      case do_handle_stream(consume, <<>>) {
        Ok(body) ->
          response.new(200)
          |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
        Error(_reason) -> failed
      }
    }
    Error(_reason) -> {
      failed
    }
  }
}

fn do_handle_stream(
  consume: fn(Int) -> Result(mist.Chunk, mist.ReadError),
  body: BitArray,
) -> Result(BitArray, Nil) {
  case consume(1024) {
    Ok(mist.Chunk(data, consume)) ->
      do_handle_stream(consume, <<body:bits, data:bits>>)
    Ok(mist.Done) -> Ok(body)
    Error(_reason) -> Error(Nil)
  }
}

fn guess_content_type(_path: String) -> String {
  "application/octet-stream"
}
```
