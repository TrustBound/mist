import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import mist
import mist/internal/http2/frame
import scaffold.{bitstring_response_should_equal}

pub fn it_applies_pseudo_headers_test() {
  let headers = [
    #(":method", "POST"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/some/path?x=1"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let actual = scaffold.http2_request(headers)

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "42")
    |> response.set_body(
      bytes_tree.from_bit_array(<<
        "POST http://example.com:8080/some/path?x=1":utf8,
      >>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_rejects_requests_without_host_test() {
  let headers = [#(":method", "GET"), #(":scheme", "http"), #(":path", "/")]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let actual = scaffold.http2_request(headers)

  let expected =
    response.new(400)
    |> response.prepend_header("content-length", "0")
    |> response.set_body(bytes_tree.from_bit_array(<<>>))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_ignores_unknown_frames_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let actual =
    scaffold.http2_request_after(<<0, 0, 1, 255, 0, 0, 0, 0, 1, 0>>, headers)

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "28")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"GET http://example.com:8080/":utf8>>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_responds_after_reading_the_body_test() {
  let headers = [
    #(":method", "POST"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
    #("content-length", "10"),
  ]

  use <- scaffold.open_server(8888, scaffold.default_handler)

  let actual = scaffold.http2_request_with_body(headers, <<"0123456789":utf8>>)

  let expected =
    response.new(200)
    |> response.prepend_header("host", "example.com:8080")
    |> response.prepend_header("content-length", "10")
    |> response.set_body(bytes_tree.from_bit_array(<<"0123456789":utf8>>))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_ignores_window_updates_on_closed_streams_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let assert [_first, actual] =
    scaffold.http2_requests([
      #(<<>>, headers, <<>>),
      #(<<0, 0, 4, 8, 0, 0, 0, 0, 1, 0, 0, 3, 232>>, headers, <<>>),
    ])

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "28")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"GET http://example.com:8080/":utf8>>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_handles_frames_sent_with_the_preface_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let actual = scaffold.http2_request(headers)

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "28")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"GET http://example.com:8080/":utf8>>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_splits_large_bodies_into_frames_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let body = <<string.repeat("a", 60_000):utf8>>

  use <- scaffold.open_server(8888, fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
  })

  let actual = scaffold.http2_request(headers)

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "60000")
    |> response.set_body(bytes_tree.from_bit_array(body))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_splits_large_headers_into_frames_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let value = string.repeat("a", 20_000)

  use <- scaffold.open_server(8888, fn(_req) {
    response.new(200)
    |> response.set_header("x-large", value)
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  })

  let actual = scaffold.http2_request(headers)

  let expected =
    response.new(200)
    |> response.prepend_header("x-large", value)
    |> response.prepend_header("content-length", "0")
    |> response.set_body(bytes_tree.from_bit_array(<<>>))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_resets_data_on_closed_streams_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let assert [_first, actual] =
    scaffold.http2_requests([
      #(<<>>, headers, <<>>),
      #(<<0, 0, 1, 0, 0, 0, 0, 0, 1, 97>>, headers, <<>>),
    ])

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "28")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"GET http://example.com:8080/":utf8>>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_resets_streams_with_invalid_methods_test() {
  let invalid = [
    #(":method", "BAD METHOD"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let assert [_reset, actual] =
    scaffold.http2_requests([#(<<>>, invalid, <<>>), #(<<>>, headers, <<>>)])

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "28")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"GET http://example.com:8080/":utf8>>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_responds_to_ping_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let actual =
    scaffold.http2_request_after(
      <<0, 0, 8, 6, 0, 0, 0, 0, 0, "pingpong":utf8>>,
      headers,
    )

  let expected =
    response.new(0)
    |> response.set_body(bytes_tree.from_bit_array(<<"pingpong":utf8>>))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_stops_reset_streams_test() {
  let slow = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/slow"),
  ]
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let pids = process.new_subject()

  use <- scaffold.open_server(8888, fn(req) {
    case request.path_segments(req) {
      ["slow"] -> {
        process.send(pids, process.self())
        process.sleep_forever()
        scaffold.uri_echo_handler(req)
      }
      _ -> scaffold.uri_echo_handler(req)
    }
  })

  let assert [_ping, actual] =
    scaffold.http2_requests([
      #(<<0, 0, 8, 6, 0, 0, 0, 0, 0, "pingpong":utf8>>, slow, <<>>),
      #(<<0, 0, 4, 3, 0, 0, 0, 0, 1, 0, 0, 0, 8>>, headers, <<>>),
    ])
  let assert Ok(pid) = process.receive(pids, 1000)

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "28")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"GET http://example.com:8080/":utf8>>),
    )

  bitstring_response_should_equal(actual, expected)
  assert !process.is_alive(pid)
}

