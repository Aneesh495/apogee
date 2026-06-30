%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_gf256
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_gf256_tests).
-include_lib("eunit/include/eunit.hrl").

gf256_inversion_test() ->
    lists:foreach(fun(A) ->
        Inv = apogee_gf256:inv(A),
        ?assertEqual(1, apogee_gf256:mult(A, Inv)),
        ?assertEqual(A, apogee_gf256:divide(A, 1))
    end, lists:seq(1, 255)).

gf256_distributive_test() ->
    A = 53,
    B = 127,
    C = 89,
    LHS = apogee_gf256:mult(A, apogee_gf256:add(B, C)),
    RHS = apogee_gf256:add(apogee_gf256:mult(A, B), apogee_gf256:mult(A, C)),
    ?assertEqual(LHS, RHS).

poly_arithmetic_test() ->
    P1 = [1, 2],       % x + 2
    P2 = [1, 3],       % x + 3
    Prod = apogee_gf256:poly_mult(P1, P2),
    %% (x + 2)(x + 3) = x^2 + (2^3)x + (2*3) in GF(256)
    ?assertEqual(3, length(Prod)),
    ?assertEqual(1, hd(Prod)).
