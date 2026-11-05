%% Streaming HTTP POST for Server-Sent Events, using OTP's httpc.
%%
%% This is glean's only FFI. gleam_httpc returns whole responses, and the
%% Gleam SSE packages pull in a second HTTP stack, so the streaming part is
%% done here with httpc's `{stream, self}` mode: body chunks arrive as
%% messages to the calling process, which `next/2` turns into values the
%% Gleam side can match on. Parsing SSE happens in Gleam
%% (glean/providers/sse.gleam).
-module(glean_http_stream_ffi).
-export([start/4, next/2, cancel/1]).

%% Start the request. Returns {ok, RequestId} or {error, Reason}.
start(Url, Headers, Body, ConnectTimeoutMs) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    Request = {
        binary_to_list(Url),
        [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers],
        "application/json",
        Body
    },
    HttpOptions = [
        {ssl, ssl_options()},
        {autoredirect, false},
        {connect_timeout, ConnectTimeoutMs}
    ],
    Options = [{sync, false}, {stream, self}, {body_format, binary}],
    case httpc:request(post, Request, HttpOptions, Options) of
        {ok, RequestId} -> {ok, RequestId};
        {error, Reason} -> {error, describe(Reason)}
    end.

%% Wait up to TimeoutMs for the next message about RequestId.
next(RequestId, TimeoutMs) ->
    receive
        {http, {RequestId, stream_start, _Headers}} -> started;
        {http, {RequestId, stream, Chunk}} -> {chunk, Chunk};
        {http, {RequestId, stream_end, _Headers}} -> finished;
        {http, {RequestId, {{_Version, Status, _Reason}, RespHeaders, RespBody}}} ->
            {status, Status, retry_after(RespHeaders), to_binary(RespBody)};
        {http, {RequestId, {error, Reason}}} -> {request_failed, describe(Reason)}
    after TimeoutMs ->
        timed_out
    end.

%% Cancel the request and drop any of its messages already in the mailbox,
%% so a stopped stream leaves nothing behind for the calling process.
cancel(RequestId) ->
    _ = httpc:cancel_request(RequestId),
    flush(RequestId).

flush(RequestId) ->
    receive
        {http, {RequestId, _}} -> flush(RequestId);
        {http, {RequestId, _, _}} -> flush(RequestId)
    after 0 ->
        nil
    end.

ssl_options() ->
    [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

%% The Retry-After header as {some, Binary} or none (a Gleam Option).
retry_after(Headers) ->
    case lists:keyfind("retry-after", 1, Headers) of
        {_, Value} -> {some, unicode:characters_to_binary(Value)};
        false -> none
    end.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> iolist_to_binary(L).

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