pub fn it_ignores_unknown_settings_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let actual =
    scaffold.http2_request_after(
      <<0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 1>>,
      headers,
    )

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "28")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"GET http://example.com:8080/":utf8>>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_waits_for_window_updates_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let body = <<string.repeat("a", 100_000):utf8>>

  use <- scaffold.open_server(8888, fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
  })

  let actual = scaffold.http2_request(headers)

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "100000")
    |> response.set_body(bytes_tree.from_bit_array(body))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_sends_go_away_on_malformed_frames_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let assert [_first, actual] =
    scaffold.http2_requests([
      #(<<>>, headers, <<>>),
      #(<<0, 0, 4, 6, 0, 0, 0, 0, 0, "ping":utf8>>, headers, <<>>),
    ])

  let expected =
    response.new(0)
    |> response.set_body(
      bytes_tree.from_bit_array(<<
        0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 6,
      >>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_sends_go_away_on_malformed_headers_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let assert [_first, actual] =
    scaffold.http2_requests([
      #(<<>>, headers, <<>>),
      #(
        <<0, 0, 6, 1, 5, 0, 0, 0, 3, 255, 255, 255, 255, 255, 255>>,
        headers,
        <<>>,
      ),
    ])

  let expected =
    response.new(0)
    |> response.set_body(
      bytes_tree.from_bit_array(<<
        0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 9,
      >>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_sends_server_sent_events_test() {
  let events = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/events"),
  ]
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, fn(req) {
    case request.path_segments(req) {
      ["events"] ->
        mist.server_sent_events(
          req,
          response.new(200),
          init: fn(subj) {
            process.send(subj, 1)
            process.send(subj, 2)
            process.send(subj, 3)
            Nil
          },
          loop: fn(state, message, conn) {
            let event =
              mist.event(string_tree.from_string(int.to_string(message)))
            let assert Ok(_nil) = mist.send_event(conn, event)
            case message {
              3 -> actor.stop()
              _ -> actor.continue(state)
            }
          },
        )
      _ -> scaffold.uri_echo_handler(req)
    }
  })

  let assert [actual, after] =
    scaffold.http2_requests([#(<<>>, events, <<>>), #(<<>>, headers, <<>>)])

  let expected =
    response.new(200)
    |> response.prepend_header("content-type", "text/event-stream")
    |> response.prepend_header("cache-control", "no-cache")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"data: 1\n\ndata: 2\n\ndata: 3\n\n":utf8>>),
    )

  bitstring_response_should_equal(actual, expected)

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "28")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"GET http://example.com:8080/":utf8>>),
    )

  bitstring_response_should_equal(after, expected)
}

