import gleam/bit_array
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/yielder
import mist
import mist/internal/http.{type Connection}
import scaffold

type H2cSocket

@external(erlang, "h2c_ffi", "h2c_connect")
fn h2c_connect(port: Int) -> H2cSocket

@external(erlang, "h2c_ffi", "h2c_connect_raw")
fn h2c_connect_raw(port: Int) -> H2cSocket

@external(erlang, "h2c_ffi", "h2c_send_headers")
fn h2c_send_headers(
  socket: H2cSocket,
  stream_id: Int,
  headers: List(#(String, String)),
  end_stream: Bool,
) -> Nil

@external(erlang, "h2c_ffi", "h2c_send_frame")
fn h2c_send_frame(socket: H2cSocket, frame_bytes: BitArray) -> Nil

@external(erlang, "h2c_ffi", "h2c_recv_frame")
fn h2c_recv_frame(socket: H2cSocket, timeout: Int) -> #(Int, Int, Int, BitArray)

@external(erlang, "h2c_ffi", "h2c_send_ping")
fn h2c_send_ping(socket: H2cSocket, data: BitArray) -> Nil

@external(erlang, "h2c_ffi", "h2c_close")
fn h2c_close(socket: H2cSocket) -> Nil

fn simple_handler(
  _req: Request(Connection),
) -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("hello")))
}

pub fn it_responds_to_ping_with_ack_test() {
  use <- scaffold.open_server(19_001, simple_handler)

  let socket = h2c_connect(19_001)
  let ping_data = <<1, 2, 3, 4, 5, 6, 7, 8>>
  h2c_send_ping(socket, ping_data)

  let #(frame_type, flags, stream_id, payload) = h2c_recv_frame(socket, 5000)
  assert frame_type == 6
  assert flags == 1
  assert stream_id == 0
  assert payload == ping_data

  h2c_close(socket)
}

pub fn it_sends_settings_ack_test() {
  use <- scaffold.open_server(19_002, simple_handler)

  let socket = h2c_connect_raw(19_002)

  h2c_send_frame(socket, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>)

  let #(settings_type, settings_flags, settings_stream, _) =
    h2c_recv_frame(socket, 5000)
  assert settings_type == 4
  assert settings_flags == 0
  assert settings_stream == 0

  h2c_send_frame(socket, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>)

  let #(ack_type, ack_flags, ack_stream, _) = h2c_recv_frame(socket, 5000)
  assert ack_type == 4
  assert ack_flags == 1
  assert ack_stream == 0

  h2c_close(socket)
}

pub fn it_handles_basic_get_request_test() {
  use <- scaffold.open_server(19_003, simple_handler)

  let socket = h2c_connect(19_003)

  h2c_send_headers(
    socket,
    1,
    [
      #(":method", "GET"),
      #(":path", "/"),
      #(":scheme", "http"),
      #(":authority", "localhost"),
    ],
    True,
  )

  let #(headers_type, _headers_flags, headers_stream, _) =
    h2c_recv_frame(socket, 5000)
  assert headers_type == 1
  assert headers_stream == 1

  let #(data_type, _data_flags, data_stream, data_payload) =
    h2c_recv_frame(socket, 5000)
  assert data_type == 0
  assert data_stream == 1
  assert data_payload == bit_array.from_string("hello")

  h2c_close(socket)
}

pub fn it_handles_rst_stream_test() {
  use <- scaffold.open_server(19_004, simple_handler)

  let socket = h2c_connect(19_004)

  h2c_send_headers(
    socket,
    1,
    [
      #(":method", "GET"),
      #(":path", "/"),
      #(":scheme", "http"),
      #(":authority", "localhost"),
    ],
    True,
  )

  h2c_send_frame(socket, <<0, 0, 4, 3, 0, 0, 0, 0, 1, 0, 0, 0, 8>>)

  let ping_data = <<10, 20, 30, 40, 50, 60, 70, 80>>
  h2c_send_ping(socket, ping_data)

  drain_until_ping_ack(socket, ping_data)

  h2c_close(socket)
}

