%% Test-only helpers for things Gleam has no function for.
-module(glean_test_ffi).
-export([mailbox_length/0, monotonic_ms/0, without_crash_reports/1]).

%% How many messages wait in the calling process's mailbox.
mailbox_length() ->
    {message_queue_len, Length} = erlang:process_info(self(), message_queue_len),
    Length.

monotonic_ms() ->
    erlang:monotonic_time(millisecond).

%% Run Fun with the logger turned off, so tests that crash a process on
%% purpose don't fill the test output with crash reports.
without_crash_reports(Fun) ->
    #{level := Level} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, none),
    try Fun()
    after
        ok = logger:set_primary_config(level, Level)
    end.
