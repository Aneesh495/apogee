%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Real-Time Spacecraft Mission Control Telemetry Dashboard (TUI).
%%% Renders a comprehensive multi-panel terminal operations console:
%%% - Ephemeris, altitude, velocity, and sub-satellite coordinates
%%% - Electrical Power System (EPS) battery state-of-charge bars and bus voltage
%%% - Attitude Determination and Control System (ADCS) reaction wheel RPM
%%% - Delay-Tolerant Networking (DTN) bundle storage and CGR contact metrics
%%% - Autonomous FDIR flight safety rule monitors and alarms
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_tui).

-behaviour(gen_server).

-include("apogee.hrl").

-export([
    render_dashboard/1,
    render_dashboard_plain/1,
    progress_bar/3,
    status_badge/1,
    box_panel/3,
    start_link/0,
    start_link/1,
    stop/0,
    stop/1,
    update_telemetry/1,
    update_telemetry/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% ANSI Colors
-define(C_RESET,  "\e[0m").
-define(C_BOLD,   "\e[1m").
-define(C_CYAN,   "\e[36m").
-define(C_GREEN,  "\e[32m").
-define(C_YELLOW, "\e[33m").
-define(C_RED,    "\e[31m").
-define(C_BLUE,   "\e[34m").
-define(C_DIM,    "\e[2m").

-record(state, {
    telemetry = #{} :: map(),
    refresh_ms = 1000 :: pos_integer(),
    timer_ref = undefined :: reference() | undefined
}).

-define(SERVER, ?MODULE).

%%====================================================================
%% API Functions
%%====================================================================

-spec render_dashboard(map()) -> string().
render_dashboard(Telemetry) ->
    render_screen(Telemetry, true).

-spec render_dashboard_plain(map()) -> string().
render_dashboard_plain(Telemetry) ->
    render_screen(Telemetry, false).

-spec progress_bar(float(), pos_integer(), string()) -> string().
progress_bar(Fraction, Width, FillChar) ->
    Clamped = max(0.0, min(1.0, float(Fraction))),
    FilledCount = round(Clamped * float(Width)),
    EmptyCount = Width - FilledCount,
    lists:flatten([
        "[",
        lists:duplicate(FilledCount, FillChar),
        lists:duplicate(EmptyCount, " "),
        "]"
    ]).

-spec status_badge(nominal | warning | critical | safe_hold) -> string().
status_badge(nominal)   -> ?C_GREEN ++ "[ NOMINAL ]" ++ ?C_RESET;
status_badge(warning)   -> ?C_YELLOW ++ "[ WARNING ]" ++ ?C_RESET;
status_badge(critical)  -> ?C_RED ++ "[ CRITICAL ]" ++ ?C_RESET;
status_badge(safe_hold) -> ?C_YELLOW ++ "[ SAFE_HOLD ]" ++ ?C_RESET;
status_badge(_)         -> "[ UNKNOWN ]".

-spec box_panel(string(), [string()], pos_integer()) -> [string()].
box_panel(Title, Lines, Width) ->
    TitleLen = length(Title),
    PadLen = max(0, Width - TitleLen - 5),
    Header = "+- " ++ Title ++ " " ++ lists:duplicate(PadLen, "-") ++ "+",
    Footer = "+" ++ lists:duplicate(Width - 2, "-") ++ "+",
    Body = [
        begin
            LineLen = length(strip_ansi(L)),
            Spaces = max(0, Width - LineLen - 4),
            "| " ++ L ++ lists:duplicate(Spaces, " ") ++ " |"
        end
        || L <- Lines
    ],
    [Header | Body] ++ [Footer].

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(InitialTelemetry) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [InitialTelemetry], []).

-spec stop() -> ok.
stop() ->
    stop(?SERVER).

-spec stop(pid() | atom()) -> ok.
stop(Server) ->
    gen_server:stop(Server).

-spec update_telemetry(map()) -> ok.
update_telemetry(Telemetry) ->
    update_telemetry(?SERVER, Telemetry).

-spec update_telemetry(pid() | atom(), map()) -> ok.
update_telemetry(Server, Telemetry) ->
    gen_server:cast(Server, {update_telemetry, Telemetry}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([InitialTelemetry]) ->
    {ok, #state{
        telemetry = InitialTelemetry,
        refresh_ms = 1000,
        timer_ref = undefined
    }}.

handle_call(get_telemetry, _From, State) ->
    {reply, State#state.telemetry, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({update_telemetry, NewTelemetry}, State) ->
    Merged = maps:merge(State#state.telemetry, NewTelemetry),
    {noreply, State#state{telemetry = Merged}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal Screen Renderer
%%====================================================================

render_screen(Telem, UseColor) ->
    SatName = maps:get(sat_name, Telem, "APOGEE-1"),
    MetStr = maps:get(met_str, Telem, "+002:14:32:08.5"),
    Mode = maps:get(flight_mode, Telem, nominal),
    AltKm = maps:get(altitude_km, Telem, 550.2),
    VelKmS = maps:get(velocity_km_s, Telem, 7.589),
    LatDeg = maps:get(latitude_deg, Telem, 28.57),
    LonDeg = maps:get(longitude_deg, Telem, -80.65),

    Soc = maps:get(battery_soc, Telem, 0.88),
    BusV = maps:get(bus_voltage, Telem, 28.1),
    SolarW = maps:get(solar_power_w, Telem, 142.5),
    BatTempC = maps:get(battery_temp_c, Telem, 19.4),

    WheelX = maps:get(wheel_rpm_x, Telem, 2400),
    WheelY = maps:get(wheel_rpm_y, Telem, 1850),
    WheelZ = maps:get(wheel_rpm_z, Telem, 3100),
    PointingErrDeg = maps:get(pointing_err_deg, Telem, 0.042),

    BundlesQueued = maps:get(bundles_queued, Telem, 48),
    StorageUsedMb = maps:get(storage_used_mb, Telem, 128.4),
    ActiveContacts = maps:get(active_contacts, Telem, 2),
    FdirAlarms = maps:get(fdir_alarms, Telem, 0),

    Width = 80,
    SepLine = lists:duplicate(Width, "="),
    
    HeaderLine1 = io_lib:format("  ~s~s MISSION CONTROL TERMINAL :: MET ~s~s", [
        color_if(UseColor, ?C_BOLD ++ ?C_CYAN),
        SatName,
        MetStr,
        color_if(UseColor, ?C_RESET)
    ]),
    HeaderLine2 = io_lib:format("  MODE: ~s | FDIR ALARMS: ~p | ACTIVE CONTACTS: ~p", [
        format_badge_text(Mode, UseColor),
        FdirAlarms,
        ActiveContacts
    ]),

    OrbitLines = [
        io_lib:format("Altitude:     ~7.2f km       Velocity:     ~6.3f km/s", [AltKm, VelKmS]),
        io_lib:format("Latitude:     ~7.2f deg      Longitude:    ~7.2f deg", [LatDeg, LonDeg])
    ],
    OrbitPanel = box_panel("ORBIT & EPHEMERIS", OrbitLines, Width),

    SocBar = progress_bar(Soc, 20, "="),
    EpsLines = [
        io_lib:format("Battery SoC:  ~s ~5.1f%", [SocBar, Soc * 100.0]),
        io_lib:format("Bus Voltage:  ~5.1f V          Solar Power:  ~5.1f W", [BusV, SolarW]),
        io_lib:format("Battery Temp: ~5.1f deg C", [BatTempC])
    ],
    EpsPanel = box_panel("ELECTRICAL POWER SYSTEM (EPS)", EpsLines, Width),

    AdcsLines = [
        io_lib:format("Reaction Wheels: [X: ~4w rpm | Y: ~4w rpm | Z: ~4w rpm]", [WheelX, WheelY, WheelZ]),
        io_lib:format("Pointing Error:  ~6.3f deg (Requirement: < 0.100 deg)", [PointingErrDeg])
    ],
    AdcsPanel = box_panel("ATTITUDE DETERMINATION & CONTROL (ADCS)", AdcsLines, Width),

    DtnLines = [
        io_lib:format("Bundles Queued:  ~4w bundles    Storage Used:  ~6.1f MB", [BundlesQueued, StorageUsedMb]),
        io_lib:format("CGR Router:      ACTIVE           Custody Trans: ENABLED", [])
    ],
    DtnPanel = box_panel("DELAY-TOLERANT NETWORKING (RFC 9171 / CGR)", DtnLines, Width),

    AllLines = [
        SepLine,
        lists:flatten(HeaderLine1),
        lists:flatten(HeaderLine2),
        SepLine
    ] ++ OrbitPanel ++ EpsPanel ++ AdcsPanel ++ DtnPanel ++ [SepLine],

    string:join(AllLines, "\n").

format_badge_text(Mode, true) ->
    status_badge(Mode);
format_badge_text(Mode, false) ->
    case Mode of
        nominal -> "[ NOMINAL ]";
        warning -> "[ WARNING ]";
        critical -> "[ CRITICAL ]";
        safe_hold -> "[ SAFE_HOLD ]";
        Other -> io_lib:format("[ ~p ]", [Other])
    end.

color_if(true, Code) -> Code;
color_if(false, _Code) -> "".

strip_ansi(String) ->
    re:replace(String, "\e\\[[0-9;]*m", "", [global, {return, list}]).
