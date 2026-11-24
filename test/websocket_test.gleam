import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/option.{None}
import glisten/tcp
import gramps/websocket.{Complete, Continuation, Data, Incomplete, TextFrame}
import mist
import scaffold

pub fn it_should_combine_continuation_frames_test() {
  let one = <<"Hello":utf8>>
  let two = <<", ":utf8>>
  let three = <<"world!":utf8>>
  let messages = [
    Incomplete(Data(TextFrame(one))),
    Incomplete(Continuation(bit_array.byte_size(two), two)),
    Complete(Continuation(bit_array.byte_size(three), three)),
  ]

  let combined = <<"Hello, world!":utf8>>

  assert websocket.aggregate_frames(messages, None, [])
    == Ok([Data(TextFrame(combined))])
}

fn websocket_handler(
  events: process.Subject(String),
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req) {
    mist.websocket(
      request: req,
      handler: fn(state, _message, _connection) {
        process.send(events, "message")
        mist.continue(state)
      },
      on_init: fn(_connection) { #(Nil, None) },
      on_close: fn(_state) { process.send(events, "closed") },
    )
  }
}

const upgrade_request = <<
  "GET / HTTP/1.1\r\nhost: localhost\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n\r\n":utf8,
>>

// The events that arrive in the next 500 milliseconds
fn receive_events(events: process.Subject(String)) -> List(String) {
  case process.receive(events, 500) {
    Ok(event) -> [event, ..receive_events(events)]
    Error(_nil) -> []
  }
}

pub fn it_runs_on_close_and_sends_no_message_on_a_close_frame_test() {
  let events = process.new_subject()
  use <- scaffold.start_server(
    mist.new(websocket_handler(events))
    |> mist.port(8888),
  )
  let socket = scaffold.http1_open(upgrade_request)
  let _upgraded = scaffold.http1_receive(socket)

  // A masked close frame with the status code 1000 and a zero mask
  let assert Ok(_nil) =
    scaffold.http1_send(socket, <<0x88, 0x82, 0, 0, 0, 0, 1000:16>>)

  assert receive_events(events) == ["closed"]
}

pub fn it_runs_on_close_and_sends_no_message_when_the_client_drops_test() {
  let events = process.new_subject()
  use <- scaffold.start_server(
    mist.new(websocket_handler(events))
    |> mist.port(8888),
  )
  let socket = scaffold.http1_open(upgrade_request)
  let _upgraded = scaffold.http1_receive(socket)

  let assert Ok(_nil) = tcp.close(socket)

  assert receive_events(events) == ["closed"]
}