pub fn it_sends_chunked_responses_test() {
  let headers = [
    #(":method", "POST"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
    #("content-length", "1000"),
  ]
  let body = <<string.repeat("a", 1000):utf8>>

  use <- scaffold.open_server(8888, scaffold.chunked_echo_server(100))

  let assert [actual, after] =
    scaffold.http2_requests([#(<<>>, headers, body), #(<<>>, headers, body)])

  let expected =
    response.new(200)
    |> response.set_body(bytes_tree.from_bit_array(body))

  bitstring_response_should_equal(actual, expected)
  bitstring_response_should_equal(after, expected)
}

pub fn it_sends_file_responses_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, fn(_req) {
    let assert Ok(file) =
      mist.send_file("gleam.toml", offset: 8, limit: Some(4))
    response.new(200)
    |> response.set_body(file)
  })

  let assert [actual, after] =
    scaffold.http2_requests([#(<<>>, headers, <<>>), #(<<>>, headers, <<>>)])

  let assert Ok(<<_offset:bytes-size(8), body:bytes-size(4), _rest:bits>>) =
    scaffold.read_file("gleam.toml")
  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "4")
    |> response.set_body(bytes_tree.from_bit_array(body))

  bitstring_response_should_equal(actual, expected)
  bitstring_response_should_equal(after, expected)
}

pub fn it_sends_empty_file_responses_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, fn(_req) {
    let assert Ok(file) =
      mist.send_file("gleam.toml", offset: 0, limit: Some(0))
    response.new(200)
    |> response.set_body(file)
  })

  let actual = scaffold.http2_request(headers)

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "0")
    |> response.set_body(bytes_tree.from_bit_array(<<>>))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_responds_with_500_on_handler_errors_test() {
  let failing = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/fail"),
  ]
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, fn(req) {
    case request.path_segments(req) {
      ["fail"] -> panic as "handler failed"
      _ -> scaffold.uri_echo_handler(req)
    }
  })

  let assert [actual, after] =
    scaffold.http2_requests([#(<<>>, failing, <<>>), #(<<>>, headers, <<>>)])

  let expected =
    response.new(500)
    |> response.prepend_header("content-length", "21")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"Internal Server Error":utf8>>),
    )

  bitstring_response_should_equal(actual, expected)

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "28")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"GET http://example.com:8080/":utf8>>),
    )

  bitstring_response_should_equal(after, expected)
}

pub fn it_resets_streams_on_handler_errors_after_headers_test() {
  let failing = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/fail"),
  ]
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, fn(req) {
    case request.path_segments(req) {
      ["fail"] -> {
        let _response =
          mist.chunked(
            req,
            response.new(200),
            init: fn(subj) { process.send(subj, Nil) },
            loop: fn(_state, _message, _conn) { mist.chunk_stop() },
          )
        panic as "handler failed"
      }
      _ -> scaffold.uri_echo_handler(req)
    }
  })

  let assert [actual, after] =
    scaffold.http2_requests([#(<<>>, failing, <<>>), #(<<>>, headers, <<>>)])

  let expected =
    response.new(200)
    |> response.set_body(bytes_tree.from_bit_array(<<>>))

  bitstring_response_should_equal(actual, expected)

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "28")
    |> response.set_body(
      bytes_tree.from_bit_array(<<"GET http://example.com:8080/":utf8>>),
    )

  bitstring_response_should_equal(after, expected)
}

