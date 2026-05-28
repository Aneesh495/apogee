%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Celestial and Terrestrial Coordinate Transformations.
%%% TEME <-> ECEF rotational transformations using Greenwich Apparent Sidereal Time.
%%% Includes WGS-84 reference ellipsoid radii and geodetic positioning.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_coords).

-include("apogee.hrl").

-export([
    teme_to_ecef/2,
    teme_to_ecef_state/2,
    ecef_to_teme/2,
    ecef_to_teme_state/2,
    wgs84_constants/0,
    wgs84_normal_radius/1,
    wgs84_meridional_radius/1,
    geodetic_to_ecef/1,
    geodetic_to_ecef/3
]).

%% Earth angular rotation rate (rad/s)
-define(EARTH_OMEGA_RAD_S, 7.292115146706979e-5).

-spec wgs84_constants() -> #{a := float(), f := float(), b := float(), e2 := float()}.
wgs84_constants() ->
    #{
        a => ?EARTH_RADIUS_KM,
        f => ?EARTH_FLATTENING,
        b => ?EARTH_SEMI_MINOR_KM,
        e2 => ?EARTH_ECCENTRICITY_SQ
    }.

-spec wgs84_normal_radius(float()) -> float().
wgs84_normal_radius(LatRad) ->
    %% Radius of curvature in prime vertical: N(phi) = a / sqrt(1 - e^2 * sin^2(phi))
    SinPhi = math:sin(LatRad),
    Denom = math:sqrt(1.0 - ?EARTH_ECCENTRICITY_SQ * SinPhi * SinPhi),
    ?EARTH_RADIUS_KM / Denom.

-spec wgs84_meridional_radius(float()) -> float().
wgs84_meridional_radius(LatRad) ->
    %% Radius of curvature in meridian: M(phi) = a * (1 - e^2) / (1 - e^2 * sin^2(phi))^(3/2)
    SinPhi = math:sin(LatRad),
    DenomBase = 1.0 - ?EARTH_ECCENTRICITY_SQ * SinPhi * SinPhi,
    (?EARTH_RADIUS_KM * (1.0 - ?EARTH_ECCENTRICITY_SQ)) / math:pow(DenomBase, 1.5).

-spec teme_to_ecef(#vector3{}, float()) -> #vector3{}.
teme_to_ecef(#vector3{} = PosTeme, JD) ->
    Gast = apogee_time:gast(JD),
    Rz = apogee_mat3:rotation_z(Gast),
    apogee_mat3:mult_vec(Rz, PosTeme).

-spec teme_to_ecef_state(#orbit_state{}, float()) -> #orbit_state{}.
teme_to_ecef_state(#orbit_state{pos = PosTeme, vel = VelTeme}, JD) ->
    Gast = apogee_time:gast(JD),
    Rz = apogee_mat3:rotation_z(Gast),
    PosEcef = apogee_mat3:mult_vec(Rz, PosTeme),
    
    %% Velocity transformation: v_ecef = Rz * v_teme - omega x r_ecef
    VelRotated = apogee_mat3:mult_vec(Rz, VelTeme),
    OmegaVec = apogee_vec3:new(0.0, 0.0, ?EARTH_OMEGA_RAD_S),
    CoriolisCorrection = apogee_vec3:cross(OmegaVec, PosEcef),
    VelEcef = apogee_vec3:sub(VelRotated, CoriolisCorrection),

    #orbit_state{
        epoch = JD,
        pos = PosEcef,
        vel = VelEcef
    }.

-spec ecef_to_teme(#vector3{}, float()) -> #vector3{}.
ecef_to_teme(#vector3{} = PosEcef, JD) ->
    Gast = apogee_time:gast(JD),
    RzInv = apogee_mat3:rotation_z(-Gast),
    apogee_mat3:mult_vec(RzInv, PosEcef).

-spec ecef_to_teme_state(#orbit_state{}, float()) -> #orbit_state{}.
ecef_to_teme_state(#orbit_state{pos = PosEcef, vel = VelEcef}, JD) ->
    Gast = apogee_time:gast(JD),
    RzInv = apogee_mat3:rotation_z(-Gast),
    PosTeme = apogee_mat3:mult_vec(RzInv, PosEcef),

    OmegaVec = apogee_vec3:new(0.0, 0.0, ?EARTH_OMEGA_RAD_S),
    CoriolisCorrection = apogee_vec3:cross(OmegaVec, PosEcef),
    VelRotated = apogee_vec3:add(VelEcef, CoriolisCorrection),
    VelTeme = apogee_mat3:mult_vec(RzInv, VelRotated),

    #orbit_state{
        epoch = JD,
        pos = PosTeme,
        vel = VelTeme
    }.

-spec geodetic_to_ecef(#geodetic{}) -> #vector3{}.
geodetic_to_ecef(#geodetic{lat = LatDeg, lon = LonDeg, alt = AltKm}) ->
    geodetic_to_ecef(LatDeg, LonDeg, AltKm).

-spec geodetic_to_ecef(number(), number(), number()) -> #vector3{}.
geodetic_to_ecef(LatDeg, LonDeg, AltKm) ->
    LatRad = float(LatDeg) * ?DEG_TO_RAD,
    LonRad = float(LonDeg) * ?DEG_TO_RAD,
    H = float(AltKm),
    N = wgs84_normal_radius(LatRad),
    CosLat = math:cos(LatRad),
    SinLat = math:sin(LatRad),
    CosLon = math:cos(LonRad),
    SinLon = math:sin(LonRad),

    X = (N + H) * CosLat * CosLon,
    Y = (N + H) * CosLat * SinLon,
    Z = (N * (1.0 - ?EARTH_ECCENTRICITY_SQ) + H) * SinLat,
    apogee_vec3:new(X, Y, Z).
