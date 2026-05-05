%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc 3x3 Matrix Arithmetic, Inversions, and Rotational Kinematics.
%%% Optimized for aerospace direction cosine matrices (DCM).
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_mat3).

-include("apogee.hrl").

-export([
    identity/0,
    zero/0,
    new/9,
    from_rows/3,
    from_cols/3,
    to_rows/1,
    to_cols/1,
    add/2,
    sub/2,
    scale/2,
    mult/2,
    mult_vec/2,
    transpose/1,
    determinant/1,
    trace/1,
    inverse/1,
    rotation_x/1,
    rotation_y/1,
    rotation_z/1,
    from_euler/3
]).

-spec identity() -> #matrix3{}.
identity() ->
    #matrix3{
        r11 = 1.0, r12 = 0.0, r13 = 0.0,
        r21 = 0.0, r22 = 1.0, r23 = 0.0,
        r31 = 0.0, r32 = 0.0, r33 = 1.0
    }.

-spec zero() -> #matrix3{}.
zero() ->
    #matrix3{
        r11 = 0.0, r12 = 0.0, r13 = 0.0,
        r21 = 0.0, r22 = 0.0, r23 = 0.0,
        r31 = 0.0, r32 = 0.0, r33 = 0.0
    }.

-spec new(number(), number(), number(),
          number(), number(), number(),
          number(), number(), number()) -> #matrix3{}.
new(R11, R12, R13, R21, R22, R23, R31, R32, R33) ->
    #matrix3{
        r11 = float(R11), r12 = float(R12), r13 = float(R13),
        r21 = float(R21), r22 = float(R22), r23 = float(R23),
        r31 = float(R31), r32 = float(R32), r33 = float(R33)
    }.

-spec from_rows(#vector3{}, #vector3{}, #vector3{}) -> #matrix3{}.
from_rows(#vector3{x = X1, y = Y1, z = Z1},
          #vector3{x = X2, y = Y2, z = Z2},
          #vector3{x = X3, y = Y3, z = Z3}) ->
    new(X1, Y1, Z1, X2, Y2, Z2, X3, Y3, Z3).

-spec from_cols(#vector3{}, #vector3{}, #vector3{}) -> #matrix3{}.
from_cols(#vector3{x = X1, y = Y1, z = Z1},
          #vector3{x = X2, y = Y2, z = Z2},
          #vector3{x = X3, y = Y3, z = Z3}) ->
    new(X1, X2, X3, Y1, Y2, Y3, Z1, Z2, Z3).

-spec to_rows(#matrix3{}) -> {#vector3{}, #vector3{}, #vector3{}}.
to_rows(#matrix3{r11 = R11, r12 = R12, r13 = R13,
                 r21 = R21, r22 = R22, r23 = R23,
                 r31 = R31, r32 = R32, r33 = R33}) ->
    {apogee_vec3:new(R11, R12, R13),
     apogee_vec3:new(R21, R22, R23),
     apogee_vec3:new(R31, R32, R33)}.

-spec to_cols(#matrix3{}) -> {#vector3{}, #vector3{}, #vector3{}}.
to_cols(#matrix3{r11 = R11, r12 = R12, r13 = R13,
                 r21 = R21, r22 = R22, r23 = R23,
                 r31 = R31, r32 = R32, r33 = R33}) ->
    {apogee_vec3:new(R11, R21, R31),
     apogee_vec3:new(R12, R22, R32),
     apogee_vec3:new(R13, R23, R33)}.

-spec add(#matrix3{}, #matrix3{}) -> #matrix3{}.
add(#matrix3{r11 = A11, r12 = A12, r13 = A13,
             r21 = A21, r22 = A22, r23 = A23,
             r31 = A31, r32 = A32, r33 = A33},
    #matrix3{r11 = B11, r12 = B12, r13 = B13,
             r21 = B21, r22 = B22, r23 = B23,
             r31 = B31, r32 = B32, r33 = B33}) ->
    #matrix3{
        r11 = A11 + B11, r12 = A12 + B12, r13 = A13 + B13,
        r21 = A21 + B21, r22 = A22 + B22, r23 = A23 + B23,
        r31 = A31 + B31, r32 = A32 + B32, r33 = A33 + B33
    }.

-spec sub(#matrix3{}, #matrix3{}) -> #matrix3{}.
sub(#matrix3{r11 = A11, r12 = A12, r13 = A13,
             r21 = A21, r22 = A22, r23 = A23,
             r31 = A31, r32 = A32, r33 = A33},
    #matrix3{r11 = B11, r12 = B12, r13 = B13,
             r21 = B21, r22 = B22, r23 = B23,
             r31 = B31, r32 = B32, r33 = B33}) ->
    #matrix3{
        r11 = A11 - B11, r12 = A12 - B12, r13 = A13 - B13,
        r21 = A21 - B21, r22 = A22 - B22, r23 = A23 - B23,
        r31 = A31 - B31, r32 = A32 - B32, r33 = A33 - B33
    }.

-spec scale(#matrix3{}, number()) -> #matrix3{}.
scale(#matrix3{r11 = A11, r12 = A12, r13 = A13,
               r21 = A21, r22 = A22, r23 = A23,
               r31 = A31, r32 = A32, r33 = A33}, S) ->
    FS = float(S),
    #matrix3{
        r11 = A11 * FS, r12 = A12 * FS, r13 = A13 * FS,
        r21 = A21 * FS, r22 = A22 * FS, r23 = A23 * FS,
        r31 = A31 * FS, r32 = A32 * FS, r33 = A33 * FS
    }.

