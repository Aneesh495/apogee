%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc RFC 9171 Section 6.1 Administrative Records & Bundle Status Reports.
%%% Formats, encodes, and decodes administrative records for bundle reception,
%%% forwarding, delivery, and deletion with standard IANA reason codes.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_admin_record).

-include("apogee.hrl").

-export([
    create_status_report/4,
    encode/1,
    decode/1,
    status_report_to_bundle/2
]).

-record(status_report, {
    status_flags = #{received => false, forwarded => false, delivered => false, deleted => false} :: map(),
    status_timestamps = #{} :: map(),
    reason_code = ?BPV7_REASON_NO_INFO :: non_neg_integer(),
    subject_source = <<>> :: binary(),
    subject_creation_time = 0 :: non_neg_integer(),
    subject_seq_num = 0 :: non_neg_integer(),
    fragment_offset = 0 :: non_neg_integer(),
    fragment_length = 0 :: non_neg_integer()
}).

-type status_report() :: #status_report{}.
-export_type([status_report/0]).

-spec create_status_report(#bpv7_bundle{}, atom(), non_neg_integer(), non_neg_integer()) -> status_report().
create_status_report(#bpv7_bundle{} = Subject, StatusType, ReasonCode, Timestamp) ->
    Flags0 = #{received => false, forwarded => false, delivered => false, deleted => false},
    Flags = Flags0#{StatusType => true},
    Timestamps = #{StatusType => Timestamp},
    #status_report{
        status_flags = Flags,
        status_timestamps = Timestamps,
        reason_code = ReasonCode,
        subject_source = Subject#bpv7_bundle.source,
        subject_creation_time = Subject#bpv7_bundle.creation_time,
        subject_seq_num = Subject#bpv7_bundle.sequence_number,
        fragment_offset = Subject#bpv7_bundle.fragment_offset,
        fragment_length = Subject#bpv7_bundle.total_app_data_len
    }.

-spec encode(status_report()) -> binary().
encode(#status_report{} = R) ->
    %% Record Type 1: Bundle Status Report
    StatusArray = [
        encode_status_item(maps:get(received, R#status_report.status_flags, false), maps:get(received, R#status_report.status_timestamps, undefined)),
        encode_status_item(maps:get(forwarded, R#status_report.status_flags, false), maps:get(forwarded, R#status_report.status_timestamps, undefined)),
        encode_status_item(maps:get(delivered, R#status_report.status_flags, false), maps:get(delivered, R#status_report.status_timestamps, undefined)),
        encode_status_item(maps:get(deleted, R#status_report.status_flags, false), maps:get(deleted, R#status_report.status_timestamps, undefined))
    ],

    {ok, SrcEid} = apogee_eid:parse(R#status_report.subject_source),
    SrcCbor = apogee_eid:encode_cbor(SrcEid),
    CreationTimestamp = [R#status_report.subject_creation_time, R#status_report.subject_seq_num],

    RecordContent = [
        StatusArray,
        R#status_report.reason_code,
        SrcCbor,
        CreationTimestamp
    ],

    AdminRecord = [?BPV7_ADMIN_STATUS_REPORT, RecordContent],
    apogee_cbor:encode(AdminRecord).

encode_status_item(false, _) ->
    false;
encode_status_item(true, undefined) ->
    true;
encode_status_item(true, Ts) ->
    [true, Ts].

-spec decode(binary()) -> {ok, status_report()} | {error, term()}.
decode(Binary) ->
    case apogee_cbor:decode_one(Binary) of
        {ok, [?BPV7_ADMIN_STATUS_REPORT, RecordContent]} when is_list(RecordContent), length(RecordContent) >= 4 ->
            [StatusArray, ReasonCode, SrcCbor, [CreationTime, SeqNum] | _] = RecordContent,
            {ok, SrcEid} = apogee_eid:decode_cbor(SrcCbor),

            {Flags, Timestamps} = parse_status_array(StatusArray),
            Report = #status_report{
                status_flags = Flags,
                status_timestamps = Timestamps,
                reason_code = ReasonCode,
                subject_source = apogee_eid:format(SrcEid),
                subject_creation_time = CreationTime,
                subject_seq_num = SeqNum
            },
            {ok, Report};
        _ ->
            {error, invalid_admin_record}
    end.

parse_status_array([Recv, Fwd, Dlv, Del]) ->
    F1 = #{
        received => is_status_true(Recv),
        forwarded => is_status_true(Fwd),
        delivered => is_status_true(Dlv),
        deleted => is_status_true(Del)
    },
    T1 = add_ts(deleted, Del,
            add_ts(delivered, Dlv,
                add_ts(forwarded, Fwd,
                    add_ts(received, Recv, #{})))),
    {F1, T1};
parse_status_array(_) ->
    {#{}, #{}}.

is_status_true(true) -> true;
is_status_true([true, _]) -> true;
is_status_true(_) -> false.

add_ts(Key, [true, Ts], Map) when is_integer(Ts) -> Map#{Key => Ts};
add_ts(_Key, _Val, Map) -> Map.

-spec status_report_to_bundle(status_report(), binary() | string()) -> #bpv7_bundle{}.
status_report_to_bundle(#status_report{} = Report, ReportingNodeEid) ->
    AdminPayload = encode(Report),
    Bundle = apogee_bpv7:new_bundle(ReportingNodeEid, Report#status_report.subject_source, 86400000, AdminPayload),
    %% Set administrative record flag
    Flags = Bundle#bpv7_bundle.flags bor ?BPV7_FLAG_ADMIN_RECORD,
    Bundle#bpv7_bundle{flags = Flags}.