pub fn it_reads_bodies_without_content_length_test() {
  let headers = [
    #(":method", "POST"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.default_handler)

  let actual = scaffold.http2_request_with_body(headers, <<"0123456789":utf8>>)

  let expected =
    response.new(200)
    |> response.prepend_header("host", "example.com:8080")
    |> response.prepend_header("content-length", "10")
    |> response.set_body(bytes_tree.from_bit_array(<<"0123456789":utf8>>))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_limits_bodies_without_content_length_test() {
  let headers = [
    #(":method", "POST"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, fn(req) {
    case mist.read_body(req, 9) {
      Ok(_req) -> response.new(200)
      Error(_read_error) -> response.new(413)
    }
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  })

  let actual = scaffold.http2_request_with_body(headers, <<"0123456789":utf8>>)

  let expected =
    response.new(413)
    |> response.prepend_header("content-length", "0")
    |> response.set_body(bytes_tree.from_bit_array(<<>>))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_reads_headers_split_into_frames_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
    #("x-large", string.repeat("a", 20_000)),
  ]

  use <- scaffold.open_server(8888, fn(req) {
    let assert Ok(large) = request.get_header(req, "x-large")
    response.new(200)
    |> response.set_body(
      mist.Bytes(bytes_tree.from_string(int.to_string(string.length(large)))),
    )
  })

  let actual = scaffold.http2_request(headers)

  let expected =
    response.new(200)
    |> response.prepend_header("content-length", "5")
    |> response.set_body(bytes_tree.from_bit_array(<<"20000":utf8>>))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_sends_go_away_on_frames_inside_headers_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let assert [_first, actual] =
    scaffold.http2_requests([
      #(<<>>, headers, <<>>),
      #(
        <<
          0, 0, 1, 1, 1, 0, 0, 0, 3, 0, 0, 0, 8, 6, 0, 0, 0, 0, 0,
          "pingping":utf8,
        >>,
        headers,
        <<>>,
      ),
    ])

  let expected =
    response.new(0)
    |> response.set_body(
      bytes_tree.from_bit_array(<<
        0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1,
      >>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_reads_bodies_ended_by_trailers_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let trailers = [#("x-checksum", "abc")]

  use <- scaffold.open_server(8888, scaffold.default_handler)

  let assert [_first, actual] =
    scaffold.http2_requests([
      #(<<>>, headers, <<>>),
      #(
        <<
          0, 0, 66, 1, 4, 0, 0, 0, 3, 0, 7, ":method":utf8, 4, "POST":utf8, 0, 7,
          ":scheme":utf8, 4, "http":utf8, 0, 10, ":authority":utf8, 16,
          "example.com:8080":utf8, 0, 5, ":path":utf8, 1, "/":utf8, 0, 0, 10, 0,
          0, 0, 0, 0, 3, "0123456789":utf8,
        >>,
        trailers,
        <<>>,
      ),
    ])

  let expected =
    response.new(200)
    |> response.prepend_header("host", "example.com:8080")
    |> response.prepend_header("content-length", "10")
    |> response.set_body(bytes_tree.from_bit_array(<<"0123456789":utf8>>))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_sends_go_away_on_oversized_frames_test() {
  let headers = [
    #(":method", "POST"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let body = <<string.repeat("a", 16_385):utf8>>

  use <- scaffold.open_server(8888, scaffold.default_handler)

  let actual = scaffold.http2_request_with_body(headers, body)

  let expected =
    response.new(0)
    |> response.set_body(
      bytes_tree.from_bit_array(<<
        0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 6,
      >>),
    )

  bitstring_response_should_equal(actual, expected)
}

fn chunk_events_handler(
  events: process.Subject(String),
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req) {
    mist.chunked(
      req,
      response.new(200),
      init: fn(subj) { process.send(subj, Nil) },
      loop: fn(_state, _message, conn) {
        process.send(events, "sending")
        case mist.send_chunk(conn, <<"chunk":utf8>>) {
          Ok(_nil) -> process.send(events, "sent")
          Error(_nil) -> process.send(events, "failed")
        }
        mist.chunk_stop()
      },
    )
  }
}

pub fn it_waits_for_the_window_before_sending_more_chunks_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let events = process.new_subject()

  use <- scaffold.open_server(8888, chunk_events_handler(events))

  let socket = scaffold.http2_open([frame.InitialWindowSize(0)], headers)
  let assert Ok("sending") = process.receive(events, 1000)
  let waiting = process.receive(events, 100)
  scaffold.http2_send(
    socket,
    frame.WindowUpdate(amount: 1000, identifier: frame.stream_identifier(1)),
  )
  let assert Ok("sent") = process.receive(events, 1000)

  assert waiting == Error(Nil)
}

pub fn it_fails_sends_on_reset_streams_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let events = process.new_subject()

  use <- scaffold.open_server(8888, chunk_events_handler(events))

  let socket = scaffold.http2_open([frame.InitialWindowSize(0)], headers)
  let assert Ok("sending") = process.receive(events, 1000)
  scaffold.http2_send(
    socket,
    frame.Termination(
      error: frame.Cancel,
      identifier: frame.stream_identifier(1),
    ),
  )

  assert process.receive(events, 1000) == Ok("failed")
}

