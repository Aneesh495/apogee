%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Astronomical Time Computations and Sidereal Reductions.
%%% Supports Julian Date, MJD, and IAU Greenwich Mean/Apparent Sidereal Time.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_time).

-include("apogee.hrl").

-export([
    datetime_to_jd/1,
    datetime_to_jd/6,
    jd_to_datetime/1,
    jd_to_mjd/1,
    mjd_to_jd/1,
    unix_to_jd/1,
    jd_to_unix/1,
    now_jd/0,
    now_unix_ms/0,
    now_seconds/0,
    gmst/1,
    gast/1,
    gast/2,
    days_to_hms/1,
    hms_to_fractional_day/3
]).

%% Standard J2000.0 epoch: 2000-01-01 12:00:00 TT = 2451545.0 JD
-define(JD_J2000, 2451545.0).
-define(MJD_OFFSET, 2400000.5).
-define(UNIX_EPOCH_JD, 2440587.5). % 1970-01-01 00:00:00 UTC

-spec datetime_to_jd({{integer(), integer(), integer()}, {integer(), integer(), number()}}) -> float().
datetime_to_jd({{Year, Month, Day}, {Hour, Minute, Second}}) ->
    datetime_to_jd(Year, Month, Day, Hour, Minute, Second).

-spec datetime_to_jd(integer(), integer(), integer(), integer(), integer(), number()) -> float().
datetime_to_jd(Year, Month, Day, Hour, Minute, Second) ->
    {AdjYear, AdjMonth} = if
        Month =< 2 -> {Year - 1, Month + 12};
        true -> {Year, Month}
    end,
    A = AdjYear div 100,
    B = 2 - A + (A div 4),
    DayFraction = (float(Hour) + float(Minute) / 60.0 + float(Second) / 3600.0) / 24.0,
    trunc(365.25 * (AdjYear + 4716)) +
    trunc(30.6001 * (AdjMonth + 1)) +
    Day + DayFraction + B - 1524.5.

-spec jd_to_datetime(float()) -> {{integer(), integer(), integer()}, {integer(), integer(), float()}}.
jd_to_datetime(JD) ->
    Z = trunc(JD + 0.5),
    F = (JD + 0.5) - Z,
    A = if
        Z < 2299161 ->
            Z;
        true ->
            Alpha = trunc((Z - 1867216.25) / 36524.25),
            Z + 1 + Alpha - (Alpha div 4)
    end,
    B = A + 1524,
    C = trunc((B - 122.1) / 365.25),
    D = trunc(365.25 * C),
    E = trunc((B - D) / 30.6001),
    DayWithFrac = B - D - trunc(30.6001 * E) + F,
    Day = trunc(DayWithFrac),
    Month = if
        E < 14 -> E - 1;
        true -> E - 13
    end,
    Year = if
        Month > 2 -> C - 4716;
        true -> C - 4715
    end,
    DayFrac = DayWithFrac - Day,
    TotalSeconds = DayFrac * 86400.0,
    Hour = trunc(TotalSeconds / 3600.0),
    RemSeconds = TotalSeconds - Hour * 3600.0,
    Minute = trunc(RemSeconds / 60.0),
    Second = RemSeconds - Minute * 60.0,
    {{Year, Month, Day}, {Hour, Minute, Second}}.

-spec jd_to_mjd(float()) -> float().
jd_to_mjd(JD) ->
    JD - ?MJD_OFFSET.

-spec mjd_to_jd(float()) -> float().
mjd_to_jd(MJD) ->
    MJD + ?MJD_OFFSET.

-spec unix_to_jd(number()) -> float().
unix_to_jd(UnixSec) ->
    ?UNIX_EPOCH_JD + (float(UnixSec) / 86400.0).

-spec jd_to_unix(float()) -> float().
jd_to_unix(JD) ->
    (JD - ?UNIX_EPOCH_JD) * 86400.0.

-spec now_jd() -> float().
now_jd() ->
    {Mega, Sec, Micro} = os:timestamp(),
    UnixSec = Mega * 1000000 + Sec + Micro * 1.0e-6,
    unix_to_jd(UnixSec).

-spec now_unix_ms() -> non_neg_integer().
now_unix_ms() ->
    erlang:system_time(millisecond).

-spec now_seconds() -> float().
now_seconds() ->
    erlang:system_time(millisecond) / 1000.0.

-spec gmst(float()) -> float().
gmst(JD) ->
    %% IAU-76 Greenwich Mean Sidereal Time in radians [0, 2*pi)
    D = JD - ?JD_J2000,
    T = D / 36525.0,
    %% GMST in seconds of time: 24110.54841 + 8640184.812866 * T + 0.093104 * T^2 - 6.2e-6 * T^3
    Sec = 24110.54841 + 8640184.812866 * T + 0.093104 * T * T - 6.2e-6 * T * T * T,
    FracDay = (D - trunc(D)) * 86400.0,
    TotalSec = Sec + FracDay * 1.00273790935,
    SecRem = TotalSec - 86400.0 * math:floor(TotalSec / 86400.0),
    AngleRad = (SecRem / 86400.0) * ?TWO_PI,
    AngleRad - ?TWO_PI * math:floor(AngleRad / ?TWO_PI).

-spec gast(float()) -> float().
gast(JD) ->
    gast(JD, 0.0).

-spec gast(float(), float()) -> float().
gast(JD, EqEquinox) ->
    %% Greenwich Apparent Sidereal Time = GMST + Equation of Equinoxes
    G = gmst(JD) + EqEquinox,
    G - ?TWO_PI * math:floor(G / ?TWO_PI).

-spec days_to_hms(float()) -> {integer(), integer(), float()}.
days_to_hms(Days) ->
    TotalSeconds = Days * 86400.0,
    H = trunc(TotalSeconds / 3600.0),
    Rem1 = TotalSeconds - H * 3600.0,
    M = trunc(Rem1 / 60.0),
    S = Rem1 - M * 60.0,
    {H, M, S}.

-spec hms_to_fractional_day(integer(), integer(), number()) -> float().
hms_to_fractional_day(H, M, S) ->
    (float(H) * 3600.0 + float(M) * 60.0 + float(S)) / 86400.0.
