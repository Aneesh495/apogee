%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Contact Plan Manager and Temporal Index for Contact Graph Routing.
%%% Stores scheduled space communication contacts, data transmission rates,
%%% one-way light time propagation delays, and byte capacity quotas.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_contact_plan).

-include("apogee.hrl").

-export([
    new/0,
    add_contact/2,
    add_contact/7,
    get_contacts/1,
    get_contacts_between/3,
    get_outbound_contacts/3,
    reserve_capacity/3,
    release_capacity/3,
    remove_contact/2
]).

-record(contact_plan, {
    contacts = #{} :: #{binary() => #contact{}},
    from_index = #{} :: #{binary() => [binary()]} % FromNode => [ContactId]
}).

-type contact_plan() :: #contact_plan{}.
-export_type([contact_plan/0]).

-spec new() -> contact_plan().
new() ->
    #contact_plan{contacts = #{}, from_index = #{}}.

-spec add_contact(contact_plan(), #contact{}) -> contact_plan().
add_contact(#contact_plan{} = CP, #contact{} = C) ->
    Id = case C#contact.id of
        <<>> ->
            gen_contact_id(C#contact.from_node, C#contact.to_node, C#contact.start_time);
        GivenId ->
            GivenId
    end,
    DurationS = max(0.0, C#contact.end_time - C#contact.start_time),
    Capacity = case C#contact.total_capacity_bytes of
        0 -> round(DurationS * C#contact.data_rate_bps / 8.0);
        Cap -> Cap
    end,
    ContactWithId = C#contact{id = Id, total_capacity_bytes = Capacity},
    NewContacts = maps:put(Id, ContactWithId, CP#contact_plan.contacts),
    
    FromNode = C#contact.from_node,
    ExistingIds = maps:get(FromNode, CP#contact_plan.from_index, []),
    NewIndex = maps:put(FromNode, [Id | lists:delete(Id, ExistingIds)], CP#contact_plan.from_index),

    CP#contact_plan{contacts = NewContacts, from_index = NewIndex}.

-spec add_contact(contact_plan(), binary() | string(), binary() | string(), number(), number(), pos_integer(), number()) -> contact_plan().
add_contact(CP, From, To, StartTime, EndTime, RateBps, RangeDelayS) ->
    FromBin = to_binary(From),
    ToBin = to_binary(To),
    C = #contact{
        id = gen_contact_id(FromBin, ToBin, StartTime),
        from_node = FromBin,
        to_node = ToBin,
        start_time = float(StartTime),
        end_time = float(EndTime),
        data_rate_bps = RateBps,
        range_delay_s = float(RangeDelayS),
        confidence = 1.0,
        reserved_bytes = 0
    },
    add_contact(CP, C).

-spec get_contacts(contact_plan()) -> [#contact{}].
get_contacts(#contact_plan{contacts = Contacts}) ->
    maps:values(Contacts).

-spec get_outbound_contacts(contact_plan(), binary() | string(), number()) -> [#contact{}].
get_outbound_contacts(#contact_plan{} = CP, FromNode, MinTime) ->
    FromBin = to_binary(FromNode),
    Ids = maps:get(FromBin, CP#contact_plan.from_index, []),
    [C || Id <- Ids,
          C <- [maps:get(Id, CP#contact_plan.contacts, undefined)],
          C =/= undefined,
          C#contact.end_time > float(MinTime)].

-spec get_contacts_between(contact_plan(), binary() | string(), binary() | string()) -> [#contact{}].
get_contacts_between(#contact_plan{} = CP, FromNode, ToNode) ->
    FromBin = to_binary(FromNode),
    ToBin = to_binary(ToNode),
    [C || C <- get_contacts(CP), C#contact.from_node =:= FromBin, C#contact.to_node =:= ToBin].

-spec reserve_capacity(contact_plan(), binary(), non_neg_integer()) -> {ok, contact_plan()} | {error, overbooked}.
reserve_capacity(#contact_plan{} = CP, ContactId, Bytes) ->
    case maps:find(ContactId, CP#contact_plan.contacts) of
        {ok, #contact{total_capacity_bytes = Total, reserved_bytes = Reserved} = C} ->
            case Reserved + Bytes =< Total of
                true ->
                    Updated = C#contact{reserved_bytes = Reserved + Bytes},
                    NewContacts = maps:put(ContactId, Updated, CP#contact_plan.contacts),
                    {ok, CP#contact_plan{contacts = NewContacts}};
                false ->
                    {error, overbooked}
            end;
        error ->
            {error, unknown_contact}
    end.

-spec release_capacity(contact_plan(), binary(), non_neg_integer()) -> contact_plan().
release_capacity(#contact_plan{} = CP, ContactId, Bytes) ->
    case maps:find(ContactId, CP#contact_plan.contacts) of
        {ok, #contact{reserved_bytes = Reserved} = C} ->
            Updated = C#contact{reserved_bytes = max(0, Reserved - Bytes)},
            NewContacts = maps:put(ContactId, Updated, CP#contact_plan.contacts),
            CP#contact_plan{contacts = NewContacts};
        error ->
            CP
    end.

-spec remove_contact(contact_plan(), binary()) -> contact_plan().
remove_contact(#contact_plan{} = CP, ContactId) ->
    case maps:find(ContactId, CP#contact_plan.contacts) of
        {ok, #contact{from_node = FromNode}} ->
            NewContacts = maps:remove(ContactId, CP#contact_plan.contacts),
            ExistingIds = maps:get(FromNode, CP#contact_plan.from_index, []),
            NewIndex = maps:put(FromNode, lists:delete(ContactId, ExistingIds), CP#contact_plan.from_index),
            CP#contact_plan{contacts = NewContacts, from_index = NewIndex};
        error ->
            CP
    end.

gen_contact_id(From, To, StartTime) ->
    <<From/binary, "->", To/binary, "@", (integer_to_binary(round(float(StartTime) * 1000)))/binary>>.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).
