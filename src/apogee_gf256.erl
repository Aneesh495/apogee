%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Galois Field GF(2^8) Arithmetic for Spacecraft Error Correction.
%%% Implements field multiplication, inversion, and polynomial arithmetic
%%% over GF(256) with CCSDS primitive polynomial p(x) = x^8 + x^4 + x^3 + x^2 + 1.
%%% Precomputed exponentiation and logarithm tables enable O(1) field operations.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_gf256).

-export([
    add/2,
    sub/2,
    mult/2,
    divide/2,
    inv/1,
    pow/2,
    exp_table/0,
    log_table/0,
    poly_eval/2,
    poly_mult/2,
    poly_add/2,
    poly_scale/2
]).

%% Standard primitive polynomial 0x11D: x^8 + x^4 + x^3 + x^2 + 1
-define(PRIMITIVE_POLY, 16#11D).

-spec add(0..255, 0..255) -> 0..255.
add(A, B) ->
    A bxor B.

-spec sub(0..255, 0..255) -> 0..255.
sub(A, B) ->
    A bxor B.

-spec mult(0..255, 0..255) -> 0..255.
mult(0, _) -> 0;
mult(_, 0) -> 0;
mult(A, B) ->
    Exp = exp_table(),
    Log = log_table(),
    LogA = binary:at(Log, A),
    LogB = binary:at(Log, B),
    binary:at(Exp, (LogA + LogB) rem 255).

-spec divide(0..255, 0..255) -> 0..255.
divide(_A, 0) -> error(division_by_zero);
divide(0, _B) -> 0;
divide(A, B) ->
    Exp = exp_table(),
    Log = log_table(),
    LogA = binary:at(Log, A),
    LogB = binary:at(Log, B),
    Diff = (LogA - LogB + 255) rem 255,
    binary:at(Exp, Diff).

-spec inv(0..255) -> 0..255.
inv(0) -> error(division_by_zero);
inv(A) ->
    Exp = exp_table(),
    Log = log_table(),
    LogA = binary:at(Log, A),
    binary:at(Exp, (255 - LogA) rem 255).

-spec pow(0..255, non_neg_integer()) -> 0..255.
pow(0, _P) -> 0;
pow(_A, 0) -> 1;
pow(A, P) ->
    Exp = exp_table(),
    Log = log_table(),
    LogA = binary:at(Log, A),
    binary:at(Exp, (LogA * P) rem 255).

-spec poly_eval([0..255], 0..255) -> 0..255.
poly_eval(Poly, X) ->
    %% Horner's method: Poly = [C_n, ..., C_1, C_0]
    lists:foldl(fun(Coeff, Acc) ->
        add(mult(Acc, X), Coeff)
    end, 0, Poly).

-spec poly_add([0..255], [0..255]) -> [0..255].
poly_add(P1, P2) ->
    L1 = length(P1),
    L2 = length(P2),
    MaxLen = max(L1, L2),
    PadP1 = lists:duplicate(MaxLen - L1, 0) ++ P1,
    PadP2 = lists:duplicate(MaxLen - L2, 0) ++ P2,
    [add(A, B) || {A, B} <- lists:zip(PadP1, PadP2)].

-spec poly_scale([0..255], 0..255) -> [0..255].
poly_scale(Poly, Scalar) ->
    [mult(C, Scalar) || C <- Poly].

-spec poly_mult([0..255], [0..255]) -> [0..255].
poly_mult(P1, P2) ->
    L1 = length(P1),
    L2 = length(P2),
    ResLen = L1 + L2 - 1,
    Array = array:new(ResLen, {default, 0}),
    NewArray = lists:foldl(fun({I, C1}, Acc1) ->
        lists:foldl(fun({J, C2}, Acc2) ->
            Idx = I + J,
            Current = array:get(Idx, Acc2),
            array:set(Idx, add(Current, mult(C1, C2)), Acc2)
        end, Acc1, lists:zip(lists:seq(0, L2 - 1), P2))
    end, Array, lists:zip(lists:seq(0, L1 - 1), P1)),
    array:to_list(NewArray).

%% Exponentiation and Logarithm tables
-spec exp_table() -> binary().
exp_table() ->
    persistent_term:get({?MODULE, exp_table}, init_tables()).

-spec log_table() -> binary().
log_table() ->
    persistent_term:get({?MODULE, log_table}, init_tables_log()).

init_tables() ->
    {ExpBin, LogBin} = build_tables(),
    persistent_term:put({?MODULE, exp_table}, ExpBin),
    persistent_term:put({?MODULE, log_table}, LogBin),
    ExpBin.

init_tables_log() ->
    {_ExpBin, LogBin} = build_tables(),
    persistent_term:put({?MODULE, log_table}, LogBin),
    LogBin.

build_tables() ->
    {ExpList, _FinalVal} = lists:foldl(fun(_I, {Acc, Val}) ->
        NextVal = case (Val bsl 1) of
            V when V >= 256 -> V bxor ?PRIMITIVE_POLY;
            V -> V
        end,
        {[Val | Acc], NextVal}
    end, {[], 1}, lists:seq(0, 511)),
    
    RevExp = lists:reverse(ExpList),
    ExpBin = list_to_binary(RevExp),

    LogArray = lists:foldl(fun(I, Acc) ->
        V = lists:nth(I + 1, RevExp),
        array:set(V, I rem 255, Acc)
    end, array:new(256, {default, 0}), lists:seq(0, 254)),

    LogBin = list_to_binary(array:to_list(LogArray)),
    {ExpBin, LogBin}.
