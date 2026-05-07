%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_quat
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_quat_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

identity_and_mult_test() ->
    I = apogee_quat:identity(),
    ?assertEqual(1.0, apogee_quat:norm(I)),
    Q = apogee_quat:from_axis_angle(apogee_vec3:new(0, 0, 1), ?PI / 2.0),
    Prod = apogee_quat:mult(Q, apogee_quat:conjugate(Q)),
    ?assert(abs(Prod#quaternion.w - 1.0) < 1.0e-9),
    ?assert(abs(Prod#quaternion.x) < 1.0e-9).

rotate_vec_test() ->
    Q = apogee_quat:from_axis_angle(apogee_vec3:new(0, 0, 1), ?PI / 2.0),
    V = apogee_vec3:new(1, 0, 0),
    RotV = apogee_quat:rotate_vec(Q, V),
    ?assert(abs(RotV#vector3.x - 0.0) < 1.0e-9),
    ?assert(abs(RotV#vector3.y - 1.0) < 1.0e-9),
    ?assert(abs(RotV#vector3.z - 0.0) < 1.0e-9).

dcm_roundtrip_test() ->
    Q = apogee_quat:normalize(apogee_quat:new(0.5, 0.5, 0.5, 0.5)),
    M = apogee_quat:to_mat3(Q),
    QRec = apogee_quat:from_mat3(M),
    ?assert(abs(abs(Q#quaternion.w) - abs(QRec#quaternion.w)) < 1.0e-6).

slerp_test() ->
    Q1 = apogee_quat:identity(),
    Q2 = apogee_quat:from_axis_angle(apogee_vec3:new(0, 0, 1), ?PI),
    Mid = apogee_quat:slerp(Q1, Q2, 0.5),
    Expected = apogee_quat:from_axis_angle(apogee_vec3:new(0, 0, 1), ?PI / 2.0),
    ?assert(abs(Mid#quaternion.w - Expected#quaternion.w) < 1.0e-6),
    ?assert(abs(Mid#quaternion.z - Expected#quaternion.z) < 1.0e-6).
