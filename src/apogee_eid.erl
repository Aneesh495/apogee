%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc RFC 9171 Endpoint Identifier (EID) Parser and Formatter.
%%% Supports dtn (URI) and ipn (compact numeric) naming schemes with CBOR mappings.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_eid).

-export([
    parse/1,
    format/1,
    encode_cbor/1,
    decode_cbor/1,
    null_eid/0,
    is_null/1,
    ipn/2,
    dtn/2,
    matches/2,
    node_binary/1
]).

-record(eid, {
    scheme = ipn :: ipn | dtn | none,
    node = 0 :: non_neg_integer() | binary(),
    service = 0 :: non_neg_integer() | binary()
}).

-type eid() :: #eid{}.
-export_type([eid/0]).

-spec null_eid() -> eid().
null_eid() ->
    #eid{scheme = none, node = 0, service = 0}.

-spec is_null(eid()) -> boolean().
is_null(#eid{scheme = none}) -> true;
is_null(_) -> false.

-spec ipn(non_neg_integer(), non_neg_integer()) -> eid().
ipn(Node, Service) when is_integer(Node), is_integer(Service), Node >= 0, Service >= 0 ->
    #eid{scheme = ipn, node = Node, service = Service}.

-spec dtn(binary() | string(), binary() | string()) -> eid().
dtn(Node, Service) ->
    NodeBin = to_binary(Node),
    ServiceBin = to_binary(Service),
    #eid{scheme = dtn, node = NodeBin, service = ServiceBin}.

-spec parse(binary() | string()) -> {ok, eid()} | {error, term()}.
parse(Str) when is_list(Str) ->
    parse(list_to_binary(Str));
parse(<<"dtn:none">>) ->
    {ok, null_eid()};
parse(<<"ipn:", Rest/binary>>) ->
    case binary:split(Rest, <<".">>) of
        [NodeStr, ServiceStr] ->
            try
                Node = binary_to_integer(NodeStr),
                Service = binary_to_integer(ServiceStr),
                {ok, ipn(Node, Service)}
            catch
                _:_ -> {error, invalid_ipn_numbers}
            end;
        _ ->
            {error, invalid_ipn_format}
    end;
parse(<<"dtn://", Rest/binary>>) ->
    case binary:split(Rest, <<"/">>) of
        [Node, Service] when Node =/= <<>> ->
            {ok, dtn(Node, Service)};
        [Node] when Node =/= <<>> ->
            {ok, dtn(Node, <<>>)};
        _ ->
            {error, invalid_dtn_uri}
    end;
parse(_) ->
    {error, unsupported_eid_scheme}.

-spec format(eid()) -> binary().
format(#eid{scheme = none}) ->
    <<"dtn:none">>;
format(#eid{scheme = ipn, node = N, service = S}) ->
    NodeBin = integer_to_binary(N),
    ServiceBin = integer_to_binary(S),
    <<"ipn:", NodeBin/binary, ".", ServiceBin/binary>>;
format(#eid{scheme = dtn, node = N, service = S}) ->
    case S of
        <<>> -> <<"dtn://", N/binary>>;
        _ -> <<"dtn://", N/binary, "/", S/binary>>
    end.

-spec encode_cbor(eid()) -> [term()].
encode_cbor(#eid{scheme = none}) ->
    [1, 0]; % Scheme code 1, SSP 0 represents dtn:none
encode_cbor(#eid{scheme = ipn, node = N, service = S}) ->
    [2, [N, S]]; % Scheme code 2 represents ipn
encode_cbor(#eid{scheme = dtn} = Eid) ->
    Formatted = format(Eid),
    [1, binary_to_list(Formatted)].

-spec decode_cbor(term()) -> {ok, eid()} | {error, term()}.
decode_cbor([1, 0]) ->
    {ok, null_eid()};
decode_cbor([2, [N, S]]) when is_integer(N), is_integer(S) ->
    {ok, ipn(N, S)};
decode_cbor([1, Str]) when is_list(Str) ->
    parse(Str);
decode_cbor(_) ->
    {error, invalid_cbor_eid}.

-spec matches(eid(), eid()) -> boolean().
matches(#eid{scheme = Scheme, node = N1, service = S1}, #eid{scheme = Scheme, node = N2, service = S2}) ->
    NodeMatch = (N1 =:= N2) orelse (N1 =:= <<"*">>),
    ServiceMatch = (S1 =:= S2) orelse (S1 =:= <<"*">>) orelse (S1 =:= 0),
    NodeMatch andalso ServiceMatch;
matches(_, _) ->
    false.

-spec node_binary(eid() | binary() | string()) -> binary().
node_binary(#eid{scheme = ipn, node = Node}) ->
    integer_to_binary(Node);
node_binary(#eid{scheme = dtn, node = Node}) ->
    to_binary(Node);
node_binary(#eid{scheme = none}) ->
    <<>>;
node_binary(Bin) when is_binary(Bin) ->
    case parse(Bin) of
        {ok, Eid} -> node_binary(Eid);
        _ -> Bin
    end;
node_binary(List) when is_list(List) ->
    node_binary(list_to_binary(List)).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).
