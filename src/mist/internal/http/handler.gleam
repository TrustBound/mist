import exception
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Subject}
import gleam/http as ghttp
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glisten/internal/handler.{Close, Internal}
import glisten/socket.{type Socket, type SocketReason, Badarg}
import glisten/transport.{type Transport}
import logging
import mist/internal/encoder
import mist/internal/file
import mist/internal/http.{
  type Connection, type Handler, type ResponseData, Bytes, ChunkProcessStarted,
  ChunkProcessStopped, Chunked, File, ServerSentEvents, Websocket,
}

pub type State {
  State(idle_timer: Option(process.Timer))
}

pub fn initial_state() -> State {
  State(idle_timer: None)
}

pub fn call(
  req: Request(Connection),
  handler: Handler,
  sender: Subject(handler.Message(user_message)),
  version: http.HttpVersion,
) -> Result(State, Result(Nil, String)) {
  exception.rescue(fn() { handler(req) })
  |> result.map_error(log_and_error(
    _,
    req.body.socket,
    req.body.transport,
    req,
    version,
  ))
  |> result.try(fn(resp) {
    case
      http.close_if_requested(req, resp)
      |> http.close_if_body_unread(req, _)
    {
      response.Response(body: Websocket, ..) -> {
        Error(Ok(Nil))
      }
      response.Response(body: ServerSentEvents, ..) as resp ->
        await_chunked_response(
          resp,
          req.body,
          sender,
          bytes_tree.from_bit_array(last_chunk_bytes),
        )
      response.Response(body: Chunked, ..) as resp ->
        await_chunked_response(resp, req.body, sender, bytes_tree.new())
      response.Response(body: body, ..) as resp -> {
        case body {
          Bytes(body) ->
            handle_bytes_tree_body(resp, body, req.body, req, version)
          File(..) -> handle_file_body(resp, body, req.body, version)
          _ -> panic as "This shouldn't ever happen 🤞"
        }
        |> result.replace_error(Ok(Nil))
        |> result.try(close_or_set_timer(_, req.body, sender))
      }
    }
  })
}

const last_chunk_bytes = <<"0\r\n\r\n":utf8>>

// The chunks of a chunked response mark the end of its body, so the
// connection can take the next request after the last chunk. The process of
// a `chunked` response sends its last chunk itself. The process of
// `server_sent_events` stops without one, so the connection sends it
fn await_chunked_response(
  resp: response.Response(ResponseData),
  conn: Connection,
  sender: Subject(handler.Message(user_message)),
  last_chunk: BytesTree,
) -> Result(State, Result(Nil, String)) {
  // The process can stop before `chunked` returns. Its `ChunkProcessStopped`
  // is then here first, and the `ChunkProcessStarted` of `chunked` after it
  let stopped = case process.receive(conn.chunk_process, 0) {
    Ok(ChunkProcessStarted) -> Ok(process.receive_forever(conn.chunk_process))
    Ok(ChunkProcessStopped(_reason) as stopped) -> Ok(stopped)
    Error(Nil) -> Error(Nil)
  }
  case stopped {
    Ok(ChunkProcessStopped(process.Normal)) -> {
      let _ = transport.send(conn.transport, conn.socket, last_chunk)
      resp
      |> response.set_body(bytes_tree.new())
      |> close_or_set_timer(conn, sender)
    }
    Ok(_stopped_with_an_error) -> {
      // The response has no last chunk, so the client must not read
      // another response from this connection
      let _ = transport.close(conn.transport, conn.socket)
      Error(Ok(Nil))
    }
    Error(Nil) -> Error(Ok(Nil))
  }
}

