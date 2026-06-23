%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc CCSDS Communications Link Control Word (CLCW).
%%% Bit-exact 32-bit reporting mechanism for closed-loop COP-1 space link feedback.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_clcw).

-include("apogee.hrl").

-export([
    new/0,
    encode/1,
    decode/1,
    report_value/1,
    is_lockout/1,
    is_wait/1,
    is_retransmit/1
]).

-type clcw() :: #clcw{}.
-export_type([clcw/0]).

-spec new() -> clcw().
new() ->
    #clcw{}.

-spec encode(clcw()) -> binary().
encode(#clcw{} = C) ->
    NoRF = bool_to_bit(C#clcw.no_rf),
    NoBitLock = bool_to_bit(C#clcw.no_bit_lock),
    Lockout = bool_to_bit(C#clcw.lockout),
    Wait = bool_to_bit(C#clcw.wait),
    Retransmit = bool_to_bit(C#clcw.retransmit),

    << 0:1, % Control Word Type = 0 (CLCW)
       (C#clcw.version):2,
       (C#clcw.status_field):3,
       (C#clcw.cop_in_effect):2,
       (C#clcw.vcid):6,
       0:2, % Reserved spares
       NoRF:1,
       NoBitLock:1,
       Lockout:1,
       Wait:1,
       Retransmit:1,
       (C#clcw.farm_b_counter):2,
       0:1, % Reserved spare
       (C#clcw.report_value):8/unsigned >>.

-spec decode(binary()) -> {ok, clcw()} | {error, term()}.
decode(<<0:1, Version:2, Status:3, Cop:2, VCID:6, _Spare1:2,
         NoRF:1, NoBitLock:1, Lockout:1, Wait:1, Retransmit:1,
         FarmB:2, _Spare2:1, ReportValue:8/unsigned>>) ->
    {ok, #clcw{
        version = Version,
        status_field = Status,
        cop_in_effect = Cop,
        vcid = VCID,
        no_rf = bit_to_bool(NoRF),
        no_bit_lock = bit_to_bool(NoBitLock),
        lockout = bit_to_bool(Lockout),
        wait = bit_to_bool(Wait),
        retransmit = bit_to_bool(Retransmit),
        farm_b_counter = FarmB,
        report_value = ReportValue
    }};
decode(Binary) when is_binary(Binary), byte_size(Binary) =/= 4 ->
    {error, invalid_clcw_length};
decode(<<1:1, _/bitstring>>) ->
    {error, not_a_clcw};
decode(_) ->
    {error, malformed_clcw}.

-spec report_value(clcw()) -> 0..255.
report_value(#clcw{report_value = VR}) -> VR.

-spec is_lockout(clcw()) -> boolean().
is_lockout(#clcw{lockout = L}) -> L.

-spec is_wait(clcw()) -> boolean().
is_wait(#clcw{wait = W}) -> W.

-spec is_retransmit(clcw()) -> boolean().
is_retransmit(#clcw{retransmit = R}) -> R.

bool_to_bit(true) -> 1;
bool_to_bit(false) -> 0.

bit_to_bool(1) -> true;
bit_to_bool(0) -> false.