fn drain_until_ping_ack(socket: H2cSocket, expected_data: BitArray) -> Nil {
  let #(frame_type, flags, _stream_id, payload) = h2c_recv_frame(socket, 5000)
  case frame_type, flags {
    6, 1 -> {
      assert payload == expected_data
      Nil
    }
    _, _ -> drain_until_ping_ack(socket, expected_data)
  }
}

pub fn it_sends_goaway_on_protocol_error_test() {
  use <- scaffold.open_server(19_005, simple_handler)

  let socket = h2c_connect(19_005)

  h2c_send_frame(socket, <<0, 0, 5, 4, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5>>)

  let #(frame_type, _flags, stream_id, payload) = h2c_recv_frame(socket, 5000)
  assert frame_type == 7
  assert stream_id == 0

  let assert <<
    _reserved:size(1),
    _last_stream_id:size(31),
    error_code:size(32),
    _rest:bits,
  >> = payload
  assert error_code == 6

  h2c_close(socket)
}

pub fn it_keeps_connection_alive_after_request_test() {
  use <- scaffold.open_server(19_006, simple_handler)

  let socket = h2c_connect(19_006)

  h2c_send_headers(
    socket,
    1,
    [
      #(":method", "GET"),
      #(":path", "/"),
      #(":scheme", "http"),
      #(":authority", "localhost"),
    ],
    True,
  )

  let ping_data = <<11, 22, 33, 44, 55, 66, 77, 88>>
  h2c_send_ping(socket, ping_data)

  drain_until_ping_ack(socket, ping_data)

  h2c_close(socket)
}

pub fn it_handles_multiple_requests_same_connection_test() {
  use <- scaffold.open_server(19_007, simple_handler)

  let socket = h2c_connect(19_007)

  h2c_send_headers(
    socket,
    1,
    [
      #(":method", "GET"),
      #(":path", "/"),
      #(":scheme", "http"),
      #(":authority", "localhost"),
    ],
    True,
  )

  let #(headers_type_1, _, headers_stream_1, _) = h2c_recv_frame(socket, 5000)
  assert headers_type_1 == 1
  assert headers_stream_1 == 1

  let #(data_type_1, _, data_stream_1, data_payload_1) =
    h2c_recv_frame(socket, 5000)
  assert data_type_1 == 0
  assert data_stream_1 == 1
  assert data_payload_1 == bit_array.from_string("hello")

  h2c_send_headers(
    socket,
    3,
    [
      #(":method", "GET"),
      #(":path", "/"),
      #(":scheme", "http"),
      #(":authority", "localhost"),
    ],
    True,
  )

  let #(headers_type_2, _, headers_stream_2, _) = h2c_recv_frame(socket, 5000)
  assert headers_type_2 == 1
  assert headers_stream_2 == 3

  let #(data_type_2, _, data_stream_2, data_payload_2) =
    h2c_recv_frame(socket, 5000)
  assert data_type_2 == 0
  assert data_stream_2 == 3
  assert data_payload_2 == bit_array.from_string("hello")

  h2c_close(socket)
}

pub fn it_ignores_window_update_for_closed_stream_test() {
  use <- scaffold.open_server(19_008, simple_handler)

  let socket = h2c_connect(19_008)

  h2c_send_headers(
    socket,
    1,
    [
      #(":method", "GET"),
      #(":path", "/"),
      #(":scheme", "http"),
      #(":authority", "localhost"),
    ],
    True,
  )

  let ping_data_1 = <<1, 1, 1, 1, 1, 1, 1, 1>>
  h2c_send_ping(socket, ping_data_1)
  drain_until_ping_ack(socket, ping_data_1)

  h2c_send_frame(socket, <<0, 0, 4, 8, 0, 0, 0, 0, 99, 0, 0, 0, 100>>)

  let ping_data_2 = <<2, 2, 2, 2, 2, 2, 2, 2>>
  h2c_send_ping(socket, ping_data_2)
  drain_until_ping_ack(socket, ping_data_2)

  h2c_close(socket)
}

