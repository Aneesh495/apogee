%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc 3D Vector Arithmetic and Geometric Operations.
%%% High-performance pure Erlang vector routines with guard optimizations.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_vec3).

-include("apogee.hrl").

-export([
    new/0,
    new/3,
    from_list/1,
    to_list/1,
    add/2,
    sub/2,
    scale/2,
    dot/2,
    cross/2,
    norm_sq/1,
    norm/1,
    magnitude/1,
    normalize/1,
    distance/2,
    distance_sq/2,
    angle_between/2,
    lerp/3,
    is_zero/1,
    is_zero/2,
    project/2,
    reject/2,
    rotate_x/2,
    rotate_y/2,
    rotate_z/2
]).

-spec new() -> #vector3{}.
new() ->
    #vector3{x = 0.0, y = 0.0, z = 0.0}.

-spec new(number(), number(), number()) -> #vector3{}.
new(X, Y, Z) ->
    #vector3{x = float(X), y = float(Y), z = float(Z)}.

-spec from_list([number()]) -> #vector3{}.
from_list([X, Y, Z]) ->
    new(X, Y, Z).

-spec to_list(#vector3{}) -> [float()].
to_list(#vector3{x = X, y = Y, z = Z}) ->
    [X, Y, Z].

-spec add(#vector3{}, #vector3{}) -> #vector3{}.
add(#vector3{x = X1, y = Y1, z = Z1}, #vector3{x = X2, y = Y2, z = Z2}) ->
    #vector3{x = X1 + X2, y = Y1 + Y2, z = Z1 + Z2}.

-spec sub(#vector3{}, #vector3{}) -> #vector3{}.
sub(#vector3{x = X1, y = Y1, z = Z1}, #vector3{x = X2, y = Y2, z = Z2}) ->
    #vector3{x = X1 - X2, y = Y1 - Y2, z = Z1 - Z2}.

-spec scale(#vector3{}, number()) -> #vector3{}.
scale(#vector3{x = X, y = Y, z = Z}, S) ->
    FS = float(S),
    #vector3{x = X * FS, y = Y * FS, z = Z * FS}.

-spec dot(#vector3{}, #vector3{}) -> float().
dot(#vector3{x = X1, y = Y1, z = Z1}, #vector3{x = X2, y = Y2, z = Z2}) ->
    X1 * X2 + Y1 * Y2 + Z1 * Z2.

-spec cross(#vector3{}, #vector3{}) -> #vector3{}.
cross(#vector3{x = X1, y = Y1, z = Z1}, #vector3{x = X2, y = Y2, z = Z2}) ->
    #vector3{
        x = Y1 * Z2 - Z1 * Y2,
        y = Z1 * X2 - X1 * Z2,
        z = X1 * Y2 - Y1 * X2
    }.

-spec norm_sq(#vector3{}) -> float().
norm_sq(#vector3{x = X, y = Y, z = Z}) ->
    X * X + Y * Y + Z * Z.

-spec norm(#vector3{}) -> float().
norm(V) ->
    math:sqrt(norm_sq(V)).

-spec magnitude(#vector3{}) -> float().
magnitude(V) ->
    norm(V).

-spec normalize(#vector3{}) -> #vector3{}.
normalize(V) ->
    case norm(V) of
        N when N > 1.0e-12 ->
            scale(V, 1.0 / N);
        _ ->
            #vector3{x = 0.0, y = 0.0, z = 0.0}
    end.

-spec distance_sq(#vector3{}, #vector3{}) -> float().
distance_sq(V1, V2) ->
    norm_sq(sub(V1, V2)).

-spec distance(#vector3{}, #vector3{}) -> float().
distance(V1, V2) ->
    norm(sub(V1, V2)).

-spec angle_between(#vector3{}, #vector3{}) -> float().
angle_between(V1, V2) ->
    N1 = norm(V1),
    N2 = norm(V2),
    case N1 * N2 of
        Denom when Denom > 1.0e-12 ->
            CosTheta = dot(V1, V2) / Denom,
            Clamped = max(-1.0, min(1.0, CosTheta)),
            math:acos(Clamped);
        _ ->
            0.0
    end.

-spec lerp(#vector3{}, #vector3{}, number()) -> #vector3{}.
lerp(#vector3{x = X1, y = Y1, z = Z1}, #vector3{x = X2, y = Y2, z = Z2}, T) ->
    FT = float(T),
    InvT = 1.0 - FT,
    #vector3{
        x = X1 * InvT + X2 * FT,
        y = Y1 * InvT + Y2 * FT,
        z = Z1 * InvT + Z2 * FT
    }.

-spec is_zero(#vector3{}) -> boolean().
is_zero(V) ->
    is_zero(V, 1.0e-9).

-spec is_zero(#vector3{}, float()) -> boolean().
is_zero(V, Eps) ->
    norm_sq(V) < (Eps * Eps).

-spec project(#vector3{}, #vector3{}) -> #vector3{}.
project(V, Target) ->
    TargetNormSq = norm_sq(Target),
    case TargetNormSq of
        T when T > 1.0e-12 ->
            scale(Target, dot(V, Target) / TargetNormSq);
        _ ->
            #vector3{x = 0.0, y = 0.0, z = 0.0}
    end.

-spec reject(#vector3{}, #vector3{}) -> #vector3{}.
reject(V, Target) ->
    sub(V, project(V, Target)).

-spec rotate_x(#vector3{}, number()) -> #vector3{}.
rotate_x(#vector3{x = X, y = Y, z = Z}, AngleRad) ->
    Cos = math:cos(AngleRad),
    Sin = math:sin(AngleRad),
    #vector3{
        x = X,
        y = Y * Cos - Z * Sin,
        z = Y * Sin + Z * Cos
    }.

-spec rotate_y(#vector3{}, number()) -> #vector3{}.
rotate_y(#vector3{x = X, y = Y, z = Z}, AngleRad) ->
    Cos = math:cos(AngleRad),
    Sin = math:sin(AngleRad),
    #vector3{
        x = X * Cos + Z * Sin,
        y = Y,
        z = -X * Sin + Z * Cos
    }.

-spec rotate_z(#vector3{}, number()) -> #vector3{}.
rotate_z(#vector3{x = X, y = Y, z = Z}, AngleRad) ->
    Cos = math:cos(AngleRad),
    Sin = math:sin(AngleRad),
    #vector3{
        x = X * Cos - Y * Sin,
        y = X * Sin + Y * Cos,
        z = Z
    }.
