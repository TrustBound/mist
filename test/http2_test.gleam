import gleam/bytes_tree
import gleam/http/response
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
