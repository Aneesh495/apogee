%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc CCSDS 232.1-B-2 Frame Acceptance and Reporting Mechanism (FARM-1).
%%% Formal gen_statem finite state machine implementing COP-1 protocol
%%% with Open, Wait, and Lockout states, sliding-window sequence checks,
%%% expedited service, and CLCW telemetry generation.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_cop1).
-behaviour(gen_statem).

-include("apogee.hrl").

%% API
-export([
    start_link/1,
    stop/1,
    process_frame/2,
    get_clcw/1,
    get_state/1,
    set_wait/2
]).

%% gen_statem callbacks
-export([
    callback_mode/0,
    init/1,
    terminate/3,
    code_change/4,
    open/3,
    wait/3,
    lockout/3
]).

-record(farm_data, {
    scid = 0 :: 0..1023,
    vcid = 0 :: 0..63,
    vr = 0 :: 0..255,                 % V(R) next expected sequence number
    sliding_window_w = 10 :: 1..127,  % Window width W
    farm_b_counter = 0 :: 0..3,       % Counter for expedited frames
    retransmit = false :: boolean(),
    received_packets = [] :: [binary()]
}).

-define(CONTROL_CMD_UNLOCK, 16#00).
-define(CONTROL_CMD_SET_VR, 16#01).

%%====================================================================
%% API
%%====================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid).

-spec process_frame(pid(), #tc_frame{}) -> {accepted, binary()} | {duplicate, 0..255} | {rejected, atom()}.
process_frame(Pid, #tc_frame{} = Frame) ->
    gen_statem:call(Pid, {process_frame, Frame}).

-spec get_clcw(pid()) -> #clcw{}.
get_clcw(Pid) ->
    gen_statem:call(Pid, get_clcw).

-spec get_state(pid()) -> {atom(), 0..255}.
get_state(Pid) ->
    gen_statem:call(Pid, get_state).

-spec set_wait(pid(), boolean()) -> ok.
set_wait(Pid, EnableWait) ->
    gen_statem:call(Pid, {set_wait, EnableWait}).

%%====================================================================
%% gen_statem Callbacks
%%====================================================================

callback_mode() ->
    state_functions.

init(Opts) ->
    SCID = maps:get(scid, Opts, 0),
    VCID = maps:get(vcid, Opts, 0),
    InitialVR = maps:get(initial_vr, Opts, 0),
    WindowW = maps:get(window_w, Opts, 10),
    Data = #farm_data{
        scid = SCID,
        vcid = VCID,
        vr = InitialVR,
        sliding_window_w = WindowW,
        farm_b_counter = 0,
        retransmit = false,
        received_packets = []
    },
    {ok, open, Data}.

%%--------------------------------------------------------------------
%% State: OPEN
%%--------------------------------------------------------------------
open({call, From}, {process_frame, #tc_frame{control_cmd_flag = 1} = Frame}, Data) ->
    handle_control_command(From, Frame, Data, open);

open({call, From}, {process_frame, #tc_frame{bypass_flag = 1} = Frame}, Data) ->
    %% Expedited (BD) service: bypass sequence checks
    NewFarmB = (Data#farm_data.farm_b_counter + 1) rem 4,
    NewData = Data#farm_data{
        farm_b_counter = NewFarmB,
        received_packets = [Frame#tc_frame.data | Data#farm_data.received_packets]
    },
    {keep_state, NewData, [{reply, From, {accepted, Frame#tc_frame.data}}]};

open({call, From}, {process_frame, #tc_frame{bypass_flag = 0} = Frame}, Data) ->
    %% Sequence-Controlled (AD) service: verify N(S) against V(R) and window W
    NS = Frame#tc_frame.frame_seq_num,
    VR = Data#farm_data.vr,
    W = Data#farm_data.sliding_window_w,

    if
        NS =:= VR ->
            %% In-sequence frame: accept and advance V(R)
            NextVR = (VR + 1) rem 256,
            NewData = Data#farm_data{
                vr = NextVR,
                retransmit = false,
                received_packets = [Frame#tc_frame.data | Data#farm_data.received_packets]
            },
            {keep_state, NewData, [{reply, From, {accepted, Frame#tc_frame.data}}]};

        true ->
            case is_in_retransmit_window(NS, VR, W) of
                true ->
                    %% Frame inside window [V(R) - W, V(R) - 1]: duplicate retransmission
                    NewData = Data#farm_data{retransmit = true},
                    {keep_state, NewData, [{reply, From, {duplicate, VR}}]};
                false ->
                    case is_in_forward_window(NS, VR, W) of
                        true ->
                            %% Frame inside window [V(R) + 1, V(R) + W]: missed frame, request retransmission
                            NewData = Data#farm_data{retransmit = true},
                            {keep_state, NewData, [{reply, From, {rejected, frame_gap}}]};
                        false ->
                            %% Sequence number outside window: sequence anomaly, enter LOCKOUT!
                            NewData = Data#farm_data{retransmit = true},
                            {next_state, lockout, NewData, [{reply, From, {rejected, lockout_anomaly}}]}
                    end
            end
    end;

open({call, From}, get_clcw, Data) ->
    CLCW = build_clcw(Data, false, false),
    {keep_state_and_data, [{reply, From, CLCW}]};

open({call, From}, get_state, Data) ->
    {keep_state_and_data, [{reply, From, {open, Data#farm_data.vr}}]};

open({call, From}, {set_wait, true}, Data) ->
    {next_state, wait, Data, [{reply, From, ok}]};
open({call, From}, {set_wait, false}, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]}.

%%--------------------------------------------------------------------
%% State: WAIT
%%--------------------------------------------------------------------
wait({call, From}, {process_frame, #tc_frame{control_cmd_flag = 1} = Frame}, Data) ->
    handle_control_command(From, Frame, Data, wait);

wait({call, From}, {process_frame, #tc_frame{bypass_flag = 1} = Frame}, Data) ->
    %% Expedited frames accepted in wait state
    NewFarmB = (Data#farm_data.farm_b_counter + 1) rem 4,
    NewData = Data#farm_data{
        farm_b_counter = NewFarmB,
        received_packets = [Frame#tc_frame.data | Data#farm_data.received_packets]
    },
    {keep_state, NewData, [{reply, From, {accepted, Frame#tc_frame.data}}]};

wait({call, From}, {process_frame, #tc_frame{bypass_flag = 0}}, _Data) ->
    %% Sequence-controlled frames rejected in wait state
    {keep_state_and_data, [{reply, From, {rejected, wait_buffer_full}}]};

wait({call, From}, get_clcw, Data) ->
    CLCW = build_clcw(Data, false, true),
    {keep_state_and_data, [{reply, From, CLCW}]};

wait({call, From}, get_state, Data) ->
    {keep_state_and_data, [{reply, From, {wait, Data#farm_data.vr}}]};

wait({call, From}, {set_wait, false}, Data) ->
    {next_state, open, Data, [{reply, From, ok}]};
wait({call, From}, {set_wait, true}, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]}.

%%--------------------------------------------------------------------
%% State: LOCKOUT
%%--------------------------------------------------------------------
lockout({call, From}, {process_frame, #tc_frame{control_cmd_flag = 1} = Frame}, Data) ->
    handle_control_command(From, Frame, Data, lockout);

lockout({call, From}, {process_frame, #tc_frame{bypass_flag = 1} = Frame}, Data) ->
    %% Expedited frames are processed even during lockout
    NewFarmB = (Data#farm_data.farm_b_counter + 1) rem 4,
    NewData = Data#farm_data{
        farm_b_counter = NewFarmB,
        received_packets = [Frame#tc_frame.data | Data#farm_data.received_packets]
    },
    {keep_state, NewData, [{reply, From, {accepted, Frame#tc_frame.data}}]};

lockout({call, From}, {process_frame, #tc_frame{bypass_flag = 0}}, _Data) ->
    %% All sequence-controlled frames rejected in lockout state
    {keep_state_and_data, [{reply, From, {rejected, in_lockout}}]};

lockout({call, From}, get_clcw, Data) ->
    CLCW = build_clcw(Data, true, false),
    {keep_state_and_data, [{reply, From, CLCW}]};

lockout({call, From}, get_state, Data) ->
    {keep_state_and_data, [{reply, From, {lockout, Data#farm_data.vr}}]};

lockout({call, From}, {set_wait, _}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, in_lockout}}]}.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%====================================================================
%% Internal Helpers
%%====================================================================

handle_control_command(From, Frame, Data, _CurrentState) ->
    case Frame#tc_frame.data of
        <<?CONTROL_CMD_UNLOCK>> ->
            %% UNLOCK control command: recovers from lockout
            NewData = Data#farm_data{retransmit = false},
            {next_state, open, NewData, [{reply, From, {accepted, unlocked}}]};

        <<?CONTROL_CMD_SET_VR, NewVR:8/unsigned>> ->
            %% SET V(R) control command: overrides receiver sequence counter
            NewData = Data#farm_data{vr = NewVR, retransmit = false},
            {next_state, open, NewData, [{reply, From, {accepted, {set_vr, NewVR}}}]};

        _ ->
            {keep_state_and_data, [{reply, From, {rejected, unknown_control_command}}]}
    end.

is_in_retransmit_window(NS, VR, W) ->
    Diff = (VR - NS + 256) rem 256,
    Diff >= 1 andalso Diff =< W.

is_in_forward_window(NS, VR, W) ->
    Diff = (NS - VR + 256) rem 256,
    Diff >= 1 andalso Diff =< W.

build_clcw(Data, Lockout, Wait) ->
    #clcw{
        version = 0,
        status_field = 0,
        cop_in_effect = 1,
        vcid = Data#farm_data.vcid,
        no_rf = false,
        no_bit_lock = false,
        lockout = Lockout,
        wait = Wait,
        retransmit = Data#farm_data.retransmit,
        farm_b_counter = Data#farm_data.farm_b_counter,
        report_value = Data#farm_data.vr
    }.
