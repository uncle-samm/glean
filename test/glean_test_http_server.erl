%% A tiny HTTP server for tests: serves the given raw responses, one per
%% connection, in order. Lets the streaming FFI be tested end to end
%% without touching the network.
-module(glean_test_http_server).
-export([serve/1]).

serve(Responses) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Pid = spawn(fun() -> loop(Listen, Responses) end),
    ok = gen_tcp:controlling_process(Listen, Pid),
    Port.

loop(Listen, []) ->
    gen_tcp:close(Listen);
loop(Listen, [Response | Rest]) ->
    {ok, Socket} = gen_tcp:accept(Listen, 5000),
    ok = read_request(Socket, <<>>),
    ok = gen_tcp:send(Socket, Response),
    gen_tcp:close(Socket),
    loop(Listen, Rest).

%% Read headers, then the Content-Length body, and discard them.
read_request(Socket, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Body] ->
            Length = content_length(Head),
            read_body(Socket, Length - byte_size(Body));
        [_] ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 5000),
            read_request(Socket, <<Acc/binary, Data/binary>>)
    end.

read_body(_Socket, Remaining) when Remaining =< 0 -> ok;
read_body(Socket, Remaining) ->
    {ok, Data} = gen_tcp:recv(Socket, 0, 5000),
    read_body(Socket, Remaining - byte_size(Data)).

content_length(Head) ->
    Lines = binary:split(Head, <<"\r\n">>, [global]),
    lists:foldl(
        fun(Line, Acc) ->
            case string:lowercase(Line) of
                <<"content-length:", Value/binary>> ->
                    binary_to_integer(string:trim(Value));
                _ -> Acc
            end
        end,
        0,
        Lines
    ).