pub fn it_ignores_unknown_frame_type_test() {
  use <- scaffold.open_server(19_009, simple_handler)

  let socket = h2c_connect(19_009)

  h2c_send_frame(socket, <<0, 0, 4, 255, 0, 0, 0, 0, 0, 1, 2, 3, 4>>)

  let ping_data = <<3, 3, 3, 3, 3, 3, 3, 3>>
  h2c_send_ping(socket, ping_data)

  let #(frame_type, flags, _stream_id, payload) = h2c_recv_frame(socket, 5000)
  assert frame_type == 6
  assert flags == 1
  assert payload == ping_data

  h2c_close(socket)
}

fn many_headers_handler(
  _req: Request(Connection),
) -> response.Response(mist.ResponseData) {
  let headers =
    int.range(from: 1, to: 30, with: [], run: fn(acc, i) {
      [
        #("x-custom-header-" <> int.to_string(i), "value-" <> int.to_string(i)),
        ..acc
      ]
    })
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  |> fn(resp) { response.Response(..resp, headers: headers) }
}

pub fn it_sends_continuation_frames_for_large_headers_test() {
  use <- scaffold.open_server(19_010, many_headers_handler)

  let socket = h2c_connect_raw(19_010)

  let #(settings_type, settings_flags, _, _) = h2c_recv_frame(socket, 5000)
  assert settings_type == 4
  assert settings_flags == 0

  h2c_send_frame(socket, <<0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 64>>)

  h2c_send_frame(socket, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>)

  let #(ack_type, ack_flags, _, _) = h2c_recv_frame(socket, 5000)
  assert ack_type == 4
  assert ack_flags == 1

  h2c_send_headers(
    socket,
    1,
    [
      #(":method", "GET"),
      #(":path", "/"),
      #(":scheme", "http"),
      #(":authority", "localhost"),
    ],
    True,
  )

  let #(first_type, first_flags, first_stream, _) = h2c_recv_frame(socket, 5000)
  assert first_type == 1
  assert first_stream == 1
  let first_end_headers = int.bitwise_and(first_flags, 4) == 4
  assert first_end_headers == False

  drain_until_end_headers(socket)

  h2c_close(socket)
}

fn drain_until_end_headers(socket: H2cSocket) -> Nil {
  let #(frame_type, flags, _stream_id, _payload) = h2c_recv_frame(socket, 5000)
  case frame_type {
    9 -> {
      let end_headers = int.bitwise_and(flags, 4) == 4
      case end_headers {
        True -> Nil
        False -> drain_until_end_headers(socket)
      }
    }
    _ -> drain_until_end_headers(socket)
  }
}

fn streaming_handler(
  _req: Request(Connection),
) -> response.Response(mist.ResponseData) {
  let stream =
    yielder.from_list([
      bytes_tree.from_string("chunk1"),
      bytes_tree.from_string("chunk2"),
      bytes_tree.from_string("chunk3"),
    ])
  response.new(200)
  |> response.set_body(mist.Streaming(stream))
}

pub fn it_sends_streaming_data_incrementally_test() {
  use <- scaffold.open_server(19_011, streaming_handler)

  let socket = h2c_connect(19_011)

  h2c_send_headers(
    socket,
    1,
    [
      #(":method", "GET"),
      #(":path", "/"),
      #(":scheme", "http"),
      #(":authority", "localhost"),
    ],
    True,
  )

  let #(headers_type, _, _, _) = h2c_recv_frame(socket, 5000)
  assert headers_type == 1

  let data_frames = collect_data_frames(socket, [])

  let non_empty =
    list.filter(data_frames, fn(payload) { bit_array.byte_size(payload) > 0 })
  assert list.length(non_empty) >= 2

  let combined =
    list.fold(data_frames, <<>>, fn(acc, payload) { <<acc:bits, payload:bits>> })
  assert combined == bit_array.from_string("chunk1chunk2chunk3")

  h2c_close(socket)
}

fn collect_data_frames(socket: H2cSocket, acc: List(BitArray)) -> List(BitArray) {
  let #(frame_type, flags, _stream_id, payload) = h2c_recv_frame(socket, 5000)
  case frame_type {
    0 -> {
      let end_stream = int.bitwise_and(flags, 1) == 1
      let new_acc = [payload, ..acc]
      case end_stream {
        True -> list.reverse(new_acc)
        False -> collect_data_frames(socket, new_acc)
      }
    }
    _ -> collect_data_frames(socket, acc)
  }
}
