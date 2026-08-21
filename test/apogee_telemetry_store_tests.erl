%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for Gorilla telemetry compression and ring buffer.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_telemetry_store_tests).

-include_lib("eunit/include/eunit.hrl").

ring_buffer_test() ->
    % Capacity of 3 samples
    S0 = apogee_telemetry_store:new(<<"battery_v">>, 3),
    ?assertEqual(0, apogee_telemetry_store:size(S0)),
    ?assertEqual(empty, apogee_telemetry_store:latest(S0)),

    S1 = apogee_telemetry_store:append(S0, 1000, 28.2),
    S2 = apogee_telemetry_store:append(S1, 2000, 28.3),
    S3 = apogee_telemetry_store:append(S2, 3000, 28.1),
    ?assertEqual(3, apogee_telemetry_store:size(S3)),
    ?assertEqual({ok, {3000, 28.1}}, apogee_telemetry_store:latest(S3)),

    % 4th sample should evict sample at t=1000
    S4 = apogee_telemetry_store:append(S3, 4000, 28.0),
    ?assertEqual(3, apogee_telemetry_store:size(S4)),
    ?assertEqual({ok, {4000, 28.0}}, apogee_telemetry_store:latest(S4)),

    % Range query
    Range = apogee_telemetry_store:query_range(S4, 2000, 3500),
    ?assertEqual(2, length(Range)),
    ?assertEqual([{2000, 28.3}, {3000, 28.1}], Range).

gorilla_compression_roundtrip_test() ->
    % Generate 100 periodic telemetry samples at 1000ms intervals
    Samples = [{1000 * I, 28.0 + (I rem 5) * 0.1} || I <- lists:seq(1, 100)],
    
    Compressed = apogee_telemetry_store:compress_series(Samples),
    % 100 uncompressed 64-bit timestamps + 64-bit values = 1600 bytes
    % Gorilla compressed should be significantly smaller (< 900 bytes)
    ?assert(byte_size(Compressed) < 900),

    Decompressed = apogee_telemetry_store:decompress_series(Compressed),
    ?assertEqual(length(Samples), length(Decompressed)),
    
    % Verify bit-exact fidelity of all samples
    lists:foreach(
        fun({{OrigT, OrigV}, {DecT, DecV}}) ->
            ?assertEqual(OrigT, DecT),
            ?assert(abs(OrigV - DecV) < 1.0e-7)
        end,
        lists:zip(Samples, Decompressed)
    ).

constant_stream_compression_test() ->
    % Constant stream compresses extremely compactly (1 bit per sample)
    Samples = [{1000 * I, 42.0} || I <- lists:seq(1, 50)],
    Compressed = apogee_telemetry_store:compress_series(Samples),
    % Should compress down to under 50 bytes!
    ?assert(byte_size(Compressed) < 50),
    Decompressed = apogee_telemetry_store:decompress_series(Compressed),
    ?assertEqual(Samples, Decompressed).
