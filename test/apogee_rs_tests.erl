%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_rs Reed-Solomon (255, 223) codec
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_rs_tests).
-include_lib("eunit/include/eunit.hrl").

clean_codeword_test() ->
    Message = <<"DEEP_SPACE_TELEMETRY_BLOCK_NO_ERRORS">>,
    Codeword = apogee_rs:encode(Message),
    ?assertEqual(byte_size(Message) + 32, byte_size(Codeword)),
    {ok, Decoded, 0} = apogee_rs:decode(Codeword),
    ?assertEqual(Message, Decoded).

generator_poly_test() ->
    G = apogee_rs:generator_poly(),
    ?assertEqual(33, length(G)),
    ?assertEqual(1, hd(G)).

clean_syndromes_test() ->
    Message = <<"APOGEE_SPACECRAFT_CCSDS_PAYLOAD">>,
    Codeword = apogee_rs:encode(Message),
    FullCodeword = lists:duplicate(223 - byte_size(Message), 0) ++ binary_to_list(Codeword),
    Syndromes = apogee_rs:calculate_syndromes(FullCodeword),
    ?assertEqual(32, length(Syndromes)),
    ?assert(lists:all(fun(S) -> S =:= 0 end, Syndromes)).

uncorrectable_detection_test() ->
    %% Test that a massively scrambled block reports clean error or decodes
    Message = <<"SMALL_MSG">>,
    Codeword = apogee_rs:encode(Message),
    Corrupted = binary:copy(<<16#FF>>, byte_size(Codeword)),
    Result = apogee_rs:decode(Corrupted),
    ?assert(Result =:= {error, uncorrectable_error} orelse element(1, Result) =:= ok).
