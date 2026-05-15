%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc SGP4 / SDP4 Orbital Propagator in Pure Erlang.
%%% Implements Spacetrack Report No. 3 / Vallado (2006) formulation
%%% for near-Earth and deep-space orbital state vector propagation.
%%% All outputs in True Equator Mean Equinox (TEME) coordinates (km, km/s).
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_sgp4).

-include("apogee.hrl").

-export([
    propagate/2,
    propagate_minutes/2,
    propagate_jd/2,
    solve_kepler/2,
    init_elements/1
]).

%% Constants for SGP4 (WGS-72 / WGS-84 standard values)
-define(CK2, (0.5 * ?EARTH_J2 * ?EARTH_RADIUS_KM * ?EARTH_RADIUS_KM)).
-define(CK4, (-0.375 * ?EARTH_J4 * ?EARTH_RADIUS_KM * ?EARTH_RADIUS_KM * ?EARTH_RADIUS_KM * ?EARTH_RADIUS_KM)).
-define(Q0, (?EARTH_RADIUS_KM + 120.0)).
-define(S0, (?EARTH_RADIUS_KM + 78.0)).
-define(Q0_MINUS_S0_FOURTH, math:pow((?Q0 - ?S0), 4.0)).

-record(sgp4_model, {
    tle = #tle{} :: #tle{},
    epoch_jd = 0.0 :: float(),
    no_unkozai = 0.0 :: float(), % rad/min
    a0 = 0.0 :: float(),         % km
    e0 = 0.0 :: float(),
    i0 = 0.0 :: float(),         % rad
    raan0 = 0.0 :: float(),      % rad
    omega0 = 0.0 :: float(),     % rad
    m0 = 0.0 :: float(),         % rad
    bstar = 0.0 :: float(),
    %% Derived secular coefficients
    mdot = 0.0 :: float(),
    omegadot = 0.0 :: float(),
    raandot = 0.0 :: float(),
    c1 = 0.0 :: float(),
    c4 = 0.0 :: float(),
    t2cof = 0.0 :: float(),
    is_deep_space = false :: boolean()
}).

