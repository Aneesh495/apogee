%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_vec3
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_vec3_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

basic_arithmetic_test() ->
    V1 = apogee_vec3:new(1, 2, 3),
    V2 = apogee_vec3:new(4, 5, 6),
    ?assertEqual(apogee_vec3:new(5, 7, 9), apogee_vec3:add(V1, V2)),
    ?assertEqual(apogee_vec3:new(-3, -3, -3), apogee_vec3:sub(V1, V2)),
    ?assertEqual(apogee_vec3:new(2, 4, 6), apogee_vec3:scale(V1, 2.0)),
    ?assertEqual(32.0, apogee_vec3:dot(V1, V2)).

cross_product_test() ->
    Vx = apogee_vec3:new(1, 0, 0),
    Vy = apogee_vec3:new(0, 1, 0),
    Vz = apogee_vec3:cross(Vx, Vy),
    ?assertEqual(apogee_vec3:new(0, 0, 1), Vz),
    ?assertEqual(apogee_vec3:new(0, 0, -1), apogee_vec3:cross(Vy, Vx)).

norm_and_normalize_test() ->
    V = apogee_vec3:new(0, 3, 4),
    ?assertEqual(25.0, apogee_vec3:norm_sq(V)),
    ?assertEqual(5.0, apogee_vec3:norm(V)),
    Normalized = apogee_vec3:normalize(V),
    ?assert(abs(Normalized#vector3.x - 0.0) < 1.0e-9),
    ?assert(abs(Normalized#vector3.y - 0.6) < 1.0e-9),
    ?assert(abs(Normalized#vector3.z - 0.8) < 1.0e-9),
    ?assert(abs(apogee_vec3:norm(Normalized) - 1.0) < 1.0e-9).

distance_and_angle_test() ->
    V1 = apogee_vec3:new(1, 0, 0),
    V2 = apogee_vec3:new(0, 1, 0),
    ?assert(abs(apogee_vec3:distance(V1, V2) - math:sqrt(2)) < 1.0e-9),
    ?assert(abs(apogee_vec3:angle_between(V1, V2) - (?PI / 2.0)) < 1.0e-9).

projection_test() ->
    V = apogee_vec3:new(2, 3, 0),
    Target = apogee_vec3:new(1, 0, 0),
    Proj = apogee_vec3:project(V, Target),
    Rej = apogee_vec3:reject(V, Target),
    ?assertEqual(apogee_vec3:new(2.0, 0.0, 0.0), Proj),
    ?assertEqual(apogee_vec3:new(0.0, 3.0, 0.0), Rej).
