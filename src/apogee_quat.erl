%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit Quaternion Kinematics, SLERP, and DCM Transformations.
%%% Provides singularity-free attitude representations for spacecraft ADCS.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_quat).

-include("apogee.hrl").

-export([
    identity/0,
    new/4,
    from_axis_angle/2,
    to_axis_angle/1,
    norm_sq/1,
    norm/1,
    normalize/1,
    conjugate/1,
    inverse/1,
    mult/2,
    rotate_vec/2,
    to_mat3/1,
    from_mat3/1,
    slerp/3,
    angular_derivative/2
]).

-spec identity() -> #quaternion{}.
identity() ->
    #quaternion{w = 1.0, x = 0.0, y = 0.0, z = 0.0}.

-spec new(number(), number(), number(), number()) -> #quaternion{}.
new(W, X, Y, Z) ->
    #quaternion{w = float(W), x = float(X), y = float(Y), z = float(Z)}.

-spec from_axis_angle(#vector3{}, number()) -> #quaternion{}.
from_axis_angle(Axis, AngleRad) ->
    HalfAngle = float(AngleRad) * 0.5,
    SinHalf = math:sin(HalfAngle),
    CosHalf = math:cos(HalfAngle),
    NormalizedAxis = apogee_vec3:normalize(Axis),
    #quaternion{
        w = CosHalf,
        x = NormalizedAxis#vector3.x * SinHalf,
        y = NormalizedAxis#vector3.y * SinHalf,
        z = NormalizedAxis#vector3.z * SinHalf
    }.

