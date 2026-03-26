import gleam/bit_array
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response
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

  let #(frame_type, flags, stream_id, payload) =
    h2c_recv_frame(socket, 5000)
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
  let #(frame_type, flags, _stream_id, payload) =
    h2c_recv_frame(socket, 5000)
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

  let #(frame_type, _flags, stream_id, payload) =
    h2c_recv_frame(socket, 5000)
  assert frame_type == 7
  assert stream_id == 0

  let assert <<_reserved:size(1), _last_stream_id:size(31),
    error_code:size(32), _rest:bits>> = payload
  assert error_code == 6

  h2c_close(socket)
}
