%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Precession, Nutation, and Equation of the Equinoxes.
%%% Implements IAU-76 / IAU-2000 reduction models for celestial frames.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_precession).

-include("apogee.hrl").

-export([
    mean_obliquity/1,
    nutation_angles/1,
    equation_of_equinoxes/1,
    precession_matrix/1,
    nutation_matrix/1,
    j2000_to_tod_matrix/1
]).

-define(JD_J2000, 2451545.0).
-define(ARCSEC_TO_RAD, 4.84813681109536e-6).

-spec mean_obliquity(float()) -> float().
mean_obliquity(JD) ->
    %% Lieske et al. (1977) polynomial for mean obliquity of the ecliptic in radians
    T = (JD - ?JD_J2000) / 36525.0,
    EpsSec = 84381.448 - 46.8150 * T - 0.00059 * T * T + 0.001813 * T * T * T,
    EpsSec * ?ARCSEC_TO_RAD.

-spec nutation_angles(float()) -> {float(), float()}.
nutation_angles(JD) ->
    %% Fundamental astronomical arguments (Delaunay arguments in radians)
    T = (JD - ?JD_J2000) / 36525.0,
    %% Mean longitude of ascending node of the Moon (Omega)
    OmegaDeg = 125.04452 - 1934.136261 * T + 0.0020708 * T * T,
    Omega = (OmegaDeg * ?DEG_TO_RAD),
    %% Mean longitude of the Sun (L)
    LDeg = 280.4665 + 36000.7698 * T,
    L = (LDeg * ?DEG_TO_RAD),
    %% Mean longitude of the Moon (Lp)
    LpDeg = 218.3165 + 481267.8813 * T,
    Lp = (LpDeg * ?DEG_TO_RAD),

    %% Dominant nutation terms in longitude (dPsi) and obliquity (dEps) in radians
    DPsiSec = -17.20 * math:sin(Omega)
              - 1.32 * math:sin(2.0 * L)
              - 0.23 * math:sin(2.0 * Lp)
              + 0.21 * math:sin(2.0 * Omega),
    DEpsSec = 9.20 * math:cos(Omega)
              + 0.57 * math:cos(2.0 * L)
              + 0.10 * math:cos(2.0 * Lp)
              - 0.09 * math:cos(2.0 * Omega),
    {DPsiSec * ?ARCSEC_TO_RAD, DEpsSec * ?ARCSEC_TO_RAD}.

-spec equation_of_equinoxes(float()) -> float().
equation_of_equinoxes(JD) ->
    {DPsi, _DEps} = nutation_angles(JD),
    Eps0 = mean_obliquity(JD),
    DPsi * math:cos(Eps0).

-spec precession_matrix(float()) -> #matrix3{}.
precession_matrix(JD) ->
    %% IAU 1976 precession angles (zeta, z, theta)
    T = (JD - ?JD_J2000) / 36525.0,
    T2 = T * T,
    T3 = T2 * T,
    ZetaSec = 2306.2181 * T + 0.30188 * T2 + 0.017998 * T3,
    ZSec = 2306.2181 * T + 1.09468 * T2 + 0.018203 * T3,
    ThetaSec = 2004.3109 * T - 0.42665 * T2 - 0.041833 * T3,

    Zeta = ZetaSec * ?ARCSEC_TO_RAD,
    Z = ZSec * ?ARCSEC_TO_RAD,
    Theta = ThetaSec * ?ARCSEC_TO_RAD,

    %% P = Rz(-z) * Ry(theta) * Rz(-zeta)
    Rz1 = apogee_mat3:rotation_z(-Zeta),
    Ry = apogee_mat3:rotation_y(Theta),
    Rz2 = apogee_mat3:rotation_z(-Z),
    apogee_mat3:mult(Rz2, apogee_mat3:mult(Ry, Rz1)).

-spec nutation_matrix(float()) -> #matrix3{}.
nutation_matrix(JD) ->
    {DPsi, DEps} = nutation_angles(JD),
    Eps0 = mean_obliquity(JD),
    Eps = Eps0 + DEps,
    %% N = Rx(-eps) * Rz(-dPsi) * Rx(eps0)
    Rx1 = apogee_mat3:rotation_x(Eps0),
    Rz = apogee_mat3:rotation_z(-DPsi),
    Rx2 = apogee_mat3:rotation_x(-Eps),
    apogee_mat3:mult(Rx2, apogee_mat3:mult(Rz, Rx1)).

-spec j2000_to_tod_matrix(float()) -> #matrix3{}.
j2000_to_tod_matrix(JD) ->
    P = precession_matrix(JD),
    N = nutation_matrix(JD),
    apogee_mat3:mult(N, P).
