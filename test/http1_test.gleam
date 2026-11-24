import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response, Response}
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import gleam/uri
import glisten/socket
import glisten/tcp
import mist
import scaffold.{
  bitstring_response_should_equal, make_request, string_response_should_equal,
}

pub type Fixture {
  Foreach
  Setup
}

pub type Instantiator {
  Spawn
  Timeout
  Inorder
  Inparallel
}

fn get_default_response() -> Response(BytesTree) {
  response.new(200)
  |> response.prepend_header("user-agent", "hackney/1.25.0")
  |> response.prepend_header("host", "localhost:8888")
  |> response.prepend_header("content-type", "application/octet-stream")
  |> response.prepend_header("content-length", "13")
  |> response.prepend_header("connection", "keep-alive")
  |> response.set_body(bytes_tree.from_bit_array(<<"hello, world!":utf8>>))
}

pub fn it_echoes_with_data_test() {
  let req = make_request("/", "hello, world!")
  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  string_response_should_equal(resp, get_default_response())
}

pub fn it_supports_large_header_fields_test() {
  let big_request =
    make_request("/", "")
    |> request.prepend_header(
      "user-agent",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:100.0) Gecko/20100101 Firefox/100.0",
    )
    |> request.prepend_header(
      "accept",
      "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    )
    |> request.prepend_header("accept-language", "en-GB,en;q=0.5")
    |> request.prepend_header("accept-encoding", "gzip, deflate, br")
    |> request.prepend_header("dnt", "1")
    |> request.prepend_header("connection", "keep-alive")
    |> request.prepend_header(
      "cookie",
      "csrftoken=redacted; firstVisit=redacted; sessionid=redacted; ph_GO532nkfIyRbVh8r-ts579S0ibtS4N7F8q1u7qy9FyY_posthog=%7B%22distinct_id%22%3A%22development-309%22%2C%22%24device_id%22%3A%2217f2233bb99e1f-0c5659974edb81-455a69-7e9000-17f2233bb9a8d6%22%2C%22%24user_id%22%3A%22development-309%22%2C%22%24initial_referrer%22%3A%22http%3A%2F%2Flocalhost%3A8000%2F%22%2C%22%24initial_referring_domain%22%3A%22localhost%3A8000%22%2C%22%24referrer%22%3A%22http%3A%2F%2Flocalhost%3A8000%2Fin-house-legal%2Fquery%2Fagreements%2F%22%2C%22%24referring_domain%22%3A%22localhost%3A8000%22%2C%22%24sesid%22%3A%5B1653655256592%2C%221810588be10b6a-070d87da3b86a88-402e2c34-4b9600-1810588be11e5a%22%5D%2C%22%24session_recording_enabled_server_side%22%3Afalse%2C%22%24active_feature_flags%22%3A%5B%5D%2C%22%24enabled_feature_flags%22%3A%7B%7D%7D; uid=SFMyNTY.MQ.3UIahins3fngCF2xLC2znGYe_xSbmG_bRdx0YSTwt_c; sessionid-3GDYO=redacted; CSRF-Token-3GDYO=tJoio2hbqKggK7fHZgFZyWVPnA7wySLf; CSRF-Token-CKIKR=Xc75SKFZS9qDDgLKD26rLYJtgtiH7Gja; sessionid-CKIKR=eikQox9V6M9sQwRnLHLj9HE5b2zRtopN; sessionid-NHOUY=wV9rHjEGqHzSpTfVrtMw3SkSUfV99YWq; CSRF-Token-NHOUY=ePu9N5NuRQSS6bwRfvrRTiSNdKjJV9Ro",
    )
    |> request.prepend_header("upgrade-insecure-requests", "")
    |> request.prepend_header("sec-fetch-dest", "1")
    |> request.prepend_header("sec-fetch-mode", "document")
    |> request.prepend_header("sec-fetch-site", "navigate")
    |> request.prepend_header("sec-fetch-user", "none")
    |> request.prepend_header("pragma", "no-cache")
    |> request.prepend_header("cache-control", "no-cache")

  let expected =
    Response(..get_default_response(), headers: big_request.headers)
    |> response.prepend_header("content-type", "application/octet-stream")
    |> response.prepend_header("content-length", "0")
    |> response.prepend_header("host", "localhost:8888")
    |> response.set_body(bytes_tree.from_bit_array(<<>>))

  let resp = scaffold.with_server(8888, scaffold.default_handler, big_request)

  string_response_should_equal(resp, expected)
}

