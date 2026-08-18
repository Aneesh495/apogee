%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Multi-Priority Spacecraft Bundle Queue with Quota Shedding.
%%% Supports 3-tier priority scheduling (expedited, standard, bulk),
%%% strict FIFO within priority tiers, TTL-based deadline pruning,
%%% and lowest-priority-first quota shedding during storage crunches.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_bundle_queue).

-include("apogee.hrl").

-export([
    new/1,
    push/3,
    pop/1,
    peek/1,
    evict_expired/2,
    shed_quota/2,
    len/1,
    total_bytes/1,
    to_list/1
]).

-type priority() :: expedited | standard | bulk.

-record(bundle_queue, {
    max_bytes = 10000000 :: non_neg_integer(),
    total_bytes = 0 :: non_neg_integer(),
    total_count = 0 :: non_neg_integer(),
    expedited = queue:new() :: queue:queue(#bpv7_bundle{}),
    standard = queue:new() :: queue:queue(#bpv7_bundle{}),
    bulk = queue:new() :: queue:queue(#bpv7_bundle{})
}).

-type bundle_queue() :: #bundle_queue{}.
-export_type([bundle_queue/0, priority/0]).

%%====================================================================
%% API Functions
%%====================================================================

-spec new(non_neg_integer()) -> bundle_queue().
new(MaxBytes) when is_integer(MaxBytes), MaxBytes > 0 ->
    #bundle_queue{
        max_bytes = MaxBytes,
        total_bytes = 0,
        total_count = 0,
        expedited = queue:new(),
        standard = queue:new(),
        bulk = queue:new()
    }.

-spec push(bundle_queue(), priority(), #bpv7_bundle{}) -> {ok, bundle_queue()} | {error, quota_exceeded}.
push(#bundle_queue{} = Q, Priority, #bpv7_bundle{} = Bundle) ->
    BundleSize = byte_size(Bundle#bpv7_bundle.payload) + 128,
    case Q#bundle_queue.total_bytes + BundleSize =< Q#bundle_queue.max_bytes of
        true ->
            NewQ = insert_priority(Q, Priority, Bundle, BundleSize),
            {ok, NewQ};
        false ->
            % Attempt to shed bulk/standard to make room if Priority is higher
            case Priority of
                expedited ->
                    RoomNeeded = (Q#bundle_queue.total_bytes + BundleSize) - Q#bundle_queue.max_bytes,
                    {_Dropped, ShedQ} = shed_quota(Q, Q#bundle_queue.total_bytes - RoomNeeded),
                    case ShedQ#bundle_queue.total_bytes + BundleSize =< ShedQ#bundle_queue.max_bytes of
                        true ->
                            {ok, insert_priority(ShedQ, Priority, Bundle, BundleSize)};
                        false ->
                            {error, quota_exceeded}
                    end;
                _ ->
                    {error, quota_exceeded}
            end
    end.

-spec pop(bundle_queue()) -> {ok, #bpv7_bundle{}, bundle_queue()} | empty.
pop(#bundle_queue{total_count = 0}) ->
    empty;
pop(#bundle_queue{} = Q) ->
    case queue:out(Q#bundle_queue.expedited) of
        {{value, Bundle}, NewExp} ->
            Size = byte_size(Bundle#bpv7_bundle.payload) + 128,
            {ok, Bundle, Q#bundle_queue{
                expedited = NewExp,
                total_bytes = max(0, Q#bundle_queue.total_bytes - Size),
                total_count = Q#bundle_queue.total_count - 1
            }};
        {empty, _} ->
            case queue:out(Q#bundle_queue.standard) of
                {{value, Bundle}, NewStd} ->
                    Size = byte_size(Bundle#bpv7_bundle.payload) + 128,
                    {ok, Bundle, Q#bundle_queue{
                        standard = NewStd,
                        total_bytes = max(0, Q#bundle_queue.total_bytes - Size),
                        total_count = Q#bundle_queue.total_count - 1
                    }};
                {empty, _} ->
                    case queue:out(Q#bundle_queue.bulk) of
                        {{value, Bundle}, NewBulk} ->
                            Size = byte_size(Bundle#bpv7_bundle.payload) + 128,
                            {ok, Bundle, Q#bundle_queue{
                                bulk = NewBulk,
                                total_bytes = max(0, Q#bundle_queue.total_bytes - Size),
                                total_count = Q#bundle_queue.total_count - 1
                            }};
                        {empty, _} ->
                            empty
                    end
            end
    end.

-spec peek(bundle_queue()) -> {ok, #bpv7_bundle{}} | empty.
peek(#bundle_queue{total_count = 0}) ->
    empty;
peek(#bundle_queue{} = Q) ->
    case queue:peek(Q#bundle_queue.expedited) of
        {value, Bundle} -> {ok, Bundle};
        empty ->
            case queue:peek(Q#bundle_queue.standard) of
                {value, Bundle} -> {ok, Bundle};
                empty ->
                    case queue:peek(Q#bundle_queue.bulk) of
                        {value, Bundle} -> {ok, Bundle};
                        empty -> empty
                    end
            end
    end.

-spec evict_expired(bundle_queue(), non_neg_integer()) -> {[#bpv7_bundle{}], bundle_queue()}.
evict_expired(#bundle_queue{} = Q, NowMs) ->
    {ExpEvicted, NewExp} = prune_expired_tier(Q#bundle_queue.expedited, NowMs),
    {StdEvicted, NewStd} = prune_expired_tier(Q#bundle_queue.standard, NowMs),
    {BulkEvicted, NewBulk} = prune_expired_tier(Q#bundle_queue.bulk, NowMs),

    AllEvicted = ExpEvicted ++ StdEvicted ++ BulkEvicted,
    BytesFreed = lists:sum([byte_size(B#bpv7_bundle.payload) + 128 || B <- AllEvicted]),
    CountFreed = length(AllEvicted),

    NewQ = Q#bundle_queue{
        expedited = NewExp,
        standard = NewStd,
        bulk = NewBulk,
        total_bytes = max(0, Q#bundle_queue.total_bytes - BytesFreed),
        total_count = max(0, Q#bundle_queue.total_count - CountFreed)
    },
    {AllEvicted, NewQ}.

-spec shed_quota(bundle_queue(), non_neg_integer()) -> {[#bpv7_bundle{}], bundle_queue()}.
shed_quota(#bundle_queue{} = Q, TargetBytes) ->
    case Q#bundle_queue.total_bytes =< TargetBytes of
        true ->
            {[], Q};
        false ->
            % Shed from bulk first, then standard
            {BulkDropped, Q1} = shed_tier(Q#bundle_queue.bulk, Q, TargetBytes, fun(NewQ, SubQ) -> NewQ#bundle_queue{bulk = SubQ} end),
            case Q1#bundle_queue.total_bytes =< TargetBytes of
                true ->
                    {BulkDropped, Q1};
                false ->
                    {StdDropped, Q2} = shed_tier(Q1#bundle_queue.standard, Q1, TargetBytes, fun(NewQ, SubQ) -> NewQ#bundle_queue{standard = SubQ} end),
                    {BulkDropped ++ StdDropped, Q2}
            end
    end.

-spec len(bundle_queue()) -> non_neg_integer().
len(#bundle_queue{total_count = Count}) ->
    Count.

-spec total_bytes(bundle_queue()) -> non_neg_integer().
total_bytes(#bundle_queue{total_bytes = Bytes}) ->
    Bytes.

-spec to_list(bundle_queue()) -> [#bpv7_bundle{}].
to_list(#bundle_queue{} = Q) ->
    queue:to_list(Q#bundle_queue.expedited) ++
    queue:to_list(Q#bundle_queue.standard) ++
    queue:to_list(Q#bundle_queue.bulk).

%%====================================================================
%% Internal helper functions
%%====================================================================

insert_priority(#bundle_queue{} = Q, expedited, Bundle, Size) ->
    Q#bundle_queue{
        expedited = queue:in(Bundle, Q#bundle_queue.expedited),
        total_bytes = Q#bundle_queue.total_bytes + Size,
        total_count = Q#bundle_queue.total_count + 1
    };
insert_priority(#bundle_queue{} = Q, standard, Bundle, Size) ->
    Q#bundle_queue{
        standard = queue:in(Bundle, Q#bundle_queue.standard),
        total_bytes = Q#bundle_queue.total_bytes + Size,
        total_count = Q#bundle_queue.total_count + 1
    };
insert_priority(#bundle_queue{} = Q, bulk, Bundle, Size) ->
    Q#bundle_queue{
        bulk = queue:in(Bundle, Q#bundle_queue.bulk),
        total_bytes = Q#bundle_queue.total_bytes + Size,
        total_count = Q#bundle_queue.total_count + 1
    }.

prune_expired_tier(TierQ, NowMs) ->
    Items = queue:to_list(TierQ),
    {Expired, Kept} = lists:partition(
        fun(#bpv7_bundle{creation_time = C, lifetime_ms = L}) ->
            (C + L) < NowMs
        end,
        Items
    ),
    {Expired, queue:from_list(Kept)}.

shed_tier(TierQ, Q, TargetBytes, SetterFun) ->
    shed_tier_loop(TierQ, Q, TargetBytes, SetterFun, []).

shed_tier_loop(TierQ, Q, TargetBytes, SetterFun, Dropped) ->
    case Q#bundle_queue.total_bytes =< TargetBytes of
        true ->
            {lists:reverse(Dropped), SetterFun(Q, TierQ)};
        false ->
            case queue:out_r(TierQ) of % Drop newest/oldest from end
                {{value, Bundle}, NewTierQ} ->
                    Size = byte_size(Bundle#bpv7_bundle.payload) + 128,
                    NewQ = Q#bundle_queue{
                        total_bytes = max(0, Q#bundle_queue.total_bytes - Size),
                        total_count = max(0, Q#bundle_queue.total_count - 1)
                    },
                    shed_tier_loop(NewTierQ, NewQ, TargetBytes, SetterFun, [Bundle | Dropped]);
                {empty, _} ->
                    {lists:reverse(Dropped), SetterFun(Q, TierQ)}
            end
    end.
