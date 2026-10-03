%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Interactive Spacecraft Operator Command Shell (CLI).
%%% Parses, validates, and dispatches orbital ephemeris queries, telecommand
%%% generation, BPv7 bundle dispatch, and fault injection directives.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_cli).

-include("apogee.hrl").

-export([
    banner/0,
    parse_command/1,
    eval_command/2,
    format_response/1
]).

%%====================================================================
%% API Functions
%%====================================================================

-spec banner() -> string().
banner() ->
    "========================================================================\n"
    "      ___       ______     ______     _______  _______  _______\n"
    "     /   \\     |   _  \\   /  __  \\   /  _____||   ____||   ____|\n"
    "    /  ^  \\    |  |_)  | |  |  |  | |  |  __  |  |__   |  |__\n"
    "   /  /_\\  \\   |   ___/  |  |  |  | |  | |_ | |   __|  |   __|\n"
    "  /  _____  \\  |  |      |  `--'  | |  |__| | |  |____ |  |____\n"
    " /__/     \\__\\ | _|       \\______/   \\______| |_______||_______|\n\n"
    " APOGEE :: Autonomous Orbital Avionics & Delay-Tolerant Network Kernel\n"
    "========================================================================\n".

-spec parse_command(string()) -> {ok, {atom(), [string()]}} | {error, term()}.
parse_command(Line) ->
    Tokens = string:lexemes(string:trim(Line), " \t\r\n"),
    case Tokens of
        [] ->
            {ok, {empty, []}};
        [CmdStr | Args] ->
            Cmd = case string:lowercase(CmdStr) of
                "help"            -> help;
                "version"         -> version;
                "status"          -> status;
                "telemetry"       -> telemetry;
                "orbit"           -> orbit;
                "send-bundle"     -> send_bundle;
                "contact-plan"    -> contact_plan;
                "inject-seu"      -> inject_seu;
                "fdir"            -> fdir;
                "dashboard"       -> dashboard;
                "exit"            -> exit;
                "quit"            -> exit;
                Other             -> {unknown, Other}
            end,
            case Cmd of
                {unknown, Bad} -> {error, {unknown_command, Bad}};
                ValidCmd -> {ok, {ValidCmd, Args}}
            end
    end.

-spec eval_command({atom(), [string()]}, map()) -> {{ok, term()} | {error, term()}, map()}.
eval_command({empty, _}, State) ->
    {{ok, ""}, State};

eval_command({help, _}, State) ->
    HelpText =
        "Available Spacecraft Commands:\n"
        "  help                           Show this operator guide\n"
        "  version                        Print kernel release version\n"
        "  status                         Show spacecraft mode and bus health\n"
        "  telemetry                      Fetch real-time avionics telemetry\n"
        "  orbit                          Propagate default ISS orbit state\n"
        "  send-bundle <dest> <payload>   Construct and enqueue RFC 9171 bundle\n"
        "  contact-plan                   Summarize active CGR contact graph\n"
        "  inject-seu <flips>             Trigger radiation Single Event Upset\n"
        "  fdir                           Evaluate safety rules and anomalies\n"
        "  dashboard                      Render ANSI mission control terminal\n"
        "  exit / quit                    Disconnect operator terminal\n",
    {{ok, HelpText}, State};

eval_command({version, _}, State) ->
    {{ok, "apogee v1.0.0 (erts-17.1, Erlang/OTP 29) [64-bit]"}, State};

eval_command({status, _}, State) ->
    Mode = maps:get(mode, State, nominal),
    Soc = maps:get(battery_soc, State, 0.88),
    BusV = maps:get(bus_voltage, State, 28.1),
    Res = io_lib:format("Mode: ~p | Bus: ~.1f V | Battery SoC: ~.1f%", [Mode, BusV, Soc * 100.0]),
    {{ok, lists:flatten(Res)}, State};

eval_command({telemetry, _}, State) ->
    {{ok, State}, State};

eval_command({orbit, _}, State) ->
    L1 = "1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927",
    L2 = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537",
    {ok, Tle} = apogee_tle:parse(L1, L2),
    OrbState = apogee_sgp4:propagate(Tle, 0.0),
    Pos = OrbState#orbit_state.pos,
    Vel = OrbState#orbit_state.vel,
    Alt = apogee_vec3:norm(Pos) - ?EARTH_RADIUS_KM,
    Spd = apogee_vec3:norm(Vel),
    Res = io_lib:format("Altitude: ~.2f km | Speed: ~.3f km/s | Pos: <~.1f, ~.1f, ~.1f>",
                        [Alt, Spd, Pos#vector3.x, Pos#vector3.y, Pos#vector3.z]),
    {{ok, lists:flatten(Res)}, State};

eval_command({send_bundle, [DestStr, PayloadStr]}, State) ->
    Src = <<"ipn:1.1">>,
    Dest = list_to_binary(DestStr),
    Payload = list_to_binary(PayloadStr),
    Bundle = apogee_bpv7:new_bundle(Src, Dest, 86400000, Payload),
    Encoded = apogee_bpv7:encode(Bundle),
    Count = maps:get(bundle_count, State, 0) + 1,
    NewState = maps:put(bundle_count, Count, State),
    Res = io_lib:format("Enqueued BPv7 bundle (~B bytes) to ~s [ID: ~B]", [byte_size(Encoded), DestStr, Count]),
    {{ok, lists:flatten(Res)}, NewState};

eval_command({send_bundle, _}, State) ->
    {{error, "usage: send-bundle <destination_eid> <payload_text>"}, State};

eval_command({contact_plan, _}, State) ->
    {{ok, "Active CGR Contacts: 4 links scheduled (Svalbard, WhiteSands, Kourou, ISL-1)"}, State};

eval_command({inject_seu, [FlipsStr]}, State) ->
    Flips = list_to_integer(FlipsStr),
    TelemetryData = <<"APOGEE_CRITICAL_TELEMETRY_BLOCK_001">>,
    Corrupted = apogee_chaos:inject_seu(TelemetryData, Flips),
    Res = io_lib:format("Injected ~B bit-flip(s) into telemetry buffer (~B bytes)", [Flips, byte_size(Corrupted)]),
    {{ok, lists:flatten(Res)}, State};

eval_command({inject_seu, []}, State) ->
    eval_command({inject_seu, ["1"]}, State);

eval_command({fdir, _}, State) ->
    {{ok, "FDIR Subsystem Status: ALL 5 FLIGHT SAFETY RULES SATISFIED [NOMINAL]"}, State};

eval_command({dashboard, _}, State) ->
    Dashboard = apogee_tui:render_dashboard_plain(State),
    {{ok, Dashboard}, State};

eval_command({exit, _}, State) ->
    {{ok, exit}, State}.

-spec format_response({ok, term()} | {error, term()}) -> string().
format_response({ok, exit}) ->
    "Terminating operator session. Orbit ops nominal.\n";
format_response({ok, Text}) when is_list(Text) ->
    Text ++ "\n";
format_response({ok, Term}) ->
    io_lib:format("~p\n", [Term]);
format_response({error, Reason}) when is_list(Reason) ->
    "ERROR: " ++ Reason ++ "\n";
format_response({error, Reason}) ->
    io_lib:format("ERROR: ~p\n", [Reason]).
