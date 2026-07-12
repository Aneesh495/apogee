%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_ldpc
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_ldpc_tests).
-include_lib("eunit/include/eunit.hrl").

circulant_shift_test() ->
    Mask = 16#80000000,
    Shifted1 = apogee_ldpc:circulant_shift(Mask, 1),
    ?assertEqual(16#40000000, Shifted1),
    Shifted31 = apogee_ldpc:circulant_shift(Mask, 31),
    ?assertEqual(1, Shifted31).

prototype_expansion_test() ->
    Proto = [
        [0, -1, 1],
        [-1, 0, 0]
    ],
    M = 4,
    Expanded = apogee_ldpc:expand_matrix(Proto, M),
    ?assertEqual(8, length(Expanded)), % 2 rows * 4 = 8 rows
    ?assertEqual(12, length(hd(Expanded))), % 3 cols * 4 = 12 cols
    
    %% All zero codeword of length 12
    AllZero = lists:duplicate(12, 0),
    ?assert(apogee_ldpc:is_valid_codeword(Expanded, AllZero)),

    %% Corrupt single bit
    Corrupted = [1 | lists:duplicate(11, 0)],
    ?assertNot(apogee_ldpc:is_valid_codeword(Expanded, Corrupted)).

ber_calculation_test() ->
    B1 = <<16#FF, 16#00>>,
    B2 = <<16#FE, 16#00>>, % 1 bit difference
    BER = apogee_ldpc:bit_error_rate(B1, B2),
    ?assert(abs(BER - (1.0 / 16.0)) < 1.0e-6).
