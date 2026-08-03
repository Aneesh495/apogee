%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_bpsec
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_bpsec_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

bpsec_signature_verification_test() ->
    SecretKey = <<"SECRET_MISSION_ENCRYPTION_KEY_256">>,
    Bundle = apogee_bpv7:new_bundle("ipn:1.1", "ipn:2.1", 3600000, <<"MISSION_CRITICAL_TELECOMMAND">>),
    {BundleSigned, BIBCbor} = apogee_bpsec:sign_payload(Bundle, SecretKey, "ipn:1.1"),
    ?assert(is_binary(BIBCbor)),

    %% Verification with correct key
    ?assertEqual({ok, verified}, apogee_bpsec:verify_payload(BundleSigned, SecretKey, BIBCbor)),

    %% Verification with wrong key
    WrongKey = <<"WRONG_KEY_ATTACKER_SIGNATURE_000">>,
    ?assertEqual({error, signature_mismatch}, apogee_bpsec:verify_payload(BundleSigned, WrongKey, BIBCbor)),

    %% Tampered payload
    TamperedBundle = BundleSigned#bpv7_bundle{payload = <<"TAMPERED_TELECOMMAND">>},
    ?assertEqual({error, signature_mismatch}, apogee_bpsec:verify_payload(TamperedBundle, SecretKey, BIBCbor)).
