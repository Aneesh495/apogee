%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Attitude Determination and Control Subsystem (ADCS).
%%% Implements:
%%% - Rigid body rotational dynamics using Euler equations of motion
%%% - Quaternion attitude kinematics integration
%%% - Reaction wheel momentum exchange, torque limits, and friction
%%% - Earth dipole geomagnetic field model
%%% - B-dot detumbling magnetic control law
%%% - Magnetic torquer reaction wheel desaturation (momentum dumping)
%%% - Quaternion feedback PD attitude pointing control
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_adcs).

-include("apogee.hrl").

-export([
    new/0,
    new/1,
    propagate_kinematics/3,
    step_attitude/4,
    compute_b_field_eci/1,
    b_dot_detumble/2,
    desaturate_reaction_wheels/2,
    pointing_error/2,
    pd_attitude_control/5,
    tilted_dipole_b_field/2,
    desaturate_if_needed/3
]).

%% Reaction wheel physical constants
-define(WHEEL_INERTIA, 1.0e-4). % kg * m^2 per reaction wheel
-define(MAX_WHEEL_TORQUE, 0.02). % N * m
-define(MAX_WHEEL_RPM, 6000.0).  % Max wheel speed
-define(RPM_TO_RAD_S, 0.10471975511965977). % 2 * pi / 60
-define(EARTH_MAGNETIC_MOMENT, 7.94e22). % A * m^2 (Earth magnetic dipole moment)

-type adcs_state() :: #adcs_state{}.
-export_type([adcs_state/0]).

%%====================================================================
%% API Functions
%%====================================================================

-spec new() -> adcs_state().
new() ->
    new([]).

