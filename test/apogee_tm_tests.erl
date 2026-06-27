%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_tm
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_tm_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

tm_frame_roundtrip_test() ->
    Payload = <<"TELEMETRY_FRAME_CONTENT_VECTOR_BURST">>,
    Clcw = (apogee_clcw:new())#clcw{vcid = 0, report_value = 55},
    Frame = apogee_tm:new_frame(42, 3, 10, 20, 0, Payload, Clcw),
    Bin = apogee_tm:encode(Frame),
    {ok, Decoded, <<>>} = apogee_tm:decode(Bin),
    ?assertEqual(42, Decoded#tm_frame.scid),
    ?assertEqual(3, Decoded#tm_frame.vcid),
    ?assertEqual(10, Decoded#tm_frame.mcfc),
    ?assertEqual(20, Decoded#tm_frame.vcfc),
    ?assertEqual(Payload, Decoded#tm_frame.data),
    ?assert(Decoded#tm_frame.clcw =/= undefined),
    ?assertEqual(55, (Decoded#tm_frame.clcw)#clcw.report_value).

multiplex_demultiplex_test() ->
    P1 = apogee_spp:create_packet(10, ?CCSDS_TYPE_TM, 0, ?CCSDS_SEQ_UNSEGMENTED, <<"SENSOR_1">>),
    P2 = apogee_spp:create_packet(10, ?CCSDS_TYPE_TM, 1, ?CCSDS_SEQ_UNSEGMENTED, <<"SENSOR_2">>),
    P3 = apogee_spp:create_packet(10, ?CCSDS_TYPE_TM, 2, ?CCSDS_SEQ_UNSEGMENTED, <<"SENSOR_3">>),
    
    Frames = apogee_tm:multiplex_packets([P1, P2, P3], 1, 0, 128),
    ?assert(length(Frames) >= 1),
    Reassembled = apogee_tm:demultiplex_frames(Frames),
    ?assertEqual(3, length(Reassembled)),
    ?assertEqual(<<"SENSOR_1">>, (lists:nth(1, Reassembled))#ccsds_packet.payload),
    ?assertEqual(<<"SENSOR_2">>, (lists:nth(2, Reassembled))#ccsds_packet.payload),
    ?assertEqual(<<"SENSOR_3">>, (lists:nth(3, Reassembled))#ccsds_packet.payload).
