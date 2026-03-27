import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import logging
import mist

pub fn main() {
  logging.configure()
  logging.set_level(logging.Debug)

  let assert Ok(_server) =
    fn(_req) {
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
    |> mist.new()
    |> mist.with_ipv6()
    |> mist.with_tls(certfile: "localhost.crt", keyfile: "localhost.key")
    |> mist.start

  process.sleep_forever()
}