pub fn it_supports_patch_requests_test() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Patch)

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  string_response_should_equal(resp, get_default_response())
}

pub fn it_rejects_large_requests_test() {
  let req =
    string.repeat("a", 4_000_001)
    |> make_request("/", _)

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  let expected =
    response.new(413)
    |> response.set_body(bytes_tree.from_bit_array(<<>>))
    |> response.prepend_header("content-length", "0")
    |> response.prepend_header("connection", "close")

  string_response_should_equal(resp, expected)
}

@external(erlang, "hackney_ffi", "stream_request")
fn stream_request(
  method method: http.Method,
  path path: String,
  headers headers: List(#(String, String)),
  body body: BitArray,
) -> Result(#(Int, List(#(String, String)), BitArray), Nil)

pub fn it_supports_chunked_encoding_test() {
  let req =
    string.repeat("a", 10_000)
    |> bit_array.from_string
    |> make_request("/", _)
    |> request.set_method(http.Post)
    |> request.prepend_header("transfer-encoding", "chunked")

  let path =
    req
    |> request.to_uri
    |> uri.to_string

  use <- scaffold.open_server(8888, scaffold.default_handler)

  let assert Ok(#(status, headers, body)) =
    stream_request(req.method, path, req.headers, req.body)
  let actual = response.Response(status, headers, body)

  let expected =
    response.new(200)
    |> response.prepend_header("user-agent", "hackney/1.25.0")
    |> response.prepend_header("host", "localhost:8888")
    |> response.prepend_header("connection", "keep-alive")
    |> response.prepend_header("content-length", "10000")
    |> response.set_body(bytes_tree.from_string(string.repeat("a", 10_000)))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_supports_query_parameters_test() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Get)
    |> request.set_query([
      #("something", "123"),
      #("another", "true"),
      #("a-complicated-one", "is the thing"),
    ])

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  let expected =
    get_default_response()
    |> response.set_header("content-length", "61")
    |> response.set_body(
      bytes_tree.from_bit_array(<<
        "something=123&another=true&a-complicated-one=is%20the%20thing":utf8,
      >>),
    )

  string_response_should_equal(resp, expected)
}

pub fn it_handles_query_parameters_with_question_mark_test() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Get)
    |> request.set_query([#("?", "123")])

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  let expected =
    get_default_response()
    |> response.set_header("content-length", "7")
    |> response.set_body(bytes_tree.from_bit_array(<<"%3F=123":utf8>>))

  string_response_should_equal(resp, expected)
}

pub fn it_doesnt_mangle_query_test() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Get)
  let req = request.Request(..req, query: Some("test"))

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  let expected =
    get_default_response()
    |> response.set_header("content-length", "4")
    |> response.set_body(bytes_tree.from_bit_array(<<"test":utf8>>))

  string_response_should_equal(resp, expected)
}

pub fn it_supports_expect_continue_header_test() {
  let req =
    string.repeat("a", 1000)
    |> make_request("/", _)
    |> request.set_method(http.Post)
    |> request.prepend_header("expect", "100-continue")

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  let expected_body =
    string.repeat("a", 1000)
    |> bytes_tree.from_string

  let expected =
    response.new(200)
    |> response.prepend_header("user-agent", "hackney/1.25.0")
    |> response.prepend_header("host", "localhost:8888")
    |> response.prepend_header("connection", "keep-alive")
    |> response.prepend_header("content-type", "application/octet-stream")
    |> response.prepend_header("content-length", "1000")
    |> response.prepend_header("expect", "100-continue")
    |> response.set_body(expected_body)

  string_response_should_equal(resp, expected)
}

pub fn it_sends_back_chunked_responses_test() {
  let req =
    string.repeat("a", 1000)
    |> make_request("/", _)
    |> request.set_host("localhost:8888")
    |> request.set_method(http.Post)

  let handler = scaffold.chunked_echo_server(100)

  let resp = scaffold.with_server(8888, handler, req)

  assert resp.status == 200
  assert resp.body == string.repeat("a", 1000)
}

pub fn it_times_out_slow_request_bodies_test() {
  let read = process.new_subject()

  use <- scaffold.start_server(
    mist.new(fn(req) {
      process.send(read, mist.read_body(req, 1000))
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    })
    |> mist.port(8888)
    |> mist.with_read_timeout(200),
  )

  let socket =
    scaffold.http1_open(<<
      "POST / HTTP/1.1\r\nhost: localhost:8888\r\ncontent-length: 6\r\n\r\n012":utf8,
    >>)
  process.sleep(400)
  let _sent = scaffold.http1_send(socket, <<"345":utf8>>)
  let assert Ok(result) = process.receive(read, 1000)

  assert result == Error(mist.MalformedBody)
}

