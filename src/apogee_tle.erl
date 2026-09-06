%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc NASA / NORAD Two-Line Element (TLE) Parser and Validator.
%%% Parses 69-column orbital elements with modulo-10 checksum verification.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_tle).

-include("apogee.hrl").

-export([
    parse/1,
    parse/2,
    parse_lines/2,
    parse_lines/3,
    checksum/1,
    verify_checksum/1,
    epoch_to_jd/2,
    jd_to_epoch/1,
    format/1,
    semi_major_axis/1,
    orbital_period_s/1,
    perigee_altitude_km/1,
    apogee_altitude_km/1
]).

-spec parse(binary() | string()) -> {ok, #tle{}} | {error, term()}.
parse(Binary) when is_binary(Binary) ->
    parse(binary_to_list(Binary));
parse(String) when is_list(String) ->
    Lines = [string:trim(L) || L <- string:lexemes(String, "\r\n"), string:trim(L) =/= ""],
    case Lines of
        [Line1, Line2] ->
            parse_lines(Line1, Line2);
        [Name, Line1, Line2] ->
            parse_lines(Name, Line1, Line2);
        _ ->
            {error, invalid_tle_format}
    end.

-spec parse(string(), string()) -> {ok, #tle{}} | {error, term()}.
parse(Line1, Line2) ->
    parse_lines(Line1, Line2).

-spec parse_lines(string(), string()) -> {ok, #tle{}} | {error, term()}.
parse_lines(Line1, Line2) ->
    parse_lines("UNKNOWN", Line1, Line2).

-spec parse_lines(string(), string(), string()) -> {ok, #tle{}} | {error, term()}.
parse_lines(Name, Line1, Line2) ->
    case {length(Line1) >= 69, length(Line2) >= 69} of
        {true, true} ->
            case {verify_checksum(Line1), verify_checksum(Line2)} of
                {true, true} ->
                    parse_fields(Name, Line1, Line2);
                {false, _} ->
                    {error, line1_checksum_mismatch};
                {_, false} ->
                    {error, line2_checksum_mismatch}
            end;
        _ ->
            {error, line_length_too_short}
    end.

-spec verify_checksum(string()) -> boolean().
verify_checksum(Line) ->
    %% Checksum is last character in 69-character line (index 69, 1-based)
    Content = lists:sublist(Line, 68),
    Expected = list_to_integer([lists:nth(69, Line)]),
    checksum(Content) =:= Expected.

-spec checksum(string()) -> integer().
checksum(Str) ->
    checksum(Str, 0).

checksum([], Acc) ->
    Acc rem 10;
checksum([$- | Rest], Acc) ->
    checksum(Rest, Acc + 1);
checksum([C | Rest], Acc) when C >= $0, C =< $9 ->
    checksum(Rest, Acc + (C - $0));
checksum([_ | Rest], Acc) ->
    checksum(Rest, Acc).

parse_fields(Name, Line1, Line2) ->
    try
        %% Line 1 parsing
        "1 " ++ L1Rest = Line1,
        SatNum1 = list_to_integer(string:trim(lists:sublist(L1Rest, 1, 5))),
        ClassChar = lists:nth(6, L1Rest),
        IdYear = list_to_integer(string:trim(lists:sublist(L1Rest, 8, 2))),
        IdLaunch = list_to_integer(string:trim(lists:sublist(L1Rest, 10, 3))),
        IdPiece = list_to_binary(string:trim(lists:sublist(L1Rest, 13, 3))),
        EpochYear = list_to_integer(string:trim(lists:sublist(L1Rest, 17, 2))),
        EpochDay = list_to_float_or_int(string:trim(lists:sublist(L1Rest, 19, 12))),
        
        %% BSTAR drag term: e.g. " 12345-4" -> 0.12345e-4
        BstarStr = lists:sublist(L1Rest, 52, 8),
        Bstar = parse_assumed_decimal(BstarStr),

        %% Line 2 parsing
        "2 " ++ L2Rest = Line2,
        SatNum2 = list_to_integer(string:trim(lists:sublist(L2Rest, 1, 5))),
        case SatNum1 =:= SatNum2 of
            true -> ok;
            false -> throw({error, satellite_number_mismatch})
        end,
        InclinationDeg = list_to_float_or_int(string:trim(lists:sublist(L2Rest, 7, 8))),
        RaanDeg = list_to_float_or_int(string:trim(lists:sublist(L2Rest, 16, 8))),
        EccStr = lists:sublist(L2Rest, 25, 7),
        Eccentricity = list_to_float("0." ++ string:trim(EccStr)),
        ArgPerigeeDeg = list_to_float_or_int(string:trim(lists:sublist(L2Rest, 33, 8))),
        MeanAnomalyDeg = list_to_float_or_int(string:trim(lists:sublist(L2Rest, 42, 8))),
        MeanMotionRevPerDay = list_to_float_or_int(string:trim(lists:sublist(L2Rest, 51, 11))),
        RevNum = list_to_integer(string:trim(lists:sublist(L2Rest, 62, 5))),

        FullEpochYear = if
            EpochYear < 57 -> 2000 + EpochYear;
            true -> 1900 + EpochYear
        end,

        %% Mean motion in radians per second: rev/day * 2*pi / 86400
        MeanMotionRadS = MeanMotionRevPerDay * ?TWO_PI / 86400.0,

        {ok, #tle{
            name = list_to_binary(string:trim(Name)),
            sat_num = SatNum1,
            classification = ClassChar,
            id_year = IdYear,
            id_launch = IdLaunch,
            id_piece = IdPiece,
            epoch_year = FullEpochYear,
            epoch_day = EpochDay,
            bstar = Bstar,
            inclination = InclinationDeg * ?DEG_TO_RAD,
            raan = RaanDeg * ?DEG_TO_RAD,
            eccentricity = Eccentricity,
            arg_perigee = ArgPerigeeDeg * ?DEG_TO_RAD,
            mean_anomaly = MeanAnomalyDeg * ?DEG_TO_RAD,
            mean_motion = MeanMotionRadS,
            rev_num = RevNum
        }}
    catch
        _:Reason ->
            {error, {parse_failed, Reason}}
    end.

parse_assumed_decimal(Str) ->
    Trimmed = string:trim(Str),
    case Trimmed of
        "" -> 0.0;
        "00000-0" -> 0.0;
        "00000+0" -> 0.0;
        _ ->
            %% Format is typically [+-]?NNNNN[+-]N
            {Sign, Rest1} = case Trimmed of
                [$- | R] -> {-1.0, R};
                [$+ | R] -> {1.0, R};
                R -> {1.0, R}
            end,
            %% Find exponent sign near end
            {MantissaDigits, ExpSign, ExpDigit} = split_mantissa_exp(Rest1),
            Mantissa = list_to_float("0." ++ MantissaDigits),
            Exponent = list_to_integer([ExpDigit]) * ExpSign,
            Sign * Mantissa * math:pow(10.0, Exponent)
    end.

split_mantissa_exp(Str) ->
    %% Match last 2 chars as [+-]E
    Len = length(Str),
    MantissaPart = lists:sublist(Str, Len - 2),
    ExpSignChar = lists:nth(Len - 1, Str),
    ExpDigit = lists:nth(Len, Str),
    ExpSign = if
        ExpSignChar =:= $- -> -1;
        true -> 1
    end,
    {MantissaPart, ExpSign, ExpDigit}.

list_to_float_or_int(Str) ->
    case string:find(Str, ".") of
        nomatch -> float(list_to_integer(Str));
        _ -> list_to_float(Str)
    end.

-spec epoch_to_jd(non_neg_integer(), float()) -> float().
epoch_to_jd(Year, DayOfYear) ->
    %% 1.0 DayOfYear corresponds to Jan 1 00:00:00
    Jan1JD = apogee_time:datetime_to_jd(Year, 1, 1, 0, 0, 0.0),
    Jan1JD + (DayOfYear - 1.0).

-spec jd_to_epoch(float()) -> {non_neg_integer(), float()}.
jd_to_epoch(JD) ->
    {{Year, _Month, _Day}, _Time} = apogee_time:jd_to_datetime(JD),
    Jan1JD = apogee_time:datetime_to_jd(Year, 1, 1, 0, 0, 0.0),
    DayOfYear = (JD - Jan1JD) + 1.0,
    {Year, DayOfYear}.

-spec semi_major_axis(#tle{}) -> float().
semi_major_axis(#tle{mean_motion = N}) when N > 0.0 ->
    %% Kepler's third law: a = (mu / n^2)^(1/3)
    math:pow(?EARTH_MU / (N * N), 1.0 / 3.0).

-spec orbital_period_s(#tle{}) -> float().
orbital_period_s(#tle{mean_motion = N}) when N > 0.0 ->
    ?TWO_PI / N.

-spec perigee_altitude_km(#tle{}) -> float().
perigee_altitude_km(#tle{eccentricity = Ecc} = Tle) ->
    A = semi_major_axis(Tle),
    (A * (1.0 - Ecc)) - ?EARTH_RADIUS_KM.

-spec apogee_altitude_km(#tle{}) -> float().
apogee_altitude_km(#tle{eccentricity = Ecc} = Tle) ->
    A = semi_major_axis(Tle),
    (A * (1.0 + Ecc)) - ?EARTH_RADIUS_KM.

-spec format(#tle{}) -> {string(), string(), string()}.
format(#tle{} = Tle) ->
    NameStr = binary_to_list(Tle#tle.name),
    ShortYear = Tle#tle.epoch_year rem 100,
    RevDay = Tle#tle.mean_motion * 86400.0 / ?TWO_PI,
    
    %% Format BSTAR: e.g. 0.12345e-4 -> " 12345-4"
    BstarFormatted = format_assumed_decimal(Tle#tle.bstar),

    Line1Prefix = io_lib:format("1 ~5..0w~c ~2..0w~3..0w~-3s ~2..0w~12.8.0f  .00000000  00000-0 ~8s 0  999", [
        Tle#tle.sat_num,
        Tle#tle.classification,
        Tle#tle.id_year rem 100,
        Tle#tle.id_launch,
        binary_to_list(Tle#tle.id_piece),
        ShortYear,
        Tle#tle.epoch_day,
        BstarFormatted
    ]),
    L1Flat = lists:flatten(Line1Prefix),
    L1Check = checksum(L1Flat),
    Line1 = io_lib:format("~s~w", [L1Flat, L1Check]),

    EccInt = trunc(Tle#tle.eccentricity * 10000000.0),
    Line2Prefix = io_lib:format("2 ~5..0w ~8.4f ~8.4f ~7..0w ~8.4f ~8.4f ~11.8f~5..0w", [
        Tle#tle.sat_num,
        Tle#tle.inclination * ?RAD_TO_DEG,
        Tle#tle.raan * ?RAD_TO_DEG,
        EccInt,
        Tle#tle.arg_perigee * ?RAD_TO_DEG,
        Tle#tle.mean_anomaly * ?RAD_TO_DEG,
        RevDay,
        Tle#tle.rev_num
    ]),
    L2Flat = lists:flatten(Line2Prefix),
    L2Check = checksum(L2Flat),
    Line2 = io_lib:format("~s~w", [L2Flat, L2Check]),

    {NameStr, lists:flatten(Line1), lists:flatten(Line2)}.

format_assumed_decimal(Val) when abs(Val) < 1.0e-12 ->
    " 00000-0";
format_assumed_decimal(Val) ->
    Sign = if Val < 0.0 -> "-"; true -> " " end,
    AbsVal = abs(Val),
    Exp = floor(math:log10(AbsVal)),
    Mantissa = AbsVal / math:pow(10.0, Exp),
    Mantissa5 = round(Mantissa * 10000.0),
    ExpVal = trunc(Exp) + 1,
    ExpSign = if ExpVal < 0 -> "-"; true -> "+" end,
    lists:flatten(io_lib:format("~s~5..0w~s~w", [Sign, Mantissa5, ExpSign, abs(ExpVal)])).