-spec mult(#matrix3{}, #matrix3{}) -> #matrix3{}.
mult(#matrix3{r11 = A11, r12 = A12, r13 = A13,
              r21 = A21, r22 = A22, r23 = A23,
              r31 = A31, r32 = A32, r33 = A33},
     #matrix3{r11 = B11, r12 = B12, r13 = B13,
              r21 = B21, r22 = B22, r23 = B23,
              r31 = B31, r32 = B32, r33 = B33}) ->
    #matrix3{
        r11 = A11 * B11 + A12 * B21 + A13 * B31,
        r12 = A11 * B12 + A12 * B22 + A13 * B32,
        r13 = A11 * B13 + A12 * B23 + A13 * B33,

        r21 = A21 * B11 + A22 * B21 + A23 * B31,
        r22 = A21 * B12 + A22 * B22 + A23 * B32,
        r23 = A21 * B13 + A22 * B23 + A23 * B33,

        r31 = A31 * B11 + A32 * B21 + A33 * B31,
        r32 = A31 * B12 + A32 * B22 + A33 * B32,
        r33 = A31 * B13 + A32 * B23 + A33 * B33
    }.

-spec mult_vec(#matrix3{}, #vector3{}) -> #vector3{}.
mult_vec(#matrix3{r11 = A11, r12 = A12, r13 = A13,
                  r21 = A21, r22 = A22, r23 = A23,
                  r31 = A31, r32 = A32, r33 = A33},
         #vector3{x = X, y = Y, z = Z}) ->
    #vector3{
        x = A11 * X + A12 * Y + A13 * Z,
        y = A21 * X + A22 * Y + A23 * Z,
        z = A31 * X + A32 * Y + A33 * Z
    }.

-spec transpose(#matrix3{}) -> #matrix3{}.
transpose(#matrix3{r11 = A11, r12 = A12, r13 = A13,
                    r21 = A21, r22 = A22, r23 = A23,
                    r31 = A31, r32 = A32, r33 = A33}) ->
    #matrix3{
        r11 = A11, r12 = A21, r13 = A31,
        r21 = A12, r22 = A22, r23 = A32,
        r31 = A13, r32 = A23, r33 = A33
    }.

-spec determinant(#matrix3{}) -> float().
determinant(#matrix3{r11 = A11, r12 = A12, r13 = A13,
                     r21 = A21, r22 = A22, r23 = A23,
                     r31 = A31, r32 = A32, r33 = A33}) ->
    A11 * (A22 * A33 - A23 * A32) -
    A12 * (A21 * A33 - A23 * A31) +
    A13 * (A21 * A32 - A22 * A31).

-spec trace(#matrix3{}) -> float().
trace(#matrix3{r11 = A11, r22 = A22, r33 = A33}) ->
    A11 + A22 + A33.

-spec inverse(#matrix3{}) -> {ok, #matrix3{}} | {error, singular}.
inverse(#matrix3{r11 = A11, r12 = A12, r13 = A13,
                 r21 = A21, r22 = A22, r23 = A23,
                 r31 = A31, r32 = A32, r33 = A33} = M) ->
    Det = determinant(M),
    case abs(Det) of
        D when D > 1.0e-12 ->
            InvDet = 1.0 / Det,
            {ok, #matrix3{
                r11 = (A22 * A33 - A23 * A32) * InvDet,
                r12 = (A13 * A32 - A12 * A33) * InvDet,
                r13 = (A12 * A23 - A13 * A22) * InvDet,

                r21 = (A23 * A31 - A21 * A33) * InvDet,
                r22 = (A11 * A33 - A13 * A31) * InvDet,
                r23 = (A13 * A21 - A11 * A23) * InvDet,

                r31 = (A21 * A32 - A22 * A31) * InvDet,
                r32 = (A12 * A31 - A11 * A32) * InvDet,
                r33 = (A11 * A22 - A12 * A21) * InvDet
            }};
        _ ->
            {error, singular}
    end.

-spec rotation_x(number()) -> #matrix3{}.
rotation_x(AngleRad) ->
    Cos = math:cos(AngleRad),
    Sin = math:sin(AngleRad),
    #matrix3{
        r11 = 1.0, r12 = 0.0,  r13 = 0.0,
        r21 = 0.0, r22 = Cos,  r23 = -Sin,
        r31 = 0.0, r32 = Sin,  r33 = Cos
    }.

-spec rotation_y(number()) -> #matrix3{}.
rotation_y(AngleRad) ->
    Cos = math:cos(AngleRad),
    Sin = math:sin(AngleRad),
    #matrix3{
        r11 = Cos,  r12 = 0.0, r13 = Sin,
        r21 = 0.0,  r22 = 1.0, r23 = 0.0,
        r31 = -Sin, r32 = 0.0, r33 = Cos
    }.

-spec rotation_z(number()) -> #matrix3{}.
rotation_z(AngleRad) ->
    Cos = math:cos(AngleRad),
    Sin = math:sin(AngleRad),
    #matrix3{
        r11 = Cos,  r12 = -Sin, r13 = 0.0,
        r21 = Sin,  r22 = Cos,  r23 = 0.0,
        r31 = 0.0,  r32 = 0.0,  r33 = 1.0
    }.

-spec from_euler(number(), number(), number()) -> #matrix3{}.
from_euler(Roll, Pitch, Yaw) ->
    %% Z-Y-X Tait-Bryan rotation sequence
    Rz = rotation_z(Yaw),
    Ry = rotation_y(Pitch),
    Rx = rotation_x(Roll),
    mult(Rz, mult(Ry, Rx)).
