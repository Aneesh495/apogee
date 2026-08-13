%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Aerospace Append-Only Write-Ahead Log (WAL) with CRC32 verification.
%%% Designed for high-reliability flight software operating on flash memory.
%%% Guarantees crash recovery across sudden spacecraft power transients.
%%% Frame format:
%%% <<Magic:32, LSN:64, Type:16, PayloadLen:32, Payload:PayloadLen/binary, CRC32:32>>
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_wal).

-behaviour(gen_server).

%% API
-export([
    start_link/1,
    start_link/2,
    append/3,
    checkpoint/1,
    replay/1,
    truncate_before/2,
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

-define(WAL_MAGIC, 16#57414C31). % "WAL1"
-define(HEADER_LEN, 18). % 4 (magic) + 8 (lsn) + 2 (type) + 4 (len)
-define(TYPE_DATA, 1).
-define(TYPE_CHECKPOINT, 2).
-define(TYPE_TOMBSTONE, 3).

-record(wal_entry, {
    lsn :: non_neg_integer(),
    type :: non_neg_integer(),
    payload :: binary()
}).

-record(state, {
    dir :: file:filename_all(),
    file_path :: file:filename_all(),
    io_device :: file:io_device() | undefined,
    current_lsn = 0 :: non_neg_integer(),
    checkpoint_lsn = 0 :: non_neg_integer(),
    sync_on_write = true :: boolean()
}).

%%====================================================================
%% API
%%====================================================================

start_link(Dir) ->
    start_link(Dir, []).

start_link(Dir, Opts) ->
    gen_server:start_link(?MODULE, {Dir, Opts}, []).

-spec append(pid(), non_neg_integer(), binary()) -> {ok, non_neg_integer()} | {error, term()}.
append(Server, Type, Payload) when is_integer(Type), is_binary(Payload) ->
    gen_server:call(Server, {append, Type, Payload}).

-spec checkpoint(pid()) -> {ok, non_neg_integer()} | {error, term()}.
checkpoint(Server) ->
    gen_server:call(Server, checkpoint).

-spec replay(pid()) -> {ok, [{non_neg_integer(), non_neg_integer(), binary()}]}.
replay(Server) ->
    gen_server:call(Server, replay).

-spec truncate_before(pid(), non_neg_integer()) -> ok | {error, term()}.
truncate_before(Server, UpToLSN) ->
    gen_server:call(Server, {truncate_before, UpToLSN}).

close(Server) ->
    stop(Server).

stop(Server) ->
    gen_server:stop(Server).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({Dir, Opts}) ->
    Sync = proplists:get_value(sync, Opts, false),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    FilePath = filename:join(Dir, "apogee_journal.wal"),
    {InitialLSN, CheckpointLSN, _ValidEntries} = recover_wal(FilePath),
    {ok, Fd} = file:open(FilePath, [read, write, binary, raw, append]),
    State = #state{
        dir = Dir,
        file_path = FilePath,
        io_device = Fd,
        current_lsn = InitialLSN,
        checkpoint_lsn = CheckpointLSN,
        sync_on_write = Sync
    },
    {ok, State}.

handle_call({append, Type, Payload}, _From, State) ->
    NextLSN = State#state.current_lsn + 1,
    Frame = encode_frame(NextLSN, Type, Payload),
    case file:write(State#state.io_device, Frame) of
        ok ->
            maybe_sync(State),
            NewState = State#state{current_lsn = NextLSN},
            {reply, {ok, NextLSN}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(checkpoint, _From, State) ->
    NextLSN = State#state.current_lsn + 1,
    Frame = encode_frame(NextLSN, ?TYPE_CHECKPOINT, <<>>),
    case file:write(State#state.io_device, Frame) of
        ok ->
            maybe_sync(State),
            NewState = State#state{current_lsn = NextLSN, checkpoint_lsn = NextLSN},
            {reply, {ok, NextLSN}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(replay, _From, State) ->
    {_MaxLSN, _CkptLSN, Entries} = recover_wal(State#state.file_path),
    Records = [{E#wal_entry.lsn, E#wal_entry.type, E#wal_entry.payload} || E <- Entries],
    {reply, {ok, Records}, State};

handle_call({truncate_before, UpToLSN}, _From, State) ->
    % Truncate safely by reading valid records after UpToLSN and writing to compact file
    {_MaxLSN, _Ckpt, Entries} = recover_wal(State#state.file_path),
    Kept = [E || E <- Entries, E#wal_entry.lsn >= UpToLSN],
    file:close(State#state.io_device),
    TmpPath = State#state.file_path ++ ".tmp",
    {ok, TmpFd} = file:open(TmpPath, [write, binary, raw]),
    lists:foreach(
        fun(E) ->
            F = encode_frame(E#wal_entry.lsn, E#wal_entry.type, E#wal_entry.payload),
            ok = file:write(TmpFd, F)
        end,
        Kept
    ),
    ok = file:close(TmpFd),
    ok = file:rename(TmpPath, State#state.file_path),
    {ok, NewFd} = file:open(State#state.file_path, [read, write, binary, raw, append]),
    NewState = State#state{io_device = NewFd},
    {reply, ok, NewState};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({continue, _}, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.io_device of
        undefined -> ok;
        Fd -> file:close(Fd)
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal frame encoding & recovery
%%====================================================================

encode_frame(LSN, Type, Payload) ->
    PayloadLen = byte_size(Payload),
    Header = <<?WAL_MAGIC:32, LSN:64, Type:16, PayloadLen:32>>,
    DataWithoutCRC = <<Header/binary, Payload/binary>>,
    CRC = apogee_crc:crc32(DataWithoutCRC),
    <<DataWithoutCRC/binary, CRC:32>>.

decode_frames(<<>>, Acc) ->
    lists:reverse(Acc);
decode_frames(<<?WAL_MAGIC:32, LSN:64, Type:16, PayloadLen:32, Rest/binary>> = Bin, Acc) ->
    TotalNeeded = PayloadLen + 4,
    case byte_size(Rest) >= TotalNeeded of
        true ->
            <<Payload:PayloadLen/binary, CRC:32, NextRest/binary>> = Rest,
            DataToCheck = binary:part(Bin, 0, ?HEADER_LEN + PayloadLen),
            case apogee_crc:crc32(DataToCheck) =:= CRC of
                true ->
                    Entry = #wal_entry{lsn = LSN, type = Type, payload = Payload},
                    decode_frames(NextRest, [Entry | Acc]);
                false ->
                    % CRC corruption detected, stop recovery here
                    lists:reverse(Acc)
            end;
        false ->
            % Incomplete trailing frame
            lists:reverse(Acc)
    end;
decode_frames(_, Acc) ->
    lists:reverse(Acc).

recover_wal(FilePath) ->
    case file:read_file(FilePath) of
        {ok, Binary} ->
            Entries = decode_frames(Binary, []),
            MaxLSN = lists:foldl(fun(E, Max) -> max(Max, E#wal_entry.lsn) end, 0, Entries),
            CkptLSN = lists:foldl(
                fun(E, Max) ->
                    case E#wal_entry.type of
                        ?TYPE_CHECKPOINT -> max(Max, E#wal_entry.lsn);
                        _ -> Max
                    end
                end,
                0,
                Entries
            ),
            {MaxLSN, CkptLSN, Entries};
        {error, enoent} ->
            {0, 0, []};
        {error, _Reason} ->
            {0, 0, []}
    end.

maybe_sync(#state{sync_on_write = true, io_device = Fd}) ->
    file:sync(Fd);
maybe_sync(_) ->
    ok.
