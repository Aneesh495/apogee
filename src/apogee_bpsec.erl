%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc RFC 9172 Bundle Security Protocol (BPSec).
%%% Implements Block Integrity Block (BIB) with HMAC-SHA256 cryptographic
%%% authentication over target canonical blocks.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_bpsec).

-include("apogee.hrl").

-export([
    sign_payload/3,
    verify_payload/2,
    verify_payload/3,
    compute_hmac_sha256/2
]).

-define(BPV7_BLOCK_BIB, 11).
-define(BPSEC_CTX_HMAC_SHA256, 1).

-spec compute_hmac_sha256(binary(), binary()) -> binary().
compute_hmac_sha256(Key, Data) ->
    crypto:mac(hmac, sha256, Key, Data).

-spec sign_payload(#bpv7_bundle{}, binary(), binary() | string()) -> {#bpv7_bundle{}, binary()}.
sign_payload(#bpv7_bundle{payload = Payload} = B, Key, SecuritySource) ->
    %% Calculate HMAC-SHA256 over target payload block
    Digest = compute_hmac_sha256(Key, Payload),
    SecuritySourceBin = to_binary(SecuritySource),

    %% Construct RFC 9172 BIB block structure
    TargetBlockNum = 1, % Target is Payload Block
    SecurityResultType = 1, % Integrity signature
    SecurityResult = [TargetBlockNum, SecurityResultType, Digest],

    BIBContent = [
        ?BPSEC_CTX_HMAC_SHA256,
        0, % Security flags
        SecuritySourceBin,
        [], % Security parameters
        [SecurityResult]
    ],
    BIBCbor = apogee_cbor:encode(BIBContent),
    {B, BIBCbor}.

-spec verify_payload(#bpv7_bundle{}, binary(), binary()) -> {ok, verified} | {error, term()}.
verify_payload(#bpv7_bundle{payload = Payload}, Key, BIBCbor) ->
    case apogee_cbor:decode_one(BIBCbor) of
        {ok, [?BPSEC_CTX_HMAC_SHA256, _Flags, _Src, _Params, [[TargetBlockNum, _Type, ExpectedDigest] | _]]} ->
            case TargetBlockNum of
                1 ->
                    ComputedDigest = compute_hmac_sha256(Key, Payload),
                    case ComputedDigest =:= ExpectedDigest of
                        true -> {ok, verified};
                        false -> {error, signature_mismatch}
                    end;
                _ ->
                    {error, unsupported_target_block}
            end;
        _ ->
            {error, invalid_bib_block}
    end.

-spec verify_payload(#bpv7_bundle{}, binary()) -> {ok, verified} | {error, term()}.
verify_payload(Bundle, Key) ->
    verify_payload(Bundle, Key, Bundle#bpv7_bundle.custody_id).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).