pub fn it_stops_the_handler_when_a_stream_is_reset_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let started = process.new_subject()

  use <- scaffold.open_server(8888, fn(_req) {
    process.send(started, process.self())
    process.sleep_forever()
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  })

  let socket = scaffold.http2_open([], headers)
  let assert Ok(handler) = process.receive(started, 1000)
  let monitor = process.monitor(handler)
  scaffold.http2_send(
    socket,
    frame.Header(
      data: frame.Complete(<<0, 10, "x-checksum":utf8, 3, "abc":utf8>>),
      end_stream: True,
      identifier: frame.stream_identifier(1),
      priority: option.None,
    ),
  )

  let stopped =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_down) { Nil })
    |> process.selector_receive(1000)

  assert stopped == Ok(Nil)
}

pub fn it_cancels_sends_that_time_out_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let events = process.new_subject()

  use <- scaffold.open_server_with_send_timeout(
    8888,
    chunk_events_handler(events),
    100,
  )

  let socket = scaffold.http2_open([frame.InitialWindowSize(0)], headers)
  let assert Ok("sending") = process.receive(events, 1000)
  let assert Ok("failed") = process.receive(events, 1000)
  scaffold.http2_send(
    socket,
    frame.WindowUpdate(amount: 1000, identifier: frame.stream_identifier(1)),
  )
  let received =
    scaffold.http2_receive(socket)
    |> list.filter(fn(received) {
      case received {
        frame.Settings(..) | frame.Header(..) -> False
        _frame -> True
      }
    })

  assert received
    == [
      frame.Termination(
        error: frame.Cancel,
        identifier: frame.stream_identifier(1),
      ),
    ]
}

pub fn it_sends_go_away_on_reused_stream_ids_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let assert [_first, actual] =
    scaffold.http2_requests([
      #(<<>>, headers, <<>>),
      #(
        <<
          0, 0, 21, 1, 5, 0, 0, 0, 1, 130, 134, 132, 1, 16,
          "example.com:8080":utf8,
        >>,
        headers,
        <<>>,
      ),
    ])

  let expected =
    response.new(0)
    |> response.set_body(
      bytes_tree.from_bit_array(<<
        0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1,
      >>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_sends_go_away_on_continuation_without_headers_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let assert [_first, actual] =
    scaffold.http2_requests([
      #(<<>>, headers, <<>>),
      #(<<0, 0, 1, 9, 4, 0, 0, 0, 3, 0>>, headers, <<>>),
    ])

  let expected =
    response.new(0)
    |> response.set_body(
      bytes_tree.from_bit_array(<<
        0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1,
      >>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_sends_go_away_on_oversized_header_blocks_test() {
  let headers = [
    #(":method", "GET"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
  ]
  let fragment = <<string.repeat("a", 16_384):utf8>>
  let header =
    frame.encode(frame.Header(
      data: frame.Continued(fragment),
      end_stream: True,
      identifier: frame.stream_identifier(3),
      priority: option.None,
    ))
  let continuation =
    frame.encode(frame.Continuation(
      data: frame.Continued(fragment),
      identifier: frame.stream_identifier(3),
    ))

  use <- scaffold.open_server(8888, scaffold.uri_echo_handler)

  let assert [_first, actual] =
    scaffold.http2_requests([
      #(<<>>, headers, <<>>),
      #(
        <<
          header:bits, continuation:bits, continuation:bits, continuation:bits,
          0, 0, 1, 9, 0, 0, 0, 0, 3, 97,
        >>,
        headers,
        <<>>,
      ),
    ])

  let expected =
    response.new(0)
    |> response.set_body(
      bytes_tree.from_bit_array(<<
        0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 11,
      >>),
    )

  bitstring_response_should_equal(actual, expected)
}

pub fn it_resets_streams_with_wrong_content_length_test() {
  let headers = [
    #(":method", "POST"),
    #(":scheme", "http"),
    #(":authority", "example.com:8080"),
    #(":path", "/"),
    #("content-length", "5"),
  ]

  use <- scaffold.open_server(8888, scaffold.default_handler)

  let actual = scaffold.http2_request_with_body(headers, <<"0123456789":utf8>>)

  let expected =
    response.new(0)
    |> response.set_body(bytes_tree.from_bit_array(<<>>))

  bitstring_response_should_equal(actual, expected)
}
