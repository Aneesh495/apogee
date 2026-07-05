%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc CCSDS Reed-Solomon (255, 223) Error Correction Codec.
%%% Implements systematic polynomial encoding, syndrome calculation,
%%% Berlekamp-Massey error locator determination, Chien root search,
%%% and Forney error evaluation. Corrects up to 16 corrupted octets per block.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_rs).

-export([
    encode/1,
    decode/1,
    generator_poly/0,
    calculate_syndromes/1
]).

-define(N, 255).
-define(K, 223).
-define(T, 16).
-define(TWO_T, 32).
-define(FCR, 112). % First Consecutive Root

-spec generator_poly() -> [0..255].
generator_poly() ->
    persistent_term:get({?MODULE, generator_poly}, init_generator()).

init_generator() ->
    %% g(x) = product_{j=112}^{143} (x - alpha^j)
    G = lists:foldl(fun(J, Poly) ->
        Root = apogee_gf256:pow(2, J),
        apogee_gf256:poly_mult(Poly, [1, Root])
    end, [1], lists:seq(?FCR, ?FCR + ?TWO_T - 1)),
    persistent_term:put({?MODULE, generator_poly}, G),
    G.

-spec encode(binary()) -> binary().
encode(Message) when is_binary(Message) ->
    MsgLen = byte_size(Message),
    case MsgLen =< ?K of
        true ->
            MsgList = binary_to_list(Message),
            %% Shortened RS code: zero-pad front to length K
            PadLen = ?K - MsgLen,
            FullMsg = lists:duplicate(PadLen, 0) ++ MsgList,
            G = generator_poly(),
            Parity = calculate_parity(FullMsg, G),
            <<Message/binary, (list_to_binary(Parity))/binary>>;
        false ->
            error(message_too_long_for_rs_block)
    end.

calculate_parity(MsgList, G) ->
    %% LFSR systematic division
    LFSR0 = lists:duplicate(?TWO_T, 0),
    FinalLFSR = lists:foldl(fun(Byte, LFSR) ->
        Feedback = apogee_gf256:add(Byte, hd(LFSR)),
        Shifted = tl(LFSR) ++ [0],
        case Feedback of
            0 ->
                Shifted;
            _ ->
                %% Subtract Feedback * G(x) from shifted LFSR
                [apogee_gf256:add(L, apogee_gf256:mult(Feedback, GCoeff))
                 || {L, GCoeff} <- lists:zip(Shifted, tl(G))]
        end
    end, LFSR0, MsgList),
    FinalLFSR.

-spec decode(binary()) -> {ok, binary(), non_neg_integer()} | {error, uncorrectable_error}.
decode(Codeword) when is_binary(Codeword) ->
    TotalLen = byte_size(Codeword),
    case TotalLen >= ?TWO_T of
        true ->
            MsgLen = TotalLen - ?TWO_T,
            PadLen = ?K - MsgLen,
            FullCodeword = lists:duplicate(PadLen, 0) ++ binary_to_list(Codeword),
            Syndromes = calculate_syndromes(FullCodeword),
            case lists:all(fun(S) -> S =:= 0 end, Syndromes) of
                true ->
                    %% Zero syndromes: codeword is clean!
                    <<CleanMsg:MsgLen/binary, _Parity/binary>> = Codeword,
                    {ok, CleanMsg, 0};
                false ->
                    %% Corrupted codeword: run Berlekamp-Massey and Chien search
                    case berlekamp_massey(Syndromes) of
                        {ok, Lambda} ->
                            case chien_search(Lambda) of
                                {ok, ErrorPositions} ->
                                    Errors = forney(Lambda, Syndromes, ErrorPositions),
                                    CorrectedFull = apply_corrections(FullCodeword, ErrorPositions, Errors),
                                    CorrectedMsgList = lists:sublist(CorrectedFull, PadLen + 1, MsgLen),
                                    NumErrors = length(ErrorPositions),
                                    {ok, list_to_binary(CorrectedMsgList), NumErrors};
                                {error, _} ->
                                    {error, uncorrectable_error}
                            end;
                        {error, _} ->
                            {error, uncorrectable_error}
                    end
            end;
        false ->
            {error, codeword_too_short}
    end.