fn log_and_error(
  error: exception.Exception,
  socket: Socket,
  transport: Transport,
  req: Request(Connection),
  version: http.HttpVersion,
) -> Result(Nil, String) {
  let error_string = string.inspect(error)
  logging.log(logging.Error, error_string)
  let resp =
    response.new(500)
    |> response.set_body(
      bytes_tree.from_bit_array(<<"Internal Server Error":utf8>>),
    )
    |> response.prepend_header("content-length", "21")
    |> http.add_default_headers(req.method == ghttp.Head)

  let resp = case version {
    http.Http1 -> http.connection_close(resp)
    _ -> http.maybe_keep_alive(resp)
  }

  let _ =
    resp
    |> encoder.to_bytes_tree(http.version_to_string(version))
    |> transport.send(transport, socket, _)

  let _ = lingering_close(transport, socket)
  Error(error_string)
}

fn close_or_set_timer(
  resp: response.Response(BytesTree),
  conn: Connection,
  sender: Subject(handler.Message(user_message)),
) -> Result(State, Result(Nil, String)) {
  // If the handler explicitly says to close the connection, we should
  // probably listen to them
  case response.get_header(resp, "connection") {
    Ok("close") -> {
      let _ = lingering_close(conn.transport, conn.socket)
      Error(Ok(Nil))
    }
    _ -> {
      // TODO:  this should be a configuration
      let timer = process.send_after(sender, 10_000, Internal(Close))
      Ok(State(idle_timer: Some(timer)))
    }
  }
}

type TimeUnit {
  Millisecond
}

const linger_timeout = 5000

// Closing a socket that still has unread data from the client resets the
// connection, which can throw away the response before the client reads it
fn lingering_close(
  transport: Transport,
  socket: Socket,
) -> Result(Nil, SocketReason) {
  let _ = transport.shutdown(transport, socket)
  drain(transport, socket, monotonic_time(Millisecond) + linger_timeout)
  transport.close(transport, socket)
}

fn drain(transport: Transport, socket: Socket, deadline: Int) -> Nil {
  case deadline - monotonic_time(Millisecond) {
    timeout if timeout > 0 ->
      case transport.receive_timeout(transport, socket, 0, timeout) {
        Ok(_data) -> drain(transport, socket, deadline)
        Error(_reason) -> Nil
      }
    _expired -> Nil
  }
}

fn handle_file_body(
  resp: response.Response(ResponseData),
  body: ResponseData,
  conn: Connection,
  http_version: http.HttpVersion,
) -> Result(response.Response(BytesTree), SocketReason) {
  let assert File(file_descriptor, offset, length) = body
  let resp =
    resp
    |> response.set_body(bytes_tree.new())
    |> http.add_date_header
    |> response.prepend_header("content-length", int.to_string(length))

  let resp = case http_version {
    http.Http1 -> http.connection_close(resp)
    _ -> http.maybe_keep_alive(resp)
  }

  let return =
    resp
    |> fn(r: response.Response(BytesTree)) {
      encoder.response_builder(
        resp.status,
        r.headers,
        http.version_to_string(http_version),
      )
    }
    |> transport.send(conn.transport, conn.socket, _)
    |> result.try(fn(_) {
      file.sendfile(
        conn.transport,
        file_descriptor,
        conn.socket,
        offset,
        length,
        [],
      )
      |> result.map_error(fn(err) {
        logging.log(
          logging.Error,
          "Failed to send file: " <> string.inspect(err),
        )
        Badarg
      })
    })
    |> result.replace(resp)

  case file.close(file_descriptor) {
    Ok(_nil) -> Nil
    Error(reason) -> {
      logging.log(
        logging.Error,
        "Failed to close file: " <> file.error_to_string(reason),
      )
    }
  }

  return
}

fn handle_bytes_tree_body(
  resp: response.Response(ResponseData),
  body: BytesTree,
  conn: Connection,
  req: Request(Connection),
  version: http.HttpVersion,
) -> Result(response.Response(BytesTree), SocketReason) {
  let resp =
    resp
    |> response.set_body(body)
    |> http.add_default_headers(req.method == ghttp.Head)

  let resp = case version {
    http.Http1 -> http.connection_close(resp)
    _ -> http.maybe_keep_alive(resp)
  }

  resp
  |> encoder.to_bytes_tree(http.version_to_string(version))
  |> transport.send(conn.transport, conn.socket, _)
  |> result.replace(resp)
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: TimeUnit) -> Int