-spec new(proplists:proplist()) -> adcs_state().
new(Opts) ->
    Att = proplists:get_value(attitude, Opts, #quaternion{w = 1.0, x = 0.0, y = 0.0, z = 0.0}),
    Omega = proplists:get_value(angular_velocity, Opts, #vector3{x = 0.0, y = 0.0, z = 0.0}),
    Inertia = proplists:get_value(inertia, Opts, #vector3{x = 0.05, y = 0.05, z = 0.02}),
    Mode = proplists:get_value(mode, Opts, detumble),
    #adcs_state{
        attitude = apogee_quat:normalize(Att),
        angular_velocity = Omega,
        wheel_momentum = #vector3{x = 0.0, y = 0.0, z = 0.0},
        wheel_speed_rpm = #vector3{x = 0.0, y = 0.0, z = 0.0},
        inertia = Inertia,
        mode = Mode
    }.

-spec propagate_kinematics(#quaternion{}, #vector3{}, float()) -> #quaternion{}.
propagate_kinematics(#quaternion{} = Q, #vector3{} = Omega, DeltaSec) ->
    NormOmega = apogee_vec3:norm(Omega),
    case NormOmega < 1.0e-12 of
        true ->
            Q;
        false ->
            Angle = NormOmega * DeltaSec,
            HalfAngle = 0.5 * Angle,
            SinHalf = math:sin(HalfAngle),
            CosHalf = math:cos(HalfAngle),
            Axis = apogee_vec3:scale(Omega, 1.0 / NormOmega),
            QDelta = #quaternion{
                w = CosHalf,
                x = Axis#vector3.x * SinHalf,
                y = Axis#vector3.y * SinHalf,
                z = Axis#vector3.z * SinHalf
            },
            apogee_quat:normalize(apogee_quat:mult(QDelta, Q))
    end.

-spec step_attitude(adcs_state(), #vector3{}, #vector3{}, float()) -> adcs_state().
step_attitude(#adcs_state{} = S, #vector3{} = TorqueCmd, #vector3{} = TorqueExt, DeltaSec) ->
    %% Clamp wheel torque to physical motor limits
    ClampedTorque = clamp_vector(TorqueCmd, -?MAX_WHEEL_TORQUE, ?MAX_WHEEL_TORQUE),

    %% Update reaction wheel momentum: dh_w/dt = tau_w
    Hw = S#adcs_state.wheel_momentum,
    NewHw = apogee_vec3:add(Hw, apogee_vec3:scale(ClampedTorque, DeltaSec)),
    
    %% Wheel speeds in RPM
    RadS_x = NewHw#vector3.x / ?WHEEL_INERTIA,
    RadS_y = NewHw#vector3.y / ?WHEEL_INERTIA,
    RadS_z = NewHw#vector3.z / ?WHEEL_INERTIA,
    WheelRPM = #vector3{
        x = RadS_x / ?RPM_TO_RAD_S,
        y = RadS_y / ?RPM_TO_RAD_S,
        z = RadS_z / ?RPM_TO_RAD_S
    },

    %% Spacecraft rotational dynamics (Euler equations):
    %% I * domega/dt = tau_ext - tau_cmd - omega x (I*omega + h_w)
    I = S#adcs_state.inertia,
    Omega = S#adcs_state.angular_velocity,
    
    I_omega = #vector3{
        x = I#vector3.x * Omega#vector3.x,
        y = I#vector3.y * Omega#vector3.y,
        z = I#vector3.z * Omega#vector3.z
    },
    TotalAngularMomentum = apogee_vec3:add(I_omega, NewHw),
    GyroscopicTorque = apogee_vec3:cross(Omega, TotalAngularMomentum),

    NetTorque = apogee_vec3:sub(
        apogee_vec3:sub(TorqueExt, ClampedTorque),
        GyroscopicTorque
    ),

    DOmega = #vector3{
        x = NetTorque#vector3.x / I#vector3.x,
        y = NetTorque#vector3.y / I#vector3.y,
        z = NetTorque#vector3.z / I#vector3.z
    },

    NewOmega = apogee_vec3:add(Omega, apogee_vec3:scale(DOmega, DeltaSec)),
    NewAttitude = propagate_kinematics(S#adcs_state.attitude, NewOmega, DeltaSec),

    S#adcs_state{
        attitude = NewAttitude,
        angular_velocity = NewOmega,
        wheel_momentum = NewHw,
        wheel_speed_rpm = WheelRPM
    }.

-spec compute_b_field_eci(#vector3{}) -> #vector3{}.
compute_b_field_eci(#vector3{} = SatPos) ->
    %% Earth magnetic dipole centered at origin
    R = apogee_vec3:norm(SatPos) * 1000.0, % km to meters
    case R < 1.0e5 of
        true ->
            #vector3{x = 0.0, y = 0.0, z = 0.0};
        false ->
            R_hat = apogee_vec3:scale(SatPos, 1000.0 / R),
            % Magnetic dipole axis aligned with Earth geographic Z axis (approximate)
            M_vec = #vector3{x = 0.0, y = 0.0, z = -?EARTH_MAGNETIC_MOMENT},
            M_dot_R = apogee_vec3:dot(M_vec, R_hat),
            R3 = R * R * R,
            Factor = 1.0e-7 / R3, % mu_0 / (4 * pi) = 1e-7
            B_x = Factor * (3.0 * M_dot_R * R_hat#vector3.x - M_vec#vector3.x),
            B_y = Factor * (3.0 * M_dot_R * R_hat#vector3.y - M_vec#vector3.y),
            B_z = Factor * (3.0 * M_dot_R * R_hat#vector3.z - M_vec#vector3.z),
            #vector3{x = B_x, y = B_y, z = B_z} % Tesla
    end.

-spec b_dot_detumble(#vector3{}, #vector3{}) -> #vector3{}.
b_dot_detumble(#vector3{} = Omega, #vector3{} = BFieldBody) ->
    %% B-dot magnetic detumbling law: m = -k * (omega x B) / ||B||
    BNorm = apogee_vec3:norm(BFieldBody),
    case BNorm < 1.0e-9 of
        true ->
            #vector3{x = 0.0, y = 0.0, z = 0.0};
        false ->
            OmegaCrossB = apogee_vec3:cross(Omega, BFieldBody),
            Gain = 1.0e5, % A * m^2 gain
            apogee_vec3:scale(OmegaCrossB, -Gain / BNorm)
    end.

-spec desaturate_reaction_wheels(adcs_state(), #vector3{}) -> {#vector3{}, adcs_state()}.
desaturate_reaction_wheels(#adcs_state{} = S, #vector3{} = BFieldBody) ->
    %% Momentum dumping: tau_mag = m x B
    %% Choose magnetic dipole moment m to produce torque opposing excess wheel momentum
    Hw = S#adcs_state.wheel_momentum,
    BNorm = apogee_vec3:norm(BFieldBody),
    case BNorm < 1.0e-9 of
        true ->
            {#vector3{x = 0.0, y = 0.0, z = 0.0}, S};
        false ->
            BSq = BNorm * BNorm,
            % Desired torque: tau_des = -k_dump * Hw
            KDump = 0.05,
            TauDes = apogee_vec3:scale(Hw, -KDump),
            % Optimal dipole moment: m = (tau_des x B) / ||B||^2
            M_dipole = apogee_vec3:scale(apogee_vec3:cross(TauDes, BFieldBody), 1.0 / BSq),
            % Applied magnetic torque: tau_mag = m x B
            TauMag = apogee_vec3:cross(M_dipole, BFieldBody),
            % Dump momentum: dh_w = -tau_mag * dt (for unit time 1s)
            UpdatedHw = apogee_vec3:sub(Hw, TauMag),
            {TauMag, S#adcs_state{wheel_momentum = UpdatedHw}}
    end.

-spec pointing_error(#quaternion{}, #quaternion{}) -> float().
pointing_error(#quaternion{} = QCurrent, #quaternion{} = QTarget) ->
    %% Angle between two unit quaternions: theta = 2 * acos(|q_err.w|)
    QTargetConj = apogee_quat:conjugate(QTarget),
    QErr = apogee_quat:mult(QCurrent, QTargetConj),
    ClampedW = max(-1.0, min(1.0, abs(QErr#quaternion.w))),
    2.0 * math:acos(ClampedW).

-spec pd_attitude_control(#quaternion{}, #quaternion{}, #vector3{}, float(), float()) -> #vector3{}.
pd_attitude_control(#quaternion{} = QCurrent, #quaternion{} = QTarget, #vector3{} = Omega, Kp, Kd) ->
    %% Quaternion feedback PD controller:
    %% tau = -2 * Kp * sgn(q_err.w) * q_err_vec - Kd * omega
    QTargetConj = apogee_quat:conjugate(QTarget),
    QErr = apogee_quat:mult(QCurrent, QTargetConj),
    Sign = case QErr#quaternion.w >= 0.0 of
        true -> 1.0;
        false -> -1.0
    end,
    TauP = #vector3{
        x = -2.0 * Kp * Sign * QErr#quaternion.x,
        y = -2.0 * Kp * Sign * QErr#quaternion.y,
        z = -2.0 * Kp * Sign * QErr#quaternion.z
    },
    TauD = apogee_vec3:scale(Omega, -Kd),
    apogee_vec3:add(TauP, TauD).

-spec desaturate_if_needed(adcs_state(), #vector3{}, float()) -> {boolean(), #vector3{}, adcs_state()}.
desaturate_if_needed(#adcs_state{} = S, #vector3{} = BFieldBody, ThresholdNmS) ->
    HwNorm = apogee_vec3:norm(S#adcs_state.wheel_momentum),
    case HwNorm > ThresholdNmS of
        true ->
            {TauMag, UpdatedS} = desaturate_reaction_wheels(S, BFieldBody),
            {true, TauMag, UpdatedS};
        false ->
            {false, #vector3{x = 0.0, y = 0.0, z = 0.0}, S}
    end.

-spec tilted_dipole_b_field(#vector3{}, float()) -> #vector3{}.
tilted_dipole_b_field(#vector3{} = SatPos, GMST) ->
    %% Dipole axis tilted by 11.5 degrees (~0.2007 rad) towards 70W longitude
    Tilt = 0.2007,
    LambdaMag = -70.0 * ?DEG_TO_RAD + GMST,
    M_hat = #vector3{
        x = math:sin(Tilt) * math:cos(LambdaMag),
        y = math:sin(Tilt) * math:sin(LambdaMag),
        z = -math:cos(Tilt)
    },
    M_vec = apogee_vec3:scale(M_hat, ?EARTH_MAGNETIC_MOMENT),
    R = apogee_vec3:norm(SatPos) * 1000.0,
    case R < 1.0e5 of
        true ->
            #vector3{x = 0.0, y = 0.0, z = 0.0};
        false ->
            R_hat = apogee_vec3:scale(SatPos, 1000.0 / R),
            M_dot_R = apogee_vec3:dot(M_vec, R_hat),
            R3 = R * R * R,
            Factor = 1.0e-7 / R3,
            B_x = Factor * (3.0 * M_dot_R * R_hat#vector3.x - M_vec#vector3.x),
            B_y = Factor * (3.0 * M_dot_R * R_hat#vector3.y - M_vec#vector3.y),
            B_z = Factor * (3.0 * M_dot_R * R_hat#vector3.z - M_vec#vector3.z),
            #vector3{x = B_x, y = B_y, z = B_z}
    end.

%%====================================================================
%% Internal Helpers
%%====================================================================

clamp_vector(#vector3{x = X, y = Y, z = Z}, Min, Max) ->
    #vector3{
        x = max(Min, min(Max, X)),
        y = max(Min, min(Max, Y)),
        z = max(Min, min(Max, Z))
    }.
