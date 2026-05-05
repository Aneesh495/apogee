%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_mat3
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_mat3_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

identity_and_trace_test() ->
    I = apogee_mat3:identity(),
    ?assertEqual(3.0, apogee_mat3:trace(I)),
    ?assertEqual(1.0, apogee_mat3:determinant(I)),
    ?assertEqual(I, apogee_mat3:transpose(I)).

mult_vec_test() ->
    I = apogee_mat3:identity(),
    V = apogee_vec3:new(1, 2, 3),
    ?assertEqual(V, apogee_mat3:mult_vec(I, V)),
    
    Rz = apogee_mat3:rotation_z(?PI / 2.0),
    RotV = apogee_mat3:mult_vec(Rz, apogee_vec3:new(1, 0, 0)),
    ?assert(abs(RotV#vector3.x - 0.0) < 1.0e-9),
    ?assert(abs(RotV#vector3.y - 1.0) < 1.0e-9),
    ?assert(abs(RotV#vector3.z - 0.0) < 1.0e-9).

inverse_test() ->
    M = apogee_mat3:new(1, 2, 3,
                        0, 1, 4,
                        5, 6, 0),
    Det = apogee_mat3:determinant(M),
    ?assertEqual(1.0, Det),
    {ok, Inv} = apogee_mat3:inverse(M),
    Prod = apogee_mat3:mult(M, Inv),
    ?assert(abs(Prod#matrix3.r11 - 1.0) < 1.0e-9),
    ?assert(abs(Prod#matrix3.r22 - 1.0) < 1.0e-9),
    ?assert(abs(Prod#matrix3.r33 - 1.0) < 1.0e-9),
    ?assert(abs(Prod#matrix3.r12) < 1.0e-9).