-spec calculate_syndromes([0..255]) -> [0..255].
calculate_syndromes(CodewordList) ->
    [apogee_gf256:poly_eval(CodewordList, apogee_gf256:pow(2, J))
     || J <- lists:seq(?FCR, ?FCR + ?TWO_T - 1)].

%% Berlekamp-Massey algorithm for error locator polynomial Lambda(x)
berlekamp_massey(Syndromes) ->
    berlekamp_loop(Syndromes, 0, [1], [1], 1, 0).

berlekamp_loop(_Syndromes, K, Lambda, _B, _L, _M) when K >= ?TWO_T ->
    {ok, Lambda};
berlekamp_loop(Syndromes, K, Lambda, B, L, M) ->
    Sk = lists:nth(K + 1, Syndromes),
    %% Delta = S_k + sum_{i=1}^L Lambda_i * S_{k-i}
    Delta = lists:foldl(fun(I, Acc) ->
        case I =< length(Lambda) - 1 of
            true ->
                LambdaI = lists:nth(length(Lambda) - I, Lambda),
                SPrev = lists:nth(K - I + 1, Syndromes),
                apogee_gf256:add(Acc, apogee_gf256:mult(LambdaI, SPrev));
            false ->
                Acc
        end
    end, Sk, lists:seq(1, L)),

    case Delta of
        0 ->
            berlekamp_loop(Syndromes, K + 1, Lambda, [0 | B], L, M + 1);
        _ ->
            T = apogee_gf256:poly_add(Lambda, apogee_gf256:poly_scale(B, Delta)),
            if
                2 * L =< K ->
                    InvDelta = apogee_gf256:inv(Delta),
                    NewB = [0 | apogee_gf256:poly_scale(Lambda, InvDelta)],
                    berlekamp_loop(Syndromes, K + 1, T, NewB, K + 1 - L, 1);
                true ->
                    berlekamp_loop(Syndromes, K + 1, T, [0 | B], L, M + 1)
            end
    end.

%% Chien root search over GF(256)
chien_search(Lambda) ->
    Deg = length(Lambda) - 1,
    Roots = lists:filtermap(fun(I) ->
        InvAlphaI = apogee_gf256:pow(2, (255 - I) rem 255),
        case apogee_gf256:poly_eval(Lambda, InvAlphaI) of
            0 -> {true, (?N - 1 - I)};
            _ -> false
        end
    end, lists:seq(0, ?N - 1)),

    case length(Roots) =:= Deg of
        true -> {ok, Roots};
        false -> {error, roots_not_equal_to_degree}
    end.

%% Forney algorithm for error values
forney(Lambda, Syndromes, ErrorPositions) ->
    %% Omega(x) = [Syndromes(x) * Lambda(x)] mod x^(2T)
    OmegaFull = apogee_gf256:poly_mult(lists:reverse(Syndromes), Lambda),
    Omega = lists:sublist(OmegaFull, max(1, length(OmegaFull) - ?TWO_T + 1)),
    
    %% Lambda' (formal derivative)
    LambdaPrime = formal_derivative(Lambda),

    [begin
        XiInv = apogee_gf256:pow(2, Pos),
        Xi = apogee_gf256:inv(XiInv),
        Num = apogee_gf256:poly_eval(Omega, Xi),
        Den = apogee_gf256:poly_eval(LambdaPrime, Xi),
        apogee_gf256:mult(apogee_gf256:pow(Xi, 1 - ?FCR), apogee_gf256:divide(Num, max(1, Den)))
     end || Pos <- ErrorPositions].

formal_derivative(Poly) ->
    Len = length(Poly),
    [lists:nth(I, Poly) || I <- lists:seq(1, Len), (Len - I) rem 2 =:= 1].

apply_corrections(Codeword, Positions, Errors) ->
    Array = array:from_list(Codeword),
    UpdatedArray = lists:foldl(fun({Pos, Err}, Acc) ->
        OldVal = array:get(Pos, Acc),
        array:set(Pos, apogee_gf256:add(OldVal, Err), Acc)
    end, Array, lists:zip(Positions, Errors)),
    array:to_list(UpdatedArray).