-spec to_axis_angle(#quaternion{}) -> {#vector3{}, float()}.
to_axis_angle(Q) ->
    Normalized = normalize(Q),
    W = max(-1.0, min(1.0, Normalized#quaternion.w)),
    Angle = 2.0 * math:acos(W),
    SinHalf = math:sqrt(max(0.0, 1.0 - W * W)),
    case SinHalf of
        S when S > 1.0e-9 ->
            Axis = apogee_vec3:new(
                Normalized#quaternion.x / S,
                Normalized#quaternion.y / S,
                Normalized#quaternion.z / S
            ),
            {Axis, Angle};
        _ ->
            {apogee_vec3:new(1.0, 0.0, 0.0), 0.0}
    end.

-spec norm_sq(#quaternion{}) -> float().
norm_sq(#quaternion{w = W, x = X, y = Y, z = Z}) ->
    W * W + X * X + Y * Y + Z * Z.

-spec norm(#quaternion{}) -> float().
norm(Q) ->
    math:sqrt(norm_sq(Q)).

-spec normalize(#quaternion{}) -> #quaternion{}.
normalize(Q) ->
    case norm(Q) of
        N when N > 1.0e-12 ->
            InvN = 1.0 / N,
            #quaternion{
                w = Q#quaternion.w * InvN,
                x = Q#quaternion.x * InvN,
                y = Q#quaternion.y * InvN,
                z = Q#quaternion.z * InvN
            };
        _ ->
            identity()
    end.

-spec conjugate(#quaternion{}) -> #quaternion{}.
conjugate(#quaternion{w = W, x = X, y = Y, z = Z}) ->
    #quaternion{w = W, x = -X, y = -Y, z = -Z}.

-spec inverse(#quaternion{}) -> #quaternion{}.
inverse(Q) ->
    N2 = norm_sq(Q),
    case N2 of
        N when N > 1.0e-12 ->
            InvN2 = 1.0 / N,
            #quaternion{
                w = Q#quaternion.w * InvN2,
                x = -Q#quaternion.x * InvN2,
                y = -Q#quaternion.y * InvN2,
                z = -Q#quaternion.z * InvN2
            };
        _ ->
            identity()
    end.

-spec mult(#quaternion{}, #quaternion{}) -> #quaternion{}.
mult(#quaternion{w = W1, x = X1, y = Y1, z = Z1},
     #quaternion{w = W2, x = X2, y = Y2, z = Z2}) ->
    #quaternion{
        w = W1 * W2 - X1 * X2 - Y1 * Y2 - Z1 * Z2,
        x = W1 * X2 + X1 * W2 + Y1 * Z2 - Z1 * Y2,
        y = W1 * Y2 - X1 * Z2 + Y1 * W2 + Z1 * X2,
        z = W1 * Z2 + X1 * Y2 - Y1 * X2 + Z1 * W2
    }.

-spec rotate_vec(#quaternion{}, #vector3{}) -> #vector3{}.
rotate_vec(Q, #vector3{x = X, y = Y, z = Z}) ->
    %% Rodrigues rotation via quaternion vector algebra
    QNorm = normalize(Q),
    QV = apogee_vec3:new(QNorm#quaternion.x, QNorm#quaternion.y, QNorm#quaternion.z),
    V = apogee_vec3:new(X, Y, Z),
    T = apogee_vec3:scale(apogee_vec3:cross(QV, V), 2.0),
    apogee_vec3:add(
        V,
        apogee_vec3:add(
            apogee_vec3:scale(T, QNorm#quaternion.w),
            apogee_vec3:cross(QV, T)
        )
    ).

-spec to_mat3(#quaternion{}) -> #matrix3{}.
to_mat3(Q) ->
    #quaternion{w = W, x = X, y = Y, z = Z} = normalize(Q),
    XX = X * X, YY = Y * Y, ZZ = Z * Z,
    XY = X * Y, XZ = X * Z, YZ = Y * Z,
    WX = W * X, WY = W * Y, WZ = W * Z,
    apogee_mat3:new(
        1.0 - 2.0 * (YY + ZZ), 2.0 * (XY - WZ),       2.0 * (XZ + WY),
        2.0 * (XY + WZ),       1.0 - 2.0 * (XX + ZZ), 2.0 * (YZ - WX),
        2.0 * (XZ - WY),       2.0 * (YZ + WX),       1.0 - 2.0 * (XX + YY)
    ).

-spec from_mat3(#matrix3{}) -> #quaternion{}.
from_mat3(#matrix3{r11 = R11, r12 = R12, r13 = R13,
                    r21 = R21, r22 = R22, r23 = R23,
                    r31 = R31, r32 = R32, r33 = R33}) ->
    Trace = R11 + R22 + R33,
    if
        Trace > 0.0 ->
            S = 0.5 / math:sqrt(Trace + 1.0),
            normalize(#quaternion{
                w = 0.25 / S,
                x = (R32 - R23) * S,
                y = (R13 - R31) * S,
                z = (R21 - R12) * S
            });
        (R11 > R22) and (R11 > R33) ->
            S = 2.0 * math:sqrt(1.0 + R11 - R22 - R33),
            normalize(#quaternion{
                w = (R32 - R23) / S,
                x = 0.25 * S,
                y = (R12 + R21) / S,
                z = (R13 + R31) / S
            });
        R22 > R33 ->
            S = 2.0 * math:sqrt(1.0 + R22 - R11 - R33),
            normalize(#quaternion{
                w = (R13 - R31) / S,
                x = (R12 + R21) / S,
                y = 0.25 * S,
                z = (R23 + R32) / S
            });
        true ->
            S = 2.0 * math:sqrt(1.0 + R33 - R11 - R22),
            normalize(#quaternion{
                w = (R21 - R12) / S,
                x = (R13 + R31) / S,
                y = (R23 + R32) / S,
                z = 0.25 * S
            })
    end.

-spec slerp(#quaternion{}, #quaternion{}, number()) -> #quaternion{}.
slerp(Q1, Q2, T) ->
    FT = float(T),
    N1 = normalize(Q1),
    N2 = normalize(Q2),
    CosOmega = N1#quaternion.w * N2#quaternion.w +
               N1#quaternion.x * N2#quaternion.x +
               N1#quaternion.y * N2#quaternion.y +
               N1#quaternion.z * N2#quaternion.z,
    {TargetQ, CosClamped} = if
        CosOmega < 0.0 ->
            {#quaternion{
                w = -N2#quaternion.w,
                x = -N2#quaternion.x,
                y = -N2#quaternion.y,
                z = -N2#quaternion.z
            }, -CosOmega};
        true ->
            {N2, CosOmega}
    end,
    if
        CosClamped > 0.9995 ->
            %% Linear interpolation fallback for nearly parallel quaternions
            normalize(#quaternion{
                w = N1#quaternion.w * (1.0 - FT) + TargetQ#quaternion.w * FT,
                x = N1#quaternion.x * (1.0 - FT) + TargetQ#quaternion.x * FT,
                y = N1#quaternion.y * (1.0 - FT) + TargetQ#quaternion.y * FT,
                z = N1#quaternion.z * (1.0 - FT) + TargetQ#quaternion.z * FT
            });
        true ->
            Omega = math:acos(max(-1.0, min(1.0, CosClamped))),
            SinOmega = math:sin(Omega),
            Scale1 = math:sin((1.0 - FT) * Omega) / SinOmega,
            Scale2 = math:sin(FT * Omega) / SinOmega,
            #quaternion{
                w = N1#quaternion.w * Scale1 + TargetQ#quaternion.w * Scale2,
                x = N1#quaternion.x * Scale1 + TargetQ#quaternion.x * Scale2,
                y = N1#quaternion.y * Scale1 + TargetQ#quaternion.y * Scale2,
                z = N1#quaternion.z * Scale1 + TargetQ#quaternion.z * Scale2
            }
    end.

-spec angular_derivative(#quaternion{}, #vector3{}) -> #quaternion{}.
angular_derivative(#quaternion{w = W, x = X, y = Y, z = Z},
                   #vector3{x = Wx, y = Wy, z = Wz}) ->
    %% dq/dt = 0.5 * q * [0, omega]
    #quaternion{
        w = 0.5 * (-X * Wx - Y * Wy - Z * Wz),
        x = 0.5 * ( W * Wx + Y * Wz - Z * Wy),
        y = 0.5 * ( W * Wy - X * Wz + Z * Wx),
        z = 0.5 * ( W * Wz + X * Wy - Y * Wx)
    }.
