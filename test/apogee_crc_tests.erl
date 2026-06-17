%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_crc against standard test vectors
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_crc_tests).
-include_lib("eunit/include/eunit.hrl").

standard_vectors_test() ->
    Data = <<"123456789">>,
    %% CRC-16-CCITT standard test vector = 0x29B1 (10673)
    ?assertEqual(16#29B1, apogee_crc:crc16_ccitt(Data)),
    ?assert(apogee_crc:verify_crc16_ccitt(Data, 16#29B1)),
    
    %% CRC-32 IEEE standard test vector = 0xCBF43926 (3421760294)
    ?assertEqual(16#CBF43926, apogee_crc:crc32_ieee(Data)),
    ?assert(apogee_crc:verify_crc32(Data, 16#CBF43926)),

    %% CRC-32 Castagnoli (CRC-32C) test vector = 0xE3069283 (3808850563)
    ?assertEqual(16#E3069283, apogee_crc:crc32_castagnoli(Data)).

empty_vector_test() ->
    Empty = <<>>,
    ?assertEqual(16#FFFF, apogee_crc:crc16_ccitt(Empty)),
    ?assertEqual(0, apogee_crc:crc32_ieee(Empty)),
    ?assertEqual(0, apogee_crc:crc32_castagnoli(Empty)).
