%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc RFC 9171 & CCSDS Custody Transfer State Machine.
%%% Manages hop-by-hop custody transfer, custody acceptance/refusal signals,
%%% retransmission timers, and custody-cleared bundle releases.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_custody).
-behaviour(gen_server).

-include("apogee.hrl").

-export([
    start_link/1,
    stop/1,
    take_custody/3,
    register_transfer/4,
    process_signal/2,
    get_custody_count/1,
    check_timeouts/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(custody_entry, {
    bundle_id = <<>> :: binary(),
    bundle = #bpv7_bundle{} :: #bpv7_bundle{},
    next_hop = <<>> :: binary(),
    sent_time_ms = 0 :: non_neg_integer(),
    timeout_ms = 60000 :: non_neg_integer(),
    retransmit_count = 0 :: non_neg_integer()
}).

-record(state, {
    node_id = <<>> :: binary(),
    max_custody_bundles = 1000 :: non_neg_integer(),
    entries = #{} :: #{binary() => #custody_entry{}},
    accepted_count = 0 :: non_neg_integer(),
    refused_count = 0 :: non_neg_integer()
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-spec take_custody(pid(), #bpv7_bundle{}, non_neg_integer()) -> {accepted, binary()} | {refused, atom(), binary()}.
take_custody(Pid, Bundle, CurrentStorageBytes) ->
    gen_server:call(Pid, {take_custody, Bundle, CurrentStorageBytes}).

-spec register_transfer(pid(), #bpv7_bundle{}, binary() | string(), non_neg_integer()) -> ok.
register_transfer(Pid, Bundle, NextHop, TimeoutMs) ->
    gen_server:call(Pid, {register_transfer, Bundle, to_binary(NextHop), TimeoutMs}).

-spec process_signal(pid(), binary()) -> {ok, released} | {error, term()}.
process_signal(Pid, CustodySignalPayload) ->
    gen_server:call(Pid, {process_signal, CustodySignalPayload}).

-spec get_custody_count(pid()) -> non_neg_integer().
get_custody_count(Pid) ->
    gen_server:call(Pid, get_custody_count).

-spec check_timeouts(pid(), non_neg_integer()) -> {ok, [#bpv7_bundle{}]}.
check_timeouts(Pid, NowMs) ->
    gen_server:call(Pid, {check_timeouts, NowMs}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    NodeId = maps:get(node_id, Opts, <<"ipn:1.1">>),
    MaxBundles = maps:get(max_custody_bundles, Opts, 1000),
    {ok, #state{
        node_id = to_binary(NodeId),
        max_custody_bundles = MaxBundles,
        entries = #{},
        accepted_count = 0,
        refused_count = 0
    }}.

handle_call({take_custody, Bundle, CurrentStorageBytes}, _From, State) ->
    BundleId = bundle_unique_id(Bundle),
    MaxBytes = 100000000, % 100 MB threshold
    CurrentCount = maps:size(State#state.entries),
    if
        CurrentCount >= State#state.max_custody_bundles ->
            Signal = encode_custody_signal(BundleId, false, depleted_storage, State#state.node_id),
            NewState = State#state{refused_count = State#state.refused_count + 1},
            {reply, {refused, depleted_storage, Signal}, NewState};
        CurrentStorageBytes >= MaxBytes ->
            Signal = encode_custody_signal(BundleId, false, storage_limit_exceeded, State#state.node_id),
            NewState = State#state{refused_count = State#state.refused_count + 1},
            {reply, {refused, storage_limit_exceeded, Signal}, NewState};
        true ->
            Signal = encode_custody_signal(BundleId, true, accepted, State#state.node_id),
            NewState = State#state{accepted_count = State#state.accepted_count + 1},
            {reply, {accepted, Signal}, NewState}
    end;

handle_call({register_transfer, Bundle, NextHop, TimeoutMs}, _From, State) ->
    BundleId = bundle_unique_id(Bundle),
    NowMs = apogee_time:now_unix_ms(),
    Entry = #custody_entry{
        bundle_id = BundleId,
        bundle = Bundle,
        next_hop = NextHop,
        sent_time_ms = NowMs,
        timeout_ms = TimeoutMs,
        retransmit_count = 0
    },
    NewEntries = maps:put(BundleId, Entry, State#state.entries),
    {reply, ok, State#state{entries = NewEntries}};

handle_call({process_signal, SignalPayload}, _From, State) ->
    case decode_custody_signal(SignalPayload) of
        {ok, BundleId, true, _Reason, _Custodian} ->
            %% Custody successfully accepted by downstream node: release bundle!
            case maps:find(BundleId, State#state.entries) of
                {ok, _Entry} ->
                    NewEntries = maps:remove(BundleId, State#state.entries),
                    {reply, {ok, released}, State#state{entries = NewEntries}};
                error ->
                    {reply, {error, unknown_custody_bundle}, State}
            end;
        {ok, BundleId, false, Reason, _Custodian} ->
            %% Custody refused: trigger retransmission or routing deflection
            {reply, {error, {custody_refused, Reason, BundleId}}, State};
        {error, Err} ->
            {reply, {error, Err}, State}
    end;

handle_call(get_custody_count, _From, State) ->
    {reply, maps:size(State#state.entries), State};

handle_call({check_timeouts, NowMs}, _From, State) ->
    {TimedOutEntries, RetainedEntries} = maps:fold(fun(Id, Entry, {ExpiredAcc, RetainedAcc}) ->
        IsExpired = (NowMs - Entry#custody_entry.sent_time_ms) >= Entry#custody_entry.timeout_ms,
        case IsExpired of
            true ->
                UpdatedEntry = Entry#custody_entry{
                    sent_time_ms = NowMs,
                    retransmit_count = Entry#custody_entry.retransmit_count + 1
                },
                {[Entry#custody_entry.bundle | ExpiredAcc], RetainedAcc#{Id => UpdatedEntry}};
            false ->
                {ExpiredAcc, RetainedAcc#{Id => Entry}}
        end
    end, {[], #{}}, State#state.entries),
    {reply, {ok, TimedOutEntries}, State#state{entries = RetainedEntries}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal Helpers
%%====================================================================

bundle_unique_id(#bpv7_bundle{} = B) ->
    << (B#bpv7_bundle.source)/binary, "-",
       (integer_to_binary(B#bpv7_bundle.creation_time))/binary, "-",
       (integer_to_binary(B#bpv7_bundle.sequence_number))/binary >>.

encode_custody_signal(BundleId, Accepted, Reason, CustodianNode) ->
    apogee_cbor:encode([
        BundleId,
        Accepted,
        atom_to_binary(Reason, utf8),
        CustodianNode,
        apogee_time:now_unix_ms()
    ]).

decode_custody_signal(Binary) ->
    case apogee_cbor:decode_one(Binary) of
        {ok, [BundleId, Accepted, ReasonBin, CustodianNode, _Ts]} ->
            Reason = binary_to_existing_atom(ReasonBin, utf8),
            {ok, BundleId, Accepted, Reason, CustodianNode};
        _ ->
            {error, invalid_custody_signal}
    end.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).
