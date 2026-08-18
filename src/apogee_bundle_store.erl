%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Log-Structured Flash-Friendly Bundle Vault for Satellite Payloads.
%%% Stores serialized DTN bundles with append-only segment writing,
%%% in-memory ETS indexing, destination routing lookups, TTL-based eviction,
%%% and online garbage collection compaction.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_bundle_store).

-behaviour(gen_server).

-include("apogee.hrl").

%% API
-export([
    start_link/1,
    start_link/2,
    put_bundle/2,
    get_bundle/2,
    delete_bundle/2,
    list_bundles/1,
    find_by_destination/2,
    evict_expired/2,
    compact/1,
    total_stored_bytes/1,
    close/1,
    stop/1
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

-define(BUNDLE_VAULT_MAGIC, 16#42564C54). % "BVLT"

-record(index_entry, {
    key :: tuple(), % {Source, CreationTime, SeqNum, FragOffset}
    offset :: non_neg_integer(),
    length :: non_neg_integer(),
    expiry :: non_neg_integer(),
    destination :: binary(),
    deleted = false :: boolean()
}).

-record(state, {
    dir :: file:filename_all(),
    data_file :: file:filename_all(),
    io_device :: file:io_device() | undefined,
    current_offset = 0 :: non_neg_integer(),
    index_tab :: ets:tid() | undefined,
    total_bytes = 0 :: non_neg_integer()
}).

%%====================================================================
%% API
%%====================================================================

start_link(Dir) ->
    start_link(Dir, []).

start_link(Dir, Opts) ->
    gen_server:start_link(?MODULE, {Dir, Opts}, []).

put_bundle(Server, #bpv7_bundle{} = Bundle) ->
    gen_server:call(Server, {put_bundle, Bundle}).

get_bundle(Server, BundleKey) ->
    gen_server:call(Server, {get_bundle, BundleKey}).

delete_bundle(Server, BundleKey) ->
    gen_server:call(Server, {delete_bundle, BundleKey}).

list_bundles(Server) ->
    gen_server:call(Server, list_bundles).

find_by_destination(Server, DestNode) ->
    gen_server:call(Server, {find_by_destination, to_binary(DestNode)}).

evict_expired(Server, NowTimeMs) ->
    gen_server:call(Server, {evict_expired, NowTimeMs}).

compact(Server) ->
    gen_server:call(Server, compact).

total_stored_bytes(Server) ->
    gen_server:call(Server, total_stored_bytes).

close(Server) ->
    stop(Server).

stop(Server) ->
    gen_server:stop(Server).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({Dir, _Opts}) ->
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    DataFile = filename:join(Dir, "vault.data"),
    IndexTab = ets:new(apogee_bundle_store_idx, [set, private, {keypos, #index_entry.key}]),
    {Offset, TotalBytes} = recover_index(DataFile, IndexTab),
    {ok, Fd} = file:open(DataFile, [read, write, binary, raw, append]),
    State = #state{
        dir = Dir,
        data_file = DataFile,
        io_device = Fd,
        current_offset = Offset,
        index_tab = IndexTab,
        total_bytes = TotalBytes
    },
    {ok, State}.

handle_call({put_bundle, #bpv7_bundle{} = Bundle}, _From, State) ->
    Key = make_bundle_key(Bundle),
    Expiry = Bundle#bpv7_bundle.creation_time + Bundle#bpv7_bundle.lifetime_ms,
    Encoded = apogee_bpv7:encode(Bundle),
    Len = byte_size(Encoded),
    Record = <<?BUNDLE_VAULT_MAGIC:32, Len:32, Encoded/binary>>,
    TotalLen = byte_size(Record),
    Offset = State#state.current_offset,

    case file:write(State#state.io_device, Record) of
        ok ->
            DestNode = apogee_eid:node_binary(Bundle#bpv7_bundle.destination),
            Entry = #index_entry{
                key = Key,
                offset = Offset,
                length = TotalLen,
                expiry = Expiry,
                destination = DestNode,
                deleted = false
            },
            ets:insert(State#state.index_tab, Entry),
            NewState = State#state{
                current_offset = Offset + TotalLen,
                total_bytes = State#state.total_bytes + TotalLen
            },
            {reply, {ok, Key}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({get_bundle, Key}, _From, State) ->
    case ets:lookup(State#state.index_tab, Key) of
        [#index_entry{deleted = false, offset = Offset, length = Length}] ->
            case read_record(State#state.data_file, Offset, Length) of
                {ok, Bundle} ->
                    {reply, {ok, Bundle}, State};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        _ ->
            {reply, {error, not_found}, State}
    end;

handle_call({delete_bundle, Key}, _From, State) ->
    case ets:lookup(State#state.index_tab, Key) of
        [#index_entry{} = Entry] ->
            ets:insert(State#state.index_tab, Entry#index_entry{deleted = true}),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call(list_bundles, _From, State) ->
    Entries = ets:tab2list(State#state.index_tab),
    ActiveKeys = [E#index_entry.key || E <- Entries, not E#index_entry.deleted],
    {reply, ActiveKeys, State};

handle_call({find_by_destination, DestNode}, _From, State) ->
    Entries = ets:tab2list(State#state.index_tab),
    ActiveMatching = [E || E <- Entries, not E#index_entry.deleted, E#index_entry.destination =:= DestNode],
    Bundles = lists:filtermap(
        fun(E) ->
            case read_record(State#state.data_file, E#index_entry.offset, E#index_entry.length) of
                {ok, B} -> {true, B};
                _ -> false
            end
        end,
        ActiveMatching
    ),
    {reply, Bundles, State};

handle_call({evict_expired, NowTimeMs}, _From, State) ->
    Entries = ets:tab2list(State#state.index_tab),
    Expired = [E || E <- Entries, not E#index_entry.deleted, E#index_entry.expiry < NowTimeMs],
    lists:foreach(
        fun(E) ->
            ets:insert(State#state.index_tab, E#index_entry{deleted = true})
        end,
        Expired
    ),
    {reply, {ok, length(Expired)}, State};

handle_call(compact, _From, State) ->
    Entries = ets:tab2list(State#state.index_tab),
    Active = [E || E <- Entries, not E#index_entry.deleted],
    TmpPath = State#state.data_file ++ ".compact",
    {ok, TmpFd} = file:open(TmpPath, [write, binary, raw]),
    file:close(State#state.io_device),
    
    {NewOffset, NewTotal} = lists:foldl(
        fun(E, {CurOff, CurBytes}) ->
            {ok, Binary} = read_raw(State#state.data_file, E#index_entry.offset, E#index_entry.length),
            ok = file:write(TmpFd, Binary),
            Len = E#index_entry.length,
            Updated = E#index_entry{offset = CurOff},
            ets:insert(State#state.index_tab, Updated),
            {CurOff + Len, CurBytes + Len}
        end,
        {0, 0},
        Active
    ),
    ok = file:close(TmpFd),
    ok = file:rename(TmpPath, State#state.data_file),
    {ok, NewFd} = file:open(State#state.data_file, [read, write, binary, raw, append]),
    Reclaimed = State#state.total_bytes - NewTotal,
    NewState = State#state{
        io_device = NewFd,
        current_offset = NewOffset,
        total_bytes = NewTotal
    },
    {reply, {ok, Reclaimed}, NewState};

handle_call(total_stored_bytes, _From, State) ->
    {reply, State#state.total_bytes, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.io_device of
        undefined -> ok;
        Fd -> file:close(Fd)
    end,
    case State#state.index_tab of
        undefined -> ok;
        Tab -> try ets:delete(Tab) catch _:_ -> ok end
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal helper functions
%%====================================================================

make_bundle_key(#bpv7_bundle{source = S, creation_time = C, sequence_number = Seq, fragment_offset = F}) ->
    {S, C, Seq, F}.

recover_index(DataFile, IndexTab) ->
    case file:read_file(DataFile) of
        {ok, Binary} ->
            scan_records(Binary, 0, 0, IndexTab);
        {error, _} ->
            {0, 0}
    end.

scan_records(<<?BUNDLE_VAULT_MAGIC:32, Len:32, Encoded:Len/binary, Rest/binary>>, Offset, TotalBytes, IndexTab) ->
    RecordLen = 8 + Len,
    Decoded = case apogee_bpv7:decode(Encoded) of
        {ok, B, _} -> {ok, B};
        {ok, B} -> {ok, B};
        Err -> Err
    end,
    case Decoded of
        {ok, Bundle} ->
            Key = make_bundle_key(Bundle),
            Expiry = Bundle#bpv7_bundle.creation_time + Bundle#bpv7_bundle.lifetime_ms,
            DestNode = apogee_eid:node_binary(Bundle#bpv7_bundle.destination),
            Entry = #index_entry{
                key = Key,
                offset = Offset,
                length = RecordLen,
                expiry = Expiry,
                destination = DestNode,
                deleted = false
            },
            ets:insert(IndexTab, Entry),
            scan_records(Rest, Offset + RecordLen, TotalBytes + RecordLen, IndexTab);
        _ ->
            scan_records(Rest, Offset + RecordLen, TotalBytes + RecordLen, IndexTab)
    end;
scan_records(_, Offset, TotalBytes, _IndexTab) ->
    {Offset, TotalBytes}.

read_record(DataFile, Offset, Length) ->
    case read_raw(DataFile, Offset, Length) of
        {ok, <<?BUNDLE_VAULT_MAGIC:32, Len:32, Encoded:Len/binary>>} ->
            case apogee_bpv7:decode(Encoded) of
                {ok, Bundle, _Rest} -> {ok, Bundle};
                {ok, Bundle} -> {ok, Bundle};
                Error -> Error
            end;
        {ok, _} ->
            {error, invalid_record_format};
        {error, Reason} ->
            {error, Reason}
    end.

read_raw(DataFile, Offset, Length) ->
    case file:open(DataFile, [read, binary, raw]) of
        {ok, Fd} ->
            case file:pread(Fd, Offset, Length) of
                {ok, Binary} ->
                    file:close(Fd),
                    {ok, Binary};
                eof ->
                    file:close(Fd),
                    {error, unexpected_eof};
                {error, Reason} ->
                    file:close(Fd),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).
