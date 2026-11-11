import exception
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/hackney
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/factory_supervisor as factory
import gleam/result
import gleam/set
import gleam/string
import gleam/uri
import glisten
import glisten/internal/handler as glisten_handler
import glisten/socket.{type Socket, type SocketReason}
import glisten/socket/options
import glisten/tcp
import glisten/transport.{Tcp}
import mist
import mist/internal/handler
import mist/internal/http.{type Connection} as mhttp
import mist/internal/http2
import mist/internal/http2/frame.{type Frame}

pub fn with_server(
  at port: Int,
  with handler: fn(Request(Connection)) -> Response(mist.ResponseData),
  given req: Request(String),
) -> Response(String) {
  use <- open_server(port, handler)

  let assert Ok(resp) = hackney.send(req)

  resp
}

pub fn open_server(
  at port: Int,
  with handler: fn(Request(Connection)) -> Response(mist.ResponseData),
  after perform: fn() -> return,
) -> return {
  let factory_supervisor = process.new_name("mist_factory_supervisor")
  let chunked_response_supervisor =
    process.spawn_unlinked(fn() {
      let assert Ok(_chunked) =
        factory.worker_child(fn(start) { start() })
        |> factory.named(factory_supervisor)
        |> factory.start()

      process.sleep_forever()
    })

  let pid =
    process.spawn_unlinked(fn() {
      let assert Ok(listener) = tcp.listen(port, [])
      let assert Ok(socket) = tcp.accept(listener)

      let loop_func =
        handler.with_func(
          fn(req) {
            req
            |> handler
            |> convert_body_types
          },
          factory_supervisor,
        )

      let glisten_handler =
        glisten_handler.Handler(
          socket: socket,
          on_init: handler.init,
          on_close: option.None,
          loop: convert_loop(loop_func),
          transport: Tcp,
          active_state: options.Once,
        )

      let assert Ok(server) = glisten_handler.start(glisten_handler)
      let assert Ok(owner) = process.subject_owner(server.data)
      let assert Ok(_nil) = tcp.controlling_process(socket, owner)
      process.send(server.data, glisten_handler.Internal(glisten_handler.Ready))

      process.sleep_forever()
    })

  case exception.rescue(perform) {
    Ok(return) -> {
      process.kill(pid)
      exit(chunked_response_supervisor, atom.create("shutdown"))
      return
    }
    Error(err) -> {
      process.kill(pid)
      exit(chunked_response_supervisor, atom.create("shutdown"))
      panic as { "Handler failed with: " <> string.inspect(err) }
    }
  }
}

fn convert_body_types(
  resp: Response(mist.ResponseData),
) -> Response(mhttp.ResponseData) {
  let new_body = case resp.body {
    mist.Websocket -> mhttp.Websocket
    mist.Bytes(data) -> mhttp.Bytes(data)
    mist.File(descriptor, offset, length) ->
      mhttp.File(descriptor, offset, length)
    mist.Chunked -> mhttp.Chunked
    mist.ServerSentEvents -> mhttp.ServerSentEvents
  }
  response.set_body(resp, new_body)
}

fn map_user_selector(
  value: glisten.Message(user_message),
) -> glisten_handler.LoopMessage(user_message) {
  case value {
    glisten.Packet(msg) -> glisten_handler.Packet(msg)
    glisten.User(msg) -> glisten_handler.Custom(msg)
  }
}

fn convert_loop(
  loop: glisten.Loop(data, user_message),
) -> glisten_handler.Loop(data, user_message) {
  fn(data, msg, conn: glisten_handler.Connection(user_message)) {
    let conn = glisten.Connection(conn.socket, conn.transport, conn.sender)
    case msg {
      glisten_handler.Packet(msg) ->
        loop(data, glisten.Packet(msg), conn)
        |> glisten.map_selector(map_user_selector)
        |> glisten.convert_next
      glisten_handler.Custom(msg) ->
        loop(data, glisten.User(msg), conn)
        |> glisten.map_selector(map_user_selector)
        |> glisten.convert_next
    }
  }
}

type ChunkMessage {
  Data(data: String)
  Done
}

pub fn chunked_echo_server(chunk_size: Int) {
  let chunk_sender = fn(body: String, subject: process.Subject(ChunkMessage)) {
    body
    |> string.to_graphemes
    |> list.sized_chunk(chunk_size)
    |> list.each(fn(chars) {
      chars
      |> string.join("")
      |> fn(data) { process.send(subject, Data(data)) }
      process.sleep(5)
    })
    process.send(subject, Done)
  }
  fn(req: request.Request(mhttp.Connection)) {
    let assert Ok(read_request) = mhttp.read_body(req)
    let assert Ok(body) = bit_array.to_string(read_request.body)
    mist.chunked(
      req,
      response.new(200),
      fn(subj) { process.spawn(fn() { chunk_sender(body, subj) }) },
      fn(state, msg, conn) {
        case msg {
          Data(data) -> {
            let assert Ok(_sent) =
              mist.send_chunk(conn, bit_array.from_string(data))
            mist.chunk_continue(state)
          }
          Done -> {
            mist.chunk_stop()
          }
        }
      },
    )
  }
}

