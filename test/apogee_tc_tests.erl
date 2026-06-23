%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_tc and apogee_clcw
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_tc_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

tc_frame_roundtrip_test() ->
    Payload = <<"TELECOMMAND_THRUSTER_FIRE_DURATION_500MS">>,
    Frame = apogee_tc:new_frame(0, 42, 1, 105, Payload),
    Encoded = apogee_tc:encode(Frame),
    ?assert(byte_size(Encoded) =:= 5 + byte_size(Payload) + 2),
    {ok, Decoded, <<>>} = apogee_tc:decode(Encoded),
    ?assertEqual(0, Decoded#tc_frame.bypass_flag),
    ?assertEqual(42, Decoded#tc_frame.scid),
    ?assertEqual(1, Decoded#tc_frame.vcid),
    ?assertEqual(105, Decoded#tc_frame.frame_seq_num),
    ?assertEqual(Payload, Decoded#tc_frame.data).

tc_corrupted_crc_test() ->
    Frame = apogee_tc:new_frame(0, 42, 1, 105, <<"TEST">>),
    Encoded = apogee_tc:encode(Frame),
    <<Head:4/binary, Byte:8, Rest/binary>> = Encoded,
    Corrupted = <<Head/binary, (Byte bxor 16#FF):8, Rest/binary>>,
    ?assertEqual({error, crc_checksum_mismatch}, apogee_tc:decode(Corrupted)).

clcw_roundtrip_test() ->
    Clcw = (apogee_clcw:new())#clcw{
        vcid = 2,
        retransmit = true,
        report_value = 106
    },
    Bin = apogee_clcw:encode(Clcw),
    ?assertEqual(4, byte_size(Bin)),
    {ok, Decoded} = apogee_clcw:decode(Bin),
    ?assertEqual(2, Decoded#clcw.vcid),
    ?assert(apogee_clcw:is_retransmit(Decoded)),
    ?assertEqual(106, apogee_clcw:report_value(Decoded)).
