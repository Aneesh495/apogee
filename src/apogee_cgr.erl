%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Contact Graph Routing (CGR) Engine for Delay-Tolerant Satellite Networks.
%%% Implements Earliest Delivery Time (EDT) Dijkstra path computation over
%%% time-varying contact graphs, multipath route selection, contact volume
%%% reservation, and dynamic route deflection for congested links.
%%% Conforms to CCSDS 734.1-R-2 and RFC 9171 CGR specifications.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_cgr).

-include("apogee.hrl").

-export([
    find_earliest_path/5,
    find_k_paths/6,
    route_and_reserve/5,
    deflect_route/6,
    route_bundle/3
]).

-type node_id() :: binary().

%%====================================================================
%% API Functions
%%====================================================================

-spec find_earliest_path(
    apogee_contact_plan:contact_plan(),
    node_id() | string(),
    node_id() | string(),
    non_neg_integer(),
    number()
) -> {ok, #cgr_route{}} | {error, no_route}.
find_earliest_path(ContactPlan, From, To, BundleSize, StartTime) ->
    case find_k_paths(ContactPlan, From, To, BundleSize, StartTime, 1) of
        [BestRoute | _] ->
            {ok, BestRoute};
        [] ->
            {error, no_route}
    end.

-spec find_k_paths(
    apogee_contact_plan:contact_plan(),
    node_id() | string(),
    node_id() | string(),
    non_neg_integer(),
    number(),
    pos_integer()
) -> [#cgr_route{}].
find_k_paths(ContactPlan, From, To, BundleSize, StartTime, K) ->
    FromBin = to_bin(From),
    ToBin = to_bin(To),
    InitialState = {float(StartTime), FromBin, [], 1.0, float(StartTime)},
    Frontier = [InitialState],
    Visited = #{FromBin => 1},
    explore(Frontier, ContactPlan, ToBin, BundleSize, Visited, [], K, []).

-spec route_and_reserve(
    apogee_contact_plan:contact_plan(),
    node_id() | string(),
    node_id() | string(),
    non_neg_integer(),
    number()
) -> {ok, #cgr_route{}, apogee_contact_plan:contact_plan()} | {error, term()}.
route_and_reserve(ContactPlan, From, To, BundleSize, StartTime) ->
    case find_earliest_path(ContactPlan, From, To, BundleSize, StartTime) of
        {ok, #cgr_route{hops = Hops} = Route} ->
            case reserve_hops(ContactPlan, Hops, BundleSize) of
                {ok, UpdatedCP} ->
                    {ok, Route, UpdatedCP};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec deflect_route(
    apogee_contact_plan:contact_plan(),
    [binary()],
    node_id() | string(),
    node_id() | string(),
    non_neg_integer(),
    number()
) -> {ok, #cgr_route{}} | {error, no_route}.
deflect_route(ContactPlan, ExcludedContactIds, From, To, BundleSize, StartTime) ->
    FromBin = to_bin(From),
    ToBin = to_bin(To),
    InitialState = {float(StartTime), FromBin, [], 1.0, float(StartTime)},
    Frontier = [InitialState],
    Visited = #{FromBin => 1},
    case explore(Frontier, ContactPlan, ToBin, BundleSize, Visited, [], 1, ExcludedContactIds) of
        [Route | _] ->
            {ok, Route};
        [] ->
            {error, no_route}
    end.

-spec route_bundle(
    apogee_contact_plan:contact_plan(),
    #bpv7_bundle{},
    number()
) -> {ok, binary(), #cgr_route{}, apogee_contact_plan:contact_plan()} | {error, term()}.
route_bundle(ContactPlan, #bpv7_bundle{} = Bundle, CurrentTime) ->
    DestNode = extract_node(Bundle#bpv7_bundle.destination),
    SrcNode = extract_node(Bundle#bpv7_bundle.source),
    BundleSize = byte_size(Bundle#bpv7_bundle.payload) + 128, % Estimate with headers
    case route_and_reserve(ContactPlan, SrcNode, DestNode, BundleSize, CurrentTime) of
        {ok, #cgr_route{hops = [FirstHop | _]} = Route, UpdatedCP} ->
            NextHop = FirstHop#contact.to_node,
            {ok, NextHop, Route, UpdatedCP};
        {error, Reason} ->
            {error, Reason}
    end.

%%====================================================================
%% Internal Dijkstra Search Functions
%%====================================================================

explore([], _CP, _Dest, _Size, _Visited, FoundRoutes, _K, _Excluded) ->
    lists:reverse(FoundRoutes);
explore(_Frontier, _CP, _Dest, _Size, _Visited, FoundRoutes, K, _Excluded) when length(FoundRoutes) >= K ->
    lists:reverse(FoundRoutes);
explore([{ArrTime, Node, Hops, Conf, TxStart} | Rest], CP, Dest, Size, Visited, FoundRoutes, K, Excluded) ->
    case Node =:= Dest of
        true ->
            Route = #cgr_route{
                from_node = case Hops of
                    [] -> Node;
                    _ -> (lists:last(Hops))#contact.from_node
                end,
                to_node = Dest,
                hops = lists:reverse(Hops),
                tx_start_time = TxStart,
                arrival_time = ArrTime,
                total_bytes = Size,
                path_confidence = Conf
            },
            explore(Rest, CP, Dest, Size, Visited, [Route | FoundRoutes], K, Excluded);
        false ->
            Outbound = apogee_contact_plan:get_outbound_contacts(CP, Node, ArrTime),
            NewEntries = lists:filtermap(
                fun(Contact) ->
                    eval_contact(Contact, ArrTime, Node, Hops, Conf, TxStart, Size, Visited, Excluded)
                end,
                Outbound
            ),
            NewFrontier = merge_frontier(Rest, NewEntries),
            NewVisited = update_visited(Visited, NewEntries),
            explore(NewFrontier, CP, Dest, Size, NewVisited, FoundRoutes, K, Excluded)
    end.

eval_contact(Contact, CurrentTime, _Node, Hops, Conf, OrigTxStart, Size, Visited, Excluded) ->
    Id = Contact#contact.id,
    case lists:member(Id, Excluded) of
        true ->
            false;
        false ->
            RateBps = Contact#contact.data_rate_bps,
            TotalCap = Contact#contact.total_capacity_bytes,
            Reserved = Contact#contact.reserved_bytes,
            DurationTx = (Size * 8) / float(RateBps),
            ActualTxStart = max(Contact#contact.start_time, CurrentTime),
            ActualTxEnd = ActualTxStart + DurationTx,
            case ActualTxEnd =< Contact#contact.end_time andalso (Reserved + Size) =< TotalCap of
                true ->
                    NextArr = ActualTxEnd + Contact#contact.range_delay_s,
                    NextNode = Contact#contact.to_node,
                    % Prevent cycles in the hop path
                    IsCycle = lists:any(fun(C) -> C#contact.from_node =:= NextNode end, Hops),
                    Visits = maps:get(NextNode, Visited, 0),
                    case (not IsCycle) andalso Visits < 5 of
                        true ->
                            FirstTx = case Hops of
                                [] -> ActualTxStart;
                                _ -> OrigTxStart
                            end,
                            NewConf = Conf * Contact#contact.confidence,
                            {true, {NextArr, NextNode, [Contact | Hops], NewConf, FirstTx}};
                        false ->
                            false
                    end;
                false ->
                    false
            end
    end.

merge_frontier(Frontier, []) ->
    Frontier;
merge_frontier(Frontier, [Item | Rest]) ->
    merge_frontier(insert_sorted(Item, Frontier), Rest).

insert_sorted(Item, []) ->
    [Item];
insert_sorted({T1, _, _, _, _} = Item, [{T2, _, _, _, _} = Head | Tail]) when T1 =< T2 ->
    [Item, Head | Tail];
insert_sorted(Item, [Head | Tail]) ->
    [Head | insert_sorted(Item, Tail)].

update_visited(Visited, []) ->
    Visited;
update_visited(Visited, [{_ArrTime, Node, _, _, _} | Rest]) ->
    Current = maps:get(Node, Visited, 0),
    update_visited(maps:put(Node, Current + 1, Visited), Rest).

reserve_hops(CP, [], _Size) ->
    {ok, CP};
reserve_hops(CP, [#contact{id = Id} | Rest], Size) ->
    case apogee_contact_plan:reserve_capacity(CP, Id, Size) of
        {ok, UpdatedCP} ->
            reserve_hops(UpdatedCP, Rest, Size);
        {error, Reason} ->
            {error, Reason}
    end.

extract_node(Eid) ->
    apogee_eid:node_binary(Eid).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).