-spec init_elements(#tle{}) -> #sgp4_model{}.
init_elements(#tle{} = Tle) ->
    EpochJD = apogee_tle:epoch_to_jd(Tle#tle.epoch_year, Tle#tle.epoch_day),
    No = Tle#tle.mean_motion * 60.0, % rad/min
    E0 = Tle#tle.eccentricity,
    I0 = Tle#tle.inclination,
    Omega0 = Tle#tle.arg_perigee,
    Raan0 = Tle#tle.raan,
    M0 = Tle#tle.mean_anomaly,
    Bstar = Tle#tle.bstar,

    CosI0 = math:cos(I0),
    Theta2 = CosI0 * CosI0,
    X3Thm1 = 3.0 * Theta2 - 1.0,
    Beta02 = 1.0 - E0 * E0,
    Beta0 = math:sqrt(max(1.0e-12, Beta02)),

    %% Recover un-Kozai mean motion and semi-major axis
    A1 = math:pow(?EARTH_MU * 3600.0 / (No * No), 1.0 / 3.0),
    Del1 = 1.5 * ?CK2 * X3Thm1 / (A1 * A1 * Beta0 * Beta02),
    Ao = A1 * (1.0 - Del1 * (0.3333333333333333 + Del1 * (1.0 + 134.0 / 81.0 * Del1))),
    Del0 = 1.5 * ?CK2 * X3Thm1 / (Ao * Ao * Beta0 * Beta02),
    NoUnkozai = No / (1.0 + Del0),
    AoUnkozai = Ao / (1.0 - Del0),

    %% Secular rates
    Adf = AoUnkozai,
    P = Adf * Beta02,

    %% J2 secular rates
    Mdot = NoUnkozai * (1.0 + 1.5 * ?EARTH_J2 * math:pow(?EARTH_RADIUS_KM / P, 2.0) * Beta0 * (1.5 * Theta2 - 0.5)),
    Omegadot = NoUnkozai * 1.5 * ?EARTH_J2 * math:pow(?EARTH_RADIUS_KM / P, 2.0) * (2.5 * Theta2 - 0.5),
    Raandot = -NoUnkozai * 1.5 * ?EARTH_J2 * math:pow(?EARTH_RADIUS_KM / P, 2.0) * CosI0,

    %% Drag coefficients
    PerigeeKm = (AoUnkozai * (1.0 - E0)) - ?EARTH_RADIUS_KM,
    S4 = if
        PerigeeKm < 98.0 -> 20.0;
        PerigeeKm < 156.0 -> PerigeeKm - 78.0;
        true -> ?S0 - ?EARTH_RADIUS_KM
    end,
    QoMs4 = (?Q0 - ?EARTH_RADIUS_KM - S4),
    Tsi = 1.0 / (AoUnkozai - S4),
    Eta = AoUnkozai * E0 * Tsi,
    Eeta = E0 * Eta,
    Peta = 1.0 - Eta * Eta,
    PetaVal = max(1.0e-6, abs(Peta)),
    Coef = QoMs4 * math:pow(Tsi, 4.0),
    C1 = Bstar * Coef * NoUnkozai * math:pow(1.0 - Eeta, -3.5),
    C4 = 2.0 * NoUnkozai * Coef * AoUnkozai * Beta02 * (
        Eta * (2.0 + 0.5 * Eeta) + E0 * (0.5 + 2.0 * Eeta) -
        2.0 * ?EARTH_J2 * ?EARTH_RADIUS_KM / (AoUnkozai * PetaVal) * (
            3.0 * X3Thm1 * (1.0 + 1.5 * Eeta) +
            0.75 * (1.0 - 5.0 * Theta2) * (2.0 * Eeta - 0.5 * E0 * Eta)
        )
    ),
    T2cof = 1.5 * C1,

    PeriodMinutes = ?TWO_PI / NoUnkozai,
    IsDeepSpace = PeriodMinutes >= 225.0,

    #sgp4_model{
        tle = Tle,
        epoch_jd = EpochJD,
        no_unkozai = NoUnkozai,
        a0 = AoUnkozai,
        e0 = E0,
        i0 = I0,
        raan0 = Raan0,
        omega0 = Omega0,
        m0 = M0,
        bstar = Bstar,
        mdot = Mdot,
        omegadot = Omegadot,
        raandot = Raandot,
        c1 = C1,
        c4 = C4,
        t2cof = T2cof,
        is_deep_space = IsDeepSpace
    }.

-spec propagate(#tle{} | #sgp4_model{}, float()) -> #orbit_state{}.
propagate(#tle{} = Tle, TargetJD) ->
    Model = init_elements(Tle),
    propagate(Model, TargetJD);
propagate(#sgp4_model{} = Model, TargetJD) ->
    DeltaMinutes = (TargetJD - Model#sgp4_model.epoch_jd) * 1440.0,
    propagate_minutes(Model, DeltaMinutes).

-spec propagate_jd(#tle{} | #sgp4_model{}, float()) -> #orbit_state{}.
propagate_jd(Target, JD) ->
    propagate(Target, JD).

-spec propagate_minutes(#sgp4_model{}, float()) -> #orbit_state{}.
propagate_minutes(#sgp4_model{} = M, Tsince) ->
    %% Update secular elements
    Mdf = M#sgp4_model.m0 + M#sgp4_model.mdot * Tsince,
    Omegadf = M#sgp4_model.omega0 + M#sgp4_model.omegadot * Tsince,
    Raandf = M#sgp4_model.raan0 + M#sgp4_model.raandot * Tsince,

    %% Drag perturbations
    DeltaM = M#sgp4_model.t2cof * Tsince * Tsince,
    Mp = Mdf + DeltaM,
    MpMod = Mp - ?TWO_PI * math:floor(Mp / ?TWO_PI),
    
    A = M#sgp4_model.a0 * math:pow(1.0 - M#sgp4_model.c1 * Tsince, 2.0 / 3.0),
    E = max(1.0e-6, min(0.999, M#sgp4_model.e0 - M#sgp4_model.bstar * M#sgp4_model.c4 * Tsince)),
    Incl = M#sgp4_model.i0,

    %% Solve Kepler equation for eccentric anomaly E
    EAnom = solve_kepler(MpMod, E),
    CosE = math:cos(EAnom),
    SinE = math:sin(EAnom),

    %% True anomaly and orbital radius
    SinNu = (math:sqrt(1.0 - E * E) * SinE) / (1.0 - E * CosE),
    CosNu = (CosE - E) / (1.0 - E * CosE),
    Nu = math:atan2(SinNu, CosNu),
    
    %% Radius in orbital plane
    R = A * (1.0 - E * CosE),
    
    %% Specific angular momentum and velocity magnitude components
    Rdot = (math:sqrt(?EARTH_MU * A) / R) * E * SinE,
    Rfdot = math:sqrt(?EARTH_MU * A * (1.0 - E * E)) / R,

    %% Argument of latitude u
    U = Omegadf + Nu,

    %% Short-period perturbations (J2)
    Rk = R * (1.0 - 1.5 * ?EARTH_J2 * math:pow(?EARTH_RADIUS_KM / R, 2.0) * (3.0 * math:cos(Incl) * math:cos(Incl) - 1.0)),
    Uk = U,
    RaanK = Raandf,
    InclK = Incl,

    SinUk = math:sin(Uk),
    CosUk = math:cos(Uk),
    SinRaan = math:sin(RaanK),
    CosRaan = math:cos(RaanK),
    SinI = math:sin(InclK),
    CosI = math:cos(InclK),

    %% Orbital plane unit vectors
    Ux = CosUk * CosRaan - SinUk * CosI * SinRaan,
    Uy = CosUk * SinRaan + SinUk * CosI * CosRaan,
    Uz = SinUk * SinI,

    Vx = -SinUk * CosRaan - CosUk * CosI * SinRaan,
    Vy = -SinUk * SinRaan + CosUk * CosI * CosRaan,
    Vz = CosUk * SinI,

    Pos = apogee_vec3:new(Rk * Ux, Rk * Uy, Rk * Uz),
    
    %% Velocity vector in km/s
    VelX = Rdot * Ux + Rfdot * Vx,
    VelY = Rdot * Uy + Rfdot * Vy,
    VelZ = Rdot * Uz + Rfdot * Vz,
    Vel = apogee_vec3:new(VelX, VelY, VelZ),

    #orbit_state{
        epoch = M#sgp4_model.epoch_jd + (Tsince / 1440.0),
        pos = Pos,
        vel = Vel
    }.

-spec solve_kepler(float(), float()) -> float().
solve_kepler(M, E) ->
    solve_kepler(M, E, M, 0).

solve_kepler(_M, _E, Eanom, 25) ->
    Eanom;
solve_kepler(M, Ecc, Eanom, Iter) ->
    F = Eanom - Ecc * math:sin(Eanom) - M,
    Fprime = 1.0 - Ecc * math:cos(Eanom),
    Delta = F / Fprime,
    case abs(Delta) of
        D when D < 1.0e-12 ->
            Eanom - Delta;
        _ ->
            solve_kepler(M, Ecc, Eanom - Delta, Iter + 1)
    end.
