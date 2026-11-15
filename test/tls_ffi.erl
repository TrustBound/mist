-module(tls_ffi).

-export([write_certificate/1, connect/2]).

write_certificate(Directory) ->
  %% public_key is not loaded until an application that uses it starts.
  {ok, _} = application:ensure_all_started(ssl),
  Options = [{key, {namedCurve, secp256r1}}, {digest, sha256}],
  Chain = #{root => Options, intermediates => [], peer => Options},
  #{server_config := Config} =
    public_key:pkix_test_data(#{server_chain => Chain, client_chain => Chain}),
  Der = proplists:get_value(cert, Config),
  {KeyType, KeyDer} = proplists:get_value(key, Config),
  CertFile = filename:join(Directory, "cert.pem"),
  KeyFile = filename:join(Directory, "key.pem"),
  ok = filelib:ensure_dir(CertFile),
  ok =
    file:write_file(
      CertFile,
      public_key:pem_encode([{'Certificate', Der, not_encrypted}])
    ),
  ok =
    file:write_file(
      KeyFile,
      public_key:pem_encode([{KeyType, KeyDer, not_encrypted}])
    ),
  {CertFile, KeyFile}.

connect(Port, Protocols) ->
  {ok, _} = application:ensure_all_started(ssl),
  Options =
    [binary,
     {active, false},
     {verify, verify_none},
     {alpn_advertised_protocols, Protocols}],
  ssl:connect("localhost", Port, Options, 5000).
