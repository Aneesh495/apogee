%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc CGR Router gen_server for stateful spacecraft bundle routing.
%%% Maintains the active contact plan, manages volume reservations,
%%% handles link failure notifications, and dynamically deflects traffic.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_cgr_router).

-behaviour(gen_server).

-include("apogee.hrl").

%% API
-export([
    start_link/0,
    start_link/1,
    add_contact/2,
    route_bundle/2,
    report_link_failure/2,
    get_contact_plan/1,
    get_k_routes/5,
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

-record(state, {
    contact_plan :: apogee_contact_plan:contact_plan(),
    failed_contacts = [] :: [binary()],
    routed_bundles = 0 :: non_neg_integer(),
    deflected_bundles = 0 :: non_neg_integer()
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    start_link([]).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

add_contact(Server, Contact) ->
    gen_server:call(Server, {add_contact, Contact}).

route_bundle(Server, Bundle) ->
    gen_server:call(Server, {route_bundle, Bundle}).

report_link_failure(Server, ContactId) ->
    gen_server:call(Server, {report_link_failure, ContactId}).

get_contact_plan(Server) ->
    gen_server:call(Server, get_contact_plan).

get_k_routes(Server, From, To, Size, K) ->
    gen_server:call(Server, {get_k_routes, From, To, Size, K}).

stop(Server) ->
    gen_server:stop(Server).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_Opts) ->
    {ok, #state{contact_plan = apogee_contact_plan:new(), failed_contacts = []}}.

handle_call({add_contact, #contact{} = C}, _From, State) ->
    NewCP = apogee_contact_plan:add_contact(State#state.contact_plan, C),
    {reply, ok, State#state{contact_plan = NewCP}};

handle_call({route_bundle, #bpv7_bundle{} = Bundle}, _From, State) ->
    CP = State#state.contact_plan,
    Failed = State#state.failed_contacts,
    DestNode = extract_node(Bundle#bpv7_bundle.destination),
    SrcNode = extract_node(Bundle#bpv7_bundle.source),
    Size = byte_size(Bundle#bpv7_bundle.payload) + 128,
    CurrentTime = apogee_time:now_seconds(),

    case Failed of
        [] ->
            case apogee_cgr:route_and_reserve(CP, SrcNode, DestNode, Size, CurrentTime) of
                {ok, #cgr_route{hops = [FirstHop | _]} = Route, UpdatedCP} ->
                    NextHop = FirstHop#contact.to_node,
                    NewState = State#state{
                        contact_plan = UpdatedCP,
                        routed_bundles = State#state.routed_bundles + 1
                    },
                    {reply, {ok, NextHop, Route}, NewState};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        _ ->
            % Dynamic deflection around failed contacts
            case apogee_cgr:deflect_route(CP, Failed, SrcNode, DestNode, Size, CurrentTime) of
                {ok, #cgr_route{hops = [FirstHop | _]} = DeflectedRoute} ->
                    NextHop = FirstHop#contact.to_node,
                    NewState = State#state{
                        routed_bundles = State#state.routed_bundles + 1,
                        deflected_bundles = State#state.deflected_bundles + 1
                    },
                    {reply, {ok, NextHop, DeflectedRoute}, NewState};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;

handle_call({report_link_failure, ContactId}, _From, State) ->
    NewFailed = [ContactId | lists:delete(ContactId, State#state.failed_contacts)],
    {reply, ok, State#state{failed_contacts = NewFailed}};

handle_call(get_contact_plan, _From, State) ->
    {reply, State#state.contact_plan, State};

handle_call({get_k_routes, From, To, Size, K}, _From, State) ->
    Now = apogee_time:now_seconds(),
    Routes = apogee_cgr:find_k_paths(State#state.contact_plan, From, To, Size, Now, K),
    {reply, Routes, State};

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
%% Internal functions
%%====================================================================

extract_node(Eid) ->
    apogee_eid:node_binary(Eid).
