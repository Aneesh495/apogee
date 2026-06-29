%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_scrambler
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_scrambler_tests).
-include_lib("eunit/include/eunit.hrl").

scramble_involution_test() ->
    Data = <<"ASTRONOMICAL_TELEMETRY_PACKET_BURST_COSMIC_RAY_TEST">>,
    Scrambled = apogee_scrambler:scramble(Data),
    ?assertNotEqual(Data, Scrambled),
    Descrambled = apogee_scrambler:descramble(Scrambled),
    ?assertEqual(Data, Descrambled).

sync_marker_test() ->
    Payload = <<"TELEMETRY_FRAME_BINARY">>,
    WithASM = apogee_scrambler:attach_sync_marker(Payload),
    ?assertEqual(4 + byte_size(Payload), byte_size(WithASM)),
    {ok, Stripped} = apogee_scrambler:strip_sync_marker(WithASM),
    ?assertEqual(Payload, Stripped).

find_sync_marker_test() ->
    Prefix = <<"NOISE_GARBAGE_1234">>,
    ASM = apogee_scrambler:sync_marker(),
    Suffix = <<"MORE_GARBAGE">>,
    Stream = <<Prefix/binary, ASM/binary, Suffix/binary>>,
    Offsets = apogee_scrambler:find_sync_markers(Stream),
    ?assertEqual([byte_size(Prefix)], Offsets).

fuzzy_sync_marker_test() ->
    %% Corrupt 2 bits of ASM
    <<B1:8, B2:8, B3:8, B4:8>> = apogee_scrambler:sync_marker(),
    CorruptedASM = <<(B1 bxor 1):8, B2:8, (B3 bxor 2):8, B4:8>>,
    Stream = <<"NOISE", CorruptedASM/binary, "DATA">>,
    ?assertEqual([], apogee_scrambler:find_sync_markers(Stream, 0)),
    ?assertEqual([5], apogee_scrambler:find_sync_markers(Stream, 2)).