fn stop_after_one_event_handler(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  mist.server_sent_events(
    req,
    response.new(200),
    init: fn(subj) { process.send(subj, "only") },
    loop: fn(state, message, conn) {
      let assert Ok(_nil) =
        mist.send_event(conn, mist.event(string_tree.from_string(message)))
      let _state = state
      actor.stop()
    },
  )
}

pub fn it_ends_server_sent_events_without_an_error_response_test() {
  use <- scaffold.start_server(
    mist.new(stop_after_one_event_handler)
    |> mist.port(8888),
  )

  let responses =
    list.repeat(Nil, 30)
    |> list.map(fn(_nil) {
      scaffold.http1_open(<<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n":utf8>>)
      |> scaffold.http1_receive_chunked(<<>>)
    })

  let error_responses =
    list.filter(responses, fn(received) {
      received
      |> bit_array.to_string
      |> result.unwrap("")
      |> string.contains("HTTP/1.1 500")
    })

  assert error_responses == []
}

pub fn it_keeps_the_connection_open_after_server_sent_events_test() {
  use <- scaffold.start_server(
    mist.new(stop_after_one_event_handler)
    |> mist.port(8888),
  )
  let request = <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n":utf8>>
  let socket = scaffold.http1_open(request)
  let first = scaffold.http1_receive_chunked(socket, <<>>)

  let assert Ok(_sent) = scaffold.http1_send(socket, request)
  let second = scaffold.http1_receive_chunked(socket, <<>>)

  assert second == first
  assert second
    |> bit_array.to_string
    |> result.unwrap("")
    |> string.ends_with("\r\n\r\nC\r\ndata: only\n\n\r\n0\r\n\r\n")
}

fn stop_after_one_chunk_handler(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  mist.chunked(
    req,
    response.new(200),
    init: fn(subj) { process.send(subj, <<"only":utf8>>) },
    loop: fn(_state, message, conn) {
      let assert Ok(_nil) = mist.send_chunk(conn, message)
      mist.chunk_stop()
    },
  )
}

pub fn it_ends_chunked_responses_without_an_error_response_test() {
  use <- scaffold.start_server(
    mist.new(stop_after_one_chunk_handler)
    |> mist.port(8888),
  )

  let responses =
    list.repeat(Nil, 30)
    |> list.map(fn(_nil) {
      scaffold.http1_open(<<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n":utf8>>)
      |> scaffold.http1_receive_chunked(<<>>)
    })
  let error_responses =
    list.filter(responses, fn(received) {
      received
      |> bit_array.to_string
      |> result.unwrap("")
      |> string.contains("HTTP/1.1 500")
    })

  assert error_responses == []
}

pub fn it_keeps_the_connection_open_after_a_chunked_response_test() {
  use <- scaffold.start_server(
    mist.new(stop_after_one_chunk_handler)
    |> mist.port(8888),
  )
  let request = <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n":utf8>>
  let socket = scaffold.http1_open(request)
  let first = scaffold.http1_receive_chunked(socket, <<>>)

  let assert Ok(_sent) = scaffold.http1_send(socket, request)
  let second = scaffold.http1_receive_chunked(socket, <<>>)

  assert second == first
  assert second
    |> bit_array.to_string
    |> result.unwrap("")
    |> string.ends_with("4\r\nonly\r\n0\r\n\r\n")
}

fn close_after_one_chunk_handler(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  mist.chunked(
    req,
    response.new(200) |> response.set_header("connection", "close"),
    init: fn(subj) { process.send(subj, <<"only":utf8>>) },
    loop: fn(_state, message, conn) {
      let assert Ok(_nil) = mist.send_chunk(conn, message)
      mist.chunk_stop()
    },
  )
}

pub fn it_closes_the_connection_after_a_chunked_response_that_asks_for_it_test() {
  use <- scaffold.start_server(
    mist.new(close_after_one_chunk_handler)
    |> mist.port(8888),
  )
  let socket =
    scaffold.http1_open(<<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n":utf8>>)

  // The server waits up to 5 seconds for the client to close first
  assert scaffold.http1_closes(socket, 6000)
}

fn abort_after_one_chunk_handler(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  mist.chunked(
    req,
    response.new(200),
    init: fn(subj) { process.send(subj, <<"only":utf8>>) },
    loop: fn(_state, message, conn) {
      let assert Ok(_nil) = mist.send_chunk(conn, message)
      mist.chunk_stop_abnormal("stopped early")
    },
  )
}

pub fn it_closes_the_connection_when_a_chunked_response_aborts_test() {
  use <- scaffold.start_server(
    mist.new(abort_after_one_chunk_handler)
    |> mist.port(8888),
  )
  let socket =
    scaffold.http1_open(<<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n":utf8>>)

  assert scaffold.http1_closes(socket, 1000)
}

fn selector_event_handler(
  others: process.Subject(process.Subject(String)),
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req) {
    mist.server_sent_events_with_selector(
      req,
      response.new(200),
      init: fn(_subj) {
        let other = process.new_subject()
        process.send(others, other)
        #(Nil, Some(process.new_selector() |> process.select(other)))
      },
      loop: fn(_state, message, conn) {
        let assert Ok(_nil) =
          mist.send_event(conn, mist.event(string_tree.from_string(message)))
        actor.stop()
      },
    )
  }
}

pub fn it_sends_server_sent_events_from_the_init_selector_test() {
  let others = process.new_subject()

  use <- scaffold.start_server(
    mist.new(selector_event_handler(others))
    |> mist.port(8888),
  )

  let socket =
    scaffold.http1_open(<<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n":utf8>>)
  let assert Ok(other) = process.receive(others, 1000)
  process.send(other, "from the selector")
  let received =
    scaffold.http1_receive_chunked(socket, <<>>)
    |> bit_array.to_string
    |> result.unwrap("")

  assert string.contains(received, "data: from the selector\n\n")
}

fn short_handler(
  _req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
}

const close_request = <<
  "GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n":utf8,
>>

fn says_close_then_closes(socket) -> Bool {
  let says_close =
    scaffold.http1_receive(socket)
    |> bit_array.to_string
    |> result.unwrap("")
    |> string.contains("\r\nconnection: close\r\n")

  says_close && scaffold.http1_closes(socket, 2000)
}

pub fn it_closes_the_connection_when_the_request_asks_for_it_test() {
  use <- scaffold.start_server(
    mist.new(short_handler)
    |> mist.port(8888),
  )

  assert says_close_then_closes(scaffold.http1_open(close_request))
}

pub fn it_reads_the_close_option_in_any_case_and_in_a_list_test() {
  use <- scaffold.start_server(
    mist.new(short_handler)
    |> mist.port(8888),
  )
  let request = <<
    "GET / HTTP/1.1\r\nhost: localhost\r\nConnection: TE, Close\r\n\r\n":utf8,
  >>

  assert says_close_then_closes(scaffold.http1_open(request))
}

pub fn it_closes_after_a_chunked_response_when_the_request_asks_for_it_test() {
  use <- scaffold.start_server(
    mist.new(stop_after_one_chunk_handler)
    |> mist.port(8888),
  )

  assert says_close_then_closes(scaffold.http1_open(close_request))
}

pub fn it_closes_after_server_sent_events_when_the_request_asks_for_it_test() {
  use <- scaffold.start_server(
    mist.new(stop_after_one_event_handler)
    |> mist.port(8888),
  )

  assert says_close_then_closes(scaffold.http1_open(close_request))
}

fn limited_body_handler(
  read: process.Subject(Result(Int, mist.ReadError)),
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req) {
    let result =
      mist.read_body(req, 1000)
      |> result.map(fn(req) { bit_array.byte_size(req.body) })
    process.send(read, result)
    case result {
      Ok(_size) -> response.new(200)
      Error(_error) ->
        response.new(413)
        |> response.set_header("connection", "close")
    }
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

const chunked_head = "POST / HTTP/1.1\r\nhost: localhost:8888\r\ntransfer-encoding: chunked\r\n\r\n"

pub fn it_rejects_a_chunked_body_one_byte_over_the_limit_test() {
  let read = process.new_subject()
  use <- scaffold.start_server(
    mist.new(limited_body_handler(read))
    |> mist.port(8888),
  )
  let body =
    chunked_head
    <> "1F4\r\n"
    <> string.repeat("a", 500)
    <> "\r\n1F5\r\n"
    <> string.repeat("a", 501)
    <> "\r\n0\r\n\r\n"
  let socket = scaffold.http1_open(bit_array.from_string(body))

  assert process.receive(read, 1000) == Ok(Error(mist.ExcessBody))
  assert scaffold.http1_receive(socket)
    |> bit_array.to_string
    |> result.unwrap("")
    |> string.starts_with("HTTP/1.1 413")
}

pub fn it_reads_a_chunked_body_at_the_limit_test() {
  let read = process.new_subject()
  use <- scaffold.start_server(
    mist.new(limited_body_handler(read))
    |> mist.port(8888),
  )
  let body =
    chunked_head
    <> "1F4\r\n"
    <> string.repeat("a", 500)
    <> "\r\n1F4\r\n"
    <> string.repeat("a", 500)
    <> "\r\n0\r\n\r\n"
  let socket = scaffold.http1_open(bit_array.from_string(body))

  assert process.receive(read, 1000) == Ok(Ok(1000))
  assert scaffold.http1_receive(socket)
    |> bit_array.to_string
    |> result.unwrap("")
    |> string.starts_with("HTTP/1.1 200")
}

pub fn it_rejects_a_large_chunk_without_reading_it_test() {
  let read = process.new_subject()
  use <- scaffold.start_server(
    mist.new(limited_body_handler(read))
    |> mist.port(8888),
  )
  // The chunk says 100,000 bytes, but only 10 are sent, and the connection
  // stays open
  let _socket =
    scaffold.http1_open(<<chunked_head:utf8, "186A0\r\naaaaaaaaaa":utf8>>)

  assert process.receive(read, 1000) == Ok(Error(mist.ExcessBody))
}

pub fn it_does_not_serve_the_unread_chunks_as_a_request_test() {
  let read = process.new_subject()
  use <- scaffold.start_server(
    mist.new(limited_body_handler(read))
    |> mist.port(8888),
  )
  let socket = scaffold.http1_open(<<chunked_head:utf8, "3E9\r\n":utf8>>)
  assert process.receive(read, 1000) == Ok(Error(mist.ExcessBody))
  assert scaffold.http1_receive(socket)
    |> bit_array.to_string
    |> result.unwrap("")
    |> string.starts_with("HTTP/1.1 413")

  // The rest of the chunk looks like a request
  let _sent =
    scaffold.http1_send(socket, <<
      "GET / HTTP/1.1\r\nhost: localhost\r\n\r\n":utf8,
    >>)

  // The next thing on the connection is its end, not a response
  assert tcp.receive_timeout(socket, 0, 2000) == Error(socket.Closed)
}

fn read_stream(
  consume: fn(Int) -> Result(mist.Chunk, mist.ReadError),
) -> Result(Nil, mist.ReadError) {
  case consume(1000) {
    Ok(mist.Chunk(_data, next)) -> read_stream(next)
    Ok(mist.Done) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

pub fn it_streams_an_invalid_chunk_size_as_an_error_at_once_test() {
  let read = process.new_subject()
  use <- scaffold.start_server(
    mist.new(fn(req) {
      process.send(read, result.try(mist.stream(req), read_stream))
      response.new(400)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    })
    |> mist.port(8888),
  )
  // The second chunk size is not hexadecimal, and the connection stays open
  let _socket =
    scaffold.http1_open(<<chunked_head:utf8, "5\r\nhello\r\nzz\r\n":utf8>>)

  assert process.receive(read, 1000) == Ok(Error(mist.MalformedBody))
}

const smuggled_request = "GET /x HTTP/1.1\r\nhost: localhost\r\n\r\n"

// Sends `head`, reads the response, and then sends a request on the same
// connection as the rest of the first body. The server must not answer it
fn does_not_answer_the_rest_of_the_body(
  handler: fn(request.Request(mist.Connection)) ->
    response.Response(mist.ResponseData),
  head: String,
) -> Nil {
  use <- scaffold.start_server(
    mist.new(handler)
    |> mist.port(8888),
  )
  let socket = scaffold.http1_open(bit_array.from_string(head))
  assert scaffold.http1_receive(socket)
    |> bit_array.to_string
    |> result.unwrap("")
    |> string.starts_with("HTTP/1.1 ")
  let _sent =
    scaffold.http1_send(socket, bit_array.from_string(smuggled_request))

  assert tcp.receive_timeout(socket, 0, 2000) == Error(socket.Closed)
}

fn answer_without_close(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case mist.read_body(req, 10) {
    Ok(_req) -> response.new(200)
    Error(_error) -> response.new(413)
  }
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

pub fn it_closes_after_an_unread_content_length_body_test() {
  does_not_answer_the_rest_of_the_body(
    answer_without_close,
    "POST / HTTP/1.1\r\nhost: localhost\r\ncontent-length: 36\r\n\r\n",
  )
}

pub fn it_closes_after_an_unread_chunked_body_test() {
  does_not_answer_the_rest_of_the_body(
    answer_without_close,
    chunked_head <> "24\r\n",
  )
}

pub fn it_closes_when_the_handler_does_not_read_the_body_test() {
  does_not_answer_the_rest_of_the_body(
    short_handler,
    "POST / HTTP/1.1\r\nhost: localhost\r\ncontent-length: 36\r\n\r\n",
  )
}

pub fn it_closes_when_a_stream_reader_stops_early_test() {
  does_not_answer_the_rest_of_the_body(
    fn(req) {
      let assert Ok(consume) = mist.stream(req)
      let assert Ok(mist.Chunk(<<"aaaaa":utf8>>, _next)) = consume(5)
      short_handler(req)
    },
    "POST / HTTP/1.1\r\nhost: localhost\r\ncontent-length: 41\r\n\r\naaaaa",
  )
}

pub fn it_does_not_read_trailers_as_a_request_test() {
  does_not_answer_the_rest_of_the_body(
    answer_without_close,
    chunked_head <> "5\r\nhello\r\n0\r\n",
  )
}

fn read_body_handler(
  read: process.Subject(Result(Int, mist.ReadError)),
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req) {
    process.send(
      read,
      mist.read_body(req, 1_000_000)
        |> result.map(fn(req) { bit_array.byte_size(req.body) }),
    )
    short_handler(req)
  }
}

pub fn it_refuses_an_endless_chunk_size_line_test() {
  let read = process.new_subject()
  use <- scaffold.start_server(
    mist.new(read_body_handler(read))
    |> mist.port(8888),
  )
  let socket = scaffold.http1_open(bit_array.from_string(chunked_head))
  let _sent = scaffold.http1_send(socket, <<string.repeat("1", 2000):utf8>>)

  assert process.receive(read, 1000) == Ok(Error(mist.MalformedBody))
}

pub fn it_refuses_a_chunk_without_its_line_end_test() {
  let read = process.new_subject()
  use <- scaffold.start_server(
    mist.new(read_body_handler(read))
    |> mist.port(8888),
  )
  let socket =
    scaffold.http1_open(bit_array.from_string(chunked_head <> "5\r\nhelloXX"))
  let _sent = scaffold.http1_send(socket, <<string.repeat("X", 2000):utf8>>)

  assert process.receive(read, 1000) == Ok(Error(mist.MalformedBody))
}

pub fn it_streams_an_endless_chunk_size_line_as_an_error_test() {
  let read = process.new_subject()
  use <- scaffold.start_server(
    mist.new(fn(req) {
      process.send(read, result.try(mist.stream(req), read_stream))
      short_handler(req)
    })
    |> mist.port(8888),
  )
  let socket = scaffold.http1_open(bit_array.from_string(chunked_head))
  let _sent = scaffold.http1_send(socket, <<string.repeat("1", 2000):utf8>>)

  assert process.receive(read, 1000) == Ok(Error(mist.MalformedBody))
}

fn receives_ok(socket) -> Bool {
  scaffold.http1_receive(socket)
  |> bit_array.to_string
  |> result.unwrap("")
  |> string.starts_with("HTTP/1.1 200")
}

pub fn it_keeps_the_connection_after_a_body_read_in_full_test() {
  let read = process.new_subject()
  use <- scaffold.start_server(
    mist.new(read_body_handler(read))
    |> mist.port(8888),
  )
  let get = <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n":utf8>>
  let socket = scaffold.http1_open(get)
  assert receives_ok(socket)
  let assert Ok(_sent) = scaffold.http1_send(socket, get)
  assert receives_ok(socket)
  let assert Ok(_sent) =
    scaffold.http1_send(socket, <<
      "POST / HTTP/1.1\r\nhost: localhost\r\ncontent-length: 5\r\n\r\nhello":utf8,
    >>)
  assert receives_ok(socket)
  let assert Ok(_sent) = scaffold.http1_send(socket, get)
  assert receives_ok(socket)
  let assert Ok(_sent) =
    scaffold.http1_send(
      socket,
      bit_array.from_string(chunked_head <> "5\r\nhello\r\n0\r\n\r\n"),
    )
  assert receives_ok(socket)
  let assert Ok(_sent) = scaffold.http1_send(socket, get)
  assert receives_ok(socket)
  assert process.receive(read, 1000) == Ok(Ok(0))
  assert process.receive(read, 1000) == Ok(Ok(0))
  assert process.receive(read, 1000) == Ok(Ok(5))
}
