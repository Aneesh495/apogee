%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_spp
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_spp_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

packet_roundtrip_test() ->
    Payload = <<"TELEMETRY_PAYLOAD_SCIENCE_BURST">>,
    P = apogee_spp:create_packet(101, ?CCSDS_TYPE_TM, 42, ?CCSDS_SEQ_UNSEGMENTED, Payload, 1700000000000),
    Bin = apogee_spp:encode(P),
    ?assert(byte_size(Bin) > byte_size(Payload)),
    {ok, Decoded, <<>>} = apogee_spp:decode(Bin),
    ?assertEqual(101, Decoded#ccsds_packet.apid),
    ?assertEqual(?CCSDS_TYPE_TM, Decoded#ccsds_packet.type),
    ?assertEqual(42, Decoded#ccsds_packet.seq_count),
    ?assertEqual(?CCSDS_SEQ_UNSEGMENTED, Decoded#ccsds_packet.seq_flags),
    ?assertEqual(Payload, Decoded#ccsds_packet.payload),
    ?assert(abs(Decoded#ccsds_packet.timestamp - 1700000000000) < 10).

idle_packet_test() ->
    Idle = apogee_spp:create_idle_packet(64),
    ?assert(apogee_spp:is_idle_packet(Idle)),
    Encoded = apogee_spp:encode(Idle),
    {ok, Decoded, <<>>} = apogee_spp:decode(Encoded),
    ?assert(apogee_spp:is_idle_packet(Decoded)),
    ?assertEqual(64, byte_size(Decoded#ccsds_packet.payload)).

stream_decode_test() ->
    P1 = apogee_spp:create_packet(1, ?CCSDS_TYPE_TC, 10, ?CCSDS_SEQ_FIRST, <<"P1">>),
    P2 = apogee_spp:create_packet(1, ?CCSDS_TYPE_TC, 11, ?CCSDS_SEQ_LAST, <<"P2">>),
    Stream = << (apogee_spp:encode(P1))/binary, (apogee_spp:encode(P2))/binary, "TRAILING" >>,
    {Packets, Trailing} = apogee_spp:decode_all(Stream),
    ?assertEqual(2, length(Packets)),
    ?assertEqual(<<"TRAILING">>, Trailing).

time_cds_roundtrip_test() ->
    UnixMs = 1680000000500,
    CdsBin = apogee_spp:encode_time_cds(UnixMs),
    ?assertEqual(6, byte_size(CdsBin)),
    Decoded = apogee_spp:decode_time_cds(CdsBin),
    ?assert(abs(Decoded - UnixMs) < 10).
