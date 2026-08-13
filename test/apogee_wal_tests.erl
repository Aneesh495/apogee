%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for write-ahead log (WAL) and crash recovery.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_wal_tests).

-include_lib("eunit/include/eunit.hrl").

wal_append_and_recovery_test() ->
    Dir = "/tmp/apogee_wal_test_" ++ integer_to_list(erlang:system_time(microsecond)),
    {ok, Pid} = apogee_wal:start_link(Dir, [{sync, false}]),
    
    {ok, 1} = apogee_wal:append(Pid, 1, <<"packet_001">>),
    {ok, 2} = apogee_wal:append(Pid, 1, <<"packet_002">>),
    {ok, 3} = apogee_wal:checkpoint(Pid),
    {ok, 4} = apogee_wal:append(Pid, 1, <<"packet_003">>),

    {ok, Replayed} = apogee_wal:replay(Pid),
    ?assertEqual(4, length(Replayed)),
    ?assertEqual({1, 1, <<"packet_001">>}, lists:nth(1, Replayed)),
    ?assertEqual({2, 1, <<"packet_002">>}, lists:nth(2, Replayed)),
    ?assertEqual({3, 2, <<>>}, lists:nth(3, Replayed)),
    ?assertEqual({4, 1, <<"packet_003">>}, lists:nth(4, Replayed)),

    % Close server
    ok = apogee_wal:close(Pid),

    % Re-open to simulate crash recovery
    {ok, Pid2} = apogee_wal:start_link(Dir, [{sync, false}]),
    {ok, Replayed2} = apogee_wal:replay(Pid2),
    ?assertEqual(4, length(Replayed2)),

    % Next append should be LSN 5
    {ok, 5} = apogee_wal:append(Pid2, 1, <<"packet_004">>),
    
    % Truncate before LSN 3
    ok = apogee_wal:truncate_before(Pid2, 3),
    {ok, Truncated} = apogee_wal:replay(Pid2),
    ?assertEqual(3, length(Truncated)),
    ?assertEqual(3, element(1, lists:nth(1, Truncated))),
    ?assertEqual(4, element(1, lists:nth(2, Truncated))),
    ?assertEqual(5, element(1, lists:nth(3, Truncated))),

    ok = apogee_wal:close(Pid2),
    os:cmd("rm -rf " ++ Dir).

wal_corruption_recovery_test() ->
    Dir = "/tmp/apogee_wal_corrupt_" ++ integer_to_list(erlang:system_time(microsecond)),
    {ok, Pid} = apogee_wal:start_link(Dir, [{sync, false}]),
    {ok, 1} = apogee_wal:append(Pid, 1, <<"valid_data">>),
    ok = apogee_wal:close(Pid),

    % Append corrupted bytes to file
    FilePath = filename:join(Dir, "apogee_journal.wal"),
    {ok, Fd} = file:open(FilePath, [append, binary]),
    ok = file:write(Fd, <<16#57, 16#41, 16#4C, 16#31, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 10, "garbage", 16#DE, 16#AD, 16#BE, 16#EF>>),
    ok = file:close(Fd),

    % Recovering should salvage valid record 1 and drop corrupted record
    {ok, Pid2} = apogee_wal:start_link(Dir, [{sync, false}]),
    {ok, Replayed} = apogee_wal:replay(Pid2),
    ?assertEqual(1, length(Replayed)),
    ?assertEqual({1, 1, <<"valid_data">>}, hd(Replayed)),

    ok = apogee_wal:close(Pid2),
    os:cmd("rm -rf " ++ Dir).