pub fn default_handler(
  req: request.Request(Connection),
) -> response.Response(mist.ResponseData) {
  let too_beeg =
    response.new(413)
    |> response.set_header("connection", "close")
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  let req = mist.read_body(req, 4_000_000)
  use <- bool.guard(when: result.is_error(req), return: too_beeg)
  let assert Ok(req) = req
  let body =
    req.query
    |> option.map(bit_array.from_string)
    |> option.unwrap(req.body)
    |> bytes_tree.from_bit_array
  let length =
    body
    |> bytes_tree.byte_size
    |> int.to_string
  let headers =
    list.filter(req.headers, fn(p) {
      case p {
        #("transfer-encoding", "chunked") -> False
        #("content-length", _) -> False
        _ -> True
      }
    })
    |> list.prepend(#("content-length", length))
  Response(status: 200, headers: headers, body: mist.Bytes(body))
}

pub fn uri_echo_handler(
  req: request.Request(Connection),
) -> response.Response(mist.ResponseData) {
  let path =
    req
    |> request.to_uri
    |> uri.to_string
  let body = http.method_to_string(req.method) <> " " <> path
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn compare_bitstring_body(actual: BitArray, expected: BytesTree) {
  assert bytes_tree.from_bit_array(actual) == expected
}

fn compare_string_body(actual: String, expected: BytesTree) {
  assert bytes_tree.from_string(actual) == expected
}

fn compare_headers_and_status(actual: Response(a), expected: Response(b)) {
  assert actual.status == expected.status

  let expected_headers = set.from_list(expected.headers)
  let actual_headers =
    actual.headers
    |> set.from_list
    |> set.filter(fn(pair) {
      let #(key, _value) = pair
      key != "date"
    })

  let missing_headers =
    set.filter(expected_headers, fn(header) {
      set.contains(actual_headers, header) == False
    })
  let extra_headers =
    set.filter(actual_headers, fn(header) {
      set.contains(expected_headers, header) == False
    })

  assert missing_headers == extra_headers
}

pub fn string_response_should_equal(
  actual: Response(String),
  expected: Response(BytesTree),
) {
  compare_headers_and_status(actual, expected)
  compare_string_body(actual.body, expected.body)
}

pub fn bitstring_response_should_equal(
  actual: Response(BitArray),
  expected: Response(BytesTree),
) {
  compare_headers_and_status(actual, expected)
  compare_bitstring_body(actual.body, expected.body)
}

pub fn make_request(path: String, body: body) -> request.Request(body) {
  request.new()
  |> request.set_host("localhost:8888")
  |> request.set_method(http.Post)
  |> request.set_path(path)
  |> request.set_body(body)
  |> request.set_scheme(http.Http)
}

pub fn http2_request(headers: List(#(String, String))) -> Response(BitArray) {
  let assert Ok(socket) =
    [options.Mode(options.Binary), options.ActiveMode(options.Passive)]
    |> options.to_erl_options
    |> gen_tcp_connect(atom.create("localhost"), 8888, _)

  let initial_settings = http2.default_settings()
  let assert Ok(#(headers, _context)) =
    http2.hpack_new_context(initial_settings.header_table_size)
    |> http2.hpack_encode(headers)

  let settings_frame = frame.Settings(ack: False, settings: [])
  let header_frame =
    frame.Header(
      data: frame.Complete(headers),
      end_stream: True,
      identifier: frame.stream_identifier(1),
      priority: option.None,
    )

  let assert Ok(_nil) =
    bytes_tree.from_string("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    |> tcp.send(socket, _)
  let assert Ok(_nil) = http2.send_frame(settings_frame, socket, Tcp)
  let assert #(frame.Settings(..), rest) = receive_frame(socket, <<>>)
  let assert Ok(_nil) = http2.send_frame(frame.settings_ack(), socket, Tcp)
  let assert Ok(_nil) = http2.send_frame(header_frame, socket, Tcp)
  let resp =
    receive_response(socket, rest, Response(status: 0, headers: [], body: <<>>))
  let assert Ok(_nil) = tcp.close(socket)

  resp
}

fn receive_frame(socket: Socket, data: BitArray) -> #(Frame, BitArray) {
  case frame.decode(data) {
    Ok(decoded) -> decoded
    Error(_connection_error) -> {
      let assert Ok(received) = tcp.receive_timeout(socket, 0, 5000)
      receive_frame(socket, <<data:bits, received:bits>>)
    }
  }
}

fn receive_response(
  socket: Socket,
  data: BitArray,
  resp: Response(BitArray),
) -> Response(BitArray) {
  let #(received, rest) = receive_frame(socket, data)
  let #(resp, end_stream) = case received {
    frame.Header(data: frame.Complete(data), end_stream: end_stream, ..) -> {
      let initial_settings = http2.default_settings()
      let assert Ok(#(headers, _context)) =
        http2.hpack_new_context(initial_settings.header_table_size)
        |> http2.hpack_decode(data)
      let assert Ok(#(status, headers)) =
        headers
        |> list.key_pop(":status")
      let assert Ok(status) = int.parse(status)
      #(Response(status: status, headers: headers, body: <<>>), end_stream)
    }
    frame.Data(data: data, end_stream: end_stream, ..) -> #(
      response.set_body(resp, <<resp.body:bits, data:bits>>),
      end_stream,
    )
    _frame -> #(resp, False)
  }
  case end_stream {
    True -> resp
    False -> receive_response(socket, rest, resp)
  }
}

@external(erlang, "gen_tcp", "connect")
fn gen_tcp_connect(
  host host: atom.Atom,
  port port: Int,
  options options: List(options.ErlangTcpOption),
) -> Result(Socket, SocketReason)

type IoFormat {
  User
}

@external(erlang, "io", "fwrite")
fn io_fwrite(
  format format: IoFormat,
  output_format output_format: String,
  data data: any,
) -> Nil

pub fn io_fwrite_user(data: anything) {
  io_fwrite(User, "~tp\n", [data])
}

@external(erlang, "erlang", "exit")
fn exit(pid: process.Pid, reason: anything) -> Nil
