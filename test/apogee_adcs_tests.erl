%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for Attitude Determination and Control Subsystem (ADCS).
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_adcs_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

kinematics_and_dynamics_test() ->
    Q0 = #quaternion{w = 1.0, x = 0.0, y = 0.0, z = 0.0},
    % Pure rotation around Z axis at 0.1 rad/s for 10 seconds (1 radian)
    OmegaZ = #vector3{x = 0.0, y = 0.0, z = 0.1},
    Q1 = apogee_adcs:propagate_kinematics(Q0, OmegaZ, 10.0),
    % Quat should remain normalized
    ?assert(abs(apogee_quat:norm(Q1) - 1.0) < 1.0e-5),
    % Angle rotated should be ~1.0 radian
    Err = apogee_adcs:pointing_error(Q0, Q1),
    ?assert(abs(Err - 1.0) < 0.05).

reaction_wheel_momentum_exchange_test() ->
    S0 = apogee_adcs:new(),
    % Apply +0.01 N*m torque command on Z-axis reaction wheel for 1 second
    TorqueCmd = #vector3{x = 0.0, y = 0.0, z = 0.01},
    ZeroExt = #vector3{x = 0.0, y = 0.0, z = 0.0},
    S1 = apogee_adcs:step_attitude(S0, TorqueCmd, ZeroExt, 1.0),
    
    % Reaction wheel should have gained +0.01 N*m*s momentum
    ?assert(abs(S1#adcs_state.wheel_momentum#vector3.z - 0.01) < 1.0e-4),
    % Spacecraft body should have accelerated in the OPPOSITE direction (negative OmegaZ)
    ?assert(S1#adcs_state.angular_velocity#vector3.z < 0.0).

pd_attitude_control_test() ->
    % Current attitude rotated by 0.2 rad, target is identity
    Target = #quaternion{w = 1.0, x = 0.0, y = 0.0, z = 0.0},
    Current = apogee_quat:from_axis_angle(#vector3{x = 0.0, y = 0.0, z = 1.0}, 0.2),
    Omega = #vector3{x = 0.0, y = 0.0, z = 0.0},

    Torque = apogee_adcs:pd_attitude_control(Current, Target, Omega, 0.5, 0.1),
    % Restoring torque should oppose the positive rotation (negative Z)
    ?assert(Torque#vector3.z < 0.0).

geomagnetic_field_and_desaturation_test() ->
    % SatPos at LEO altitude (7000 km) on equator
    SatPos = #vector3{x = 7000.0, y = 0.0, z = 0.0},
    BField = apogee_adcs:compute_b_field_eci(SatPos),
    BNorm = apogee_vec3:norm(BField),
    % Earth B-field at 7000 km is ~20 to 60 microTesla (2e-5 to 6e-5 Tesla)
    ?assert(BNorm > 1.0e-5 andalso BNorm < 1.0e-4),

    % B-dot detumble command should be non-zero for tumbling satellite
    TumblingOmega = #vector3{x = 0.05, y = -0.02, z = 0.01},
    Dipole = apogee_adcs:b_dot_detumble(TumblingOmega, BField),
    ?assert(apogee_vec3:norm(Dipole) > 0.0),

    % Saturated reaction wheels
    S0 = apogee_adcs:new(),
    S_sat = S0#adcs_state{wheel_momentum = #vector3{x = 0.05, y = 0.05, z = 0.05}},
    {TorqueMag, S_desat} = apogee_adcs:desaturate_reaction_wheels(S_sat, BField),
    ?assert(apogee_vec3:norm(TorqueMag) > 0.0),
    % Total wheel momentum magnitude should decrease
    H_before = apogee_vec3:norm(S_sat#adcs_state.wheel_momentum),
    H_after = apogee_vec3:norm(S_desat#adcs_state.wheel_momentum),
    ?assert(H_after < H_before).
