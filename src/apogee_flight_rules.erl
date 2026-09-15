%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc NASA/ESA Flight Rules and Autonomous FDIR Safety Engine.
%%% Evaluates operational constraints and triggers autonomous fault recovery:
%%% - FR_EPS_01: Battery Depth-of-Discharge limits (DoD <= 80%)
%%% - FR_EPS_02: Bus voltage operational envelope (22.0V - 32.0V)
%%% - FR_THERM_01: Battery qualification temperatures (-10C to +45C)
%%% - FR_ADCS_01: Maximum spacecraft tumbling angular rate (<= 0.2 rad/s)
%%% - FR_ADCS_02: Reaction wheel angular momentum saturation threshold (<= 5500 RPM)
%%% - FR_COMM_01: Autonomous watchdog command loss timeout (<= 72 hours)
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_flight_rules).

-include("apogee.hrl").

-export([
    check_telemetry/1,
    evaluate_health/1,
    recommended_action/1,
    all_rules/0
]).

-record(flight_rule, {
    id :: atom(),
    name :: binary(),
    severity :: warning | critical,
    condition :: fun((map()) -> boolean()),
    action :: none | safe_hold | detumble | desaturate | shed_payload | cycle_radio
}).

-type violation() :: {atom(), warning | critical, binary(), atom()}.
-export_type([violation/0]).

%%====================================================================
%% API Functions
%%====================================================================

-spec all_rules() -> [#flight_rule{}].
all_rules() ->
    [
        #flight_rule{
            id = fr_eps_01,
            name = <<"Battery Depth-of-Discharge Limit">>,
            severity = critical,
            condition = fun(T) -> maps:get(battery_soc, T, 1.0) < 0.20 end,
            action = safe_hold
        },
        #flight_rule{
            id = fr_eps_02,
            name = <<"Bus Voltage Out-of-Bounds">>,
            severity = warning,
            condition = fun(T) ->
                V = maps:get(bus_voltage, T, 28.0),
                V < 22.0 orelse V > 32.0
            end,
            action = safe_hold
        },
        #flight_rule{
            id = fr_therm_01,
            name = <<"Battery Temperature Limit Exceeded">>,
            severity = critical,
            condition = fun(T) ->
                Temps = maps:get(temp_c, T, #{}),
                BattT = maps:get(battery, Temps, 20.0),
                BattT < -10.0 orelse BattT > 45.0
            end,
            action = shed_payload
        },
        #flight_rule{
            id = fr_adcs_01,
            name = <<"Excessive Spacecraft Tumbling Rate">>,
            severity = warning,
            condition = fun(T) ->
                case maps:find(angular_velocity, T) of
                    {ok, #vector3{} = Omega} ->
                        apogee_vec3:norm(Omega) > 0.20; % > 11.5 deg/s
                    _ ->
                        false
                end
            end,
            action = detumble
        },
        #flight_rule{
            id = fr_adcs_02,
            name = <<"Reaction Wheel Saturation Threat">>,
            severity = warning,
            condition = fun(T) ->
                case maps:find(wheel_speed_rpm, T) of
                    {ok, #vector3{} = RPM} ->
                        max(abs(RPM#vector3.x), max(abs(RPM#vector3.y), abs(RPM#vector3.z))) > 5500.0;
                    _ ->
                        false
                end
            end,
            action = desaturate
        },
        #flight_rule{
            id = fr_comm_01,
            name = <<"Command Watchdog Loss Timeout">>,
            severity = critical,
            condition = fun(T) ->
                maps:get(command_loss_s, T, 0) > 259200 % > 72 hours
            end,
            action = cycle_radio
        }
    ].

-spec check_telemetry(map()) -> [violation()].
check_telemetry(Telem) ->
    Rules = all_rules(),
    lists:filtermap(
        fun(#flight_rule{id = Id, severity = Sev, name = Name, condition = Cond, action = Act}) ->
            case Cond(Telem) of
                true ->
                    {true, {Id, Sev, Name, Act}};
                false ->
                    false
            end
        end,
        Rules
    ).

-spec evaluate_health(map()) -> nominal | warning | critical.
evaluate_health(Telem) ->
    Violations = check_telemetry(Telem),
    Severities = [Sev || {_Id, Sev, _Name, _Act} <- Violations],
    case lists:member(critical, Severities) of
        true -> critical;
        false ->
            case lists:member(warning, Severities) of
                true -> warning;
                false -> nominal
            end
    end.

-spec recommended_action(map()) -> none | safe_hold | detumble | desaturate | shed_payload | cycle_radio.
recommended_action(Telem) ->
    Violations = check_telemetry(Telem),
    Actions = [Act || {_Id, _Sev, _Name, Act} <- Violations],
    PriorityOrder = [safe_hold, shed_payload, cycle_radio, detumble, desaturate],
    find_first_action(PriorityOrder, Actions).

find_first_action([], _Actions) -> none;
find_first_action([P | Rest], Actions) ->
    case lists:member(P, Actions) of
        true -> P;
        false -> find_first_action(Rest, Actions)
    end.
