%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Line-of-Sight Visibility, Horizon Occultation, and Topocentric Look Angles.
%%% Implements Earth ellipsoid ray intersection, ENU topocentric coordinate frames,
%%% azimuth, elevation, slant range, and Doppler shift calculations.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_los).

-include("apogee.hrl").

-export([
    is_los_visible/2,
    is_los_visible/3,
    ray_tangent_altitude_km/2,
    ecef_to_enu/2,
    ground_look_angles/2,
    is_above_elevation_mask/3,
    range_rate_km_s/2,
    doppler_shift_hz/4
]).

-define(A, ?EARTH_RADIUS_KM).
-define(B, ?EARTH_SEMI_MINOR_KM).

-spec is_los_visible(#vector3{}, #vector3{}) -> boolean().
is_los_visible(Pos1Ecef, Pos2Ecef) ->
    is_los_visible(Pos1Ecef, Pos2Ecef, 100.0). % Default 100 km atmospheric buffer

-spec is_los_visible(#vector3{}, #vector3{}, float()) -> boolean().
is_los_visible(Pos1Ecef, Pos2Ecef, MinGrazingAltKm) ->
    ray_tangent_altitude_km(Pos1Ecef, Pos2Ecef) >= MinGrazingAltKm.

-spec ray_tangent_altitude_km(#vector3{}, #vector3{}) -> float().
ray_tangent_altitude_km(#vector3{} = P1, #vector3{} = P2) ->
    %% Parameterized line: r(t) = P1 + t * (P2 - P1), t in [0, 1]
    D = apogee_vec3:sub(P2, P1),
    DNormSq = apogee_vec3:norm_sq(D),
    case DNormSq of
        Val when Val < 1.0e-9 ->
            %% P1 and P2 are identical
            Geo = apogee_geodetic:ecef_to_geodetic(P1),
            Geo#geodetic.alt;
        _ ->
            %% Find t where norm(r(t)) is minimized: d/dt |r(t)|^2 = 0
            %% 2 * (P1 + t*D) . D = 0 => t = - (P1 . D) / |D|^2
            TMin = -apogee_vec3:dot(P1, D) / DNormSq,
            TClamped = max(0.0, min(1.0, TMin)),
            ClosestPoint = apogee_vec3:add(P1, apogee_vec3:scale(D, TClamped)),
            Geo = apogee_geodetic:ecef_to_geodetic(ClosestPoint),
            Geo#geodetic.alt
    end.

-spec ecef_to_enu(#geodetic{}, #vector3{}) -> #vector3{}.
ecef_to_enu(#geodetic{lat = LatDeg, lon = LonDeg} = StationGeo, #vector3{} = TargetEcef) ->
    StationEcef = apogee_coords:geodetic_to_ecef(StationGeo),
    Delta = apogee_vec3:sub(TargetEcef, StationEcef),

    LatRad = float(LatDeg) * ?DEG_TO_RAD,
    LonRad = float(LonDeg) * ?DEG_TO_RAD,
    SinLat = math:sin(LatRad),
    CosLat = math:cos(LatRad),
    SinLon = math:sin(LonRad),
    CosLon = math:cos(LonRad),

    %% East, North, Up unit vectors in ECEF
    East = -SinLon * Delta#vector3.x + CosLon * Delta#vector3.y,
    North = -SinLat * CosLon * Delta#vector3.x - SinLat * SinLon * Delta#vector3.y + CosLat * Delta#vector3.z,
    Up = CosLat * CosLon * Delta#vector3.x + CosLat * SinLon * Delta#vector3.y + SinLat * Delta#vector3.z,

    apogee_vec3:new(East, North, Up).

-spec ground_look_angles(#geodetic{}, #vector3{}) -> #{azimuth_deg := float(), elevation_deg := float(), range_km := float()}.
ground_look_angles(#geodetic{} = StationGeo, #vector3{} = TargetEcef) ->
    #vector3{x = E, y = N, z = U} = ecef_to_enu(StationGeo, TargetEcef),
    HorizontalRange = math:sqrt(E * E + N * N),
    TotalRange = math:sqrt(E * E + N * N + U * U),

    %% Azimuth: angle clockwise from North [0, 360)
    AzimuthRad = math:atan2(E, N),
    AzimuthDeg = case AzimuthRad * ?RAD_TO_DEG of
        Az when Az < 0.0 -> Az + 360.0;
        Az -> Az
    end,

    %% Elevation: angle above horizontal [-90, +90]
    ElevationRad = math:atan2(U, max(1.0e-9, HorizontalRange)),
    ElevationDeg = ElevationRad * ?RAD_TO_DEG,

    #{
        azimuth_deg => AzimuthDeg,
        elevation_deg => ElevationDeg,
        range_km => TotalRange
    }.

-spec is_above_elevation_mask(#geodetic{}, #vector3{}, number()) -> boolean().
is_above_elevation_mask(#geodetic{} = StationGeo, #vector3{} = TargetEcef, MinElevationDeg) ->
    #{elevation_deg := El} = ground_look_angles(StationGeo, TargetEcef),
    El >= float(MinElevationDeg).

-spec range_rate_km_s(#orbit_state{}, #vector3{}) -> float().
range_rate_km_s(#orbit_state{pos = SatEcef, vel = SatVelEcef}, #vector3{} = StationEcef) ->
    RelPos = apogee_vec3:sub(SatEcef, StationEcef),
    Range = apogee_vec3:norm(RelPos),
    case Range of
        R when R > 1.0e-6 ->
            apogee_vec3:dot(RelPos, SatVelEcef) / R;
        _ ->
            0.0
    end.

-spec doppler_shift_hz(number(), #orbit_state{}, #vector3{}, number()) -> float().
doppler_shift_hz(CarrierFreqHz, #orbit_state{} = SatStateEcef, #vector3{} = StationEcef, _C_KmS) ->
    RangeRate = range_rate_km_s(SatStateEcef, StationEcef),
    %% Delta f = - f0 * (range_rate / c)
    - float(CarrierFreqHz) * (RangeRate / ?SPEED_OF_LIGHT_KM_S).
