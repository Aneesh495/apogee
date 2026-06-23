%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Apogee core header file.
%%% Defines astronomical, physical, CCSDS, and DTN constants.
%%% @end
%%%-------------------------------------------------------------------
-ifndef(APOGEE_HRL).
-define(APOGEE_HRL, true).

%% Astronomical and physical constants
-define(EARTH_RADIUS_KM, 6378.137).
-define(EARTH_FLATTENING, 0.0033528106647474805). % 1.0 / 298.257223563
-define(EARTH_SEMI_MINOR_KM, (?EARTH_RADIUS_KM * (1.0 - ?EARTH_FLATTENING))).
-define(EARTH_ECCENTRICITY_SQ, (?EARTH_FLATTENING * (2.0 - ?EARTH_FLATTENING))).
-define(EARTH_MU, 398600.4418).                   % km^3 / s^2
-define(EARTH_J2, 1.08262668e-3).
-define(EARTH_J3, -2.5327e-6).
-define(EARTH_J4, -1.6196e-6).
-define(SPEED_OF_LIGHT_KM_S, 299792.458).
-define(SOLAR_CONSTANT_W_M2, 1361.0).
-define(STEFAN_BOLTZMANN, 5.670374419e-8).
-define(DEEP_SPACE_TEMP_K, 3.0).
-define(PI, 3.14159265358979323846).
-define(TWO_PI, 6.28318530717958647692).
-define(RAD_TO_DEG, 57.29577951308232).
-define(DEG_TO_RAD, 0.017453292519943295).

%% CCSDS Protocol constants
-define(CCSDS_ASM, 16#1ACFFC1D).
-define(CCSDS_ASM_SIZE_BITS, 32).
-define(CCSDS_MAX_FRAME_SIZE, 1024).
-define(CCSDS_CLCW_SIZE_BYTES, 4).
-define(CCSDS_POLY_SCRAMBLER, 16#A9). % x^8 + x^7 + x^5 + x^3 + 1

%% CCSDS Packet Type
-define(CCSDS_TYPE_TM, 0).
-define(CCSDS_TYPE_TC, 1).

%% CCSDS Sequence Flags
-define(CCSDS_SEQ_CONTINUATION, 0).
-define(CCSDS_SEQ_FIRST, 1).
-define(CCSDS_SEQ_LAST, 2).
-define(CCSDS_SEQ_UNSEGMENTED, 3).

%% DTN Bundle Protocol Version 7 constants (RFC 9171)
-define(BPV7_VERSION, 7).
-define(BPV7_CR_NONE, 0).
-define(BPV7_CR_CRC16, 1).
-define(BPV7_CR_CRC32, 2).

%% Block Types
-define(BPV7_BLOCK_PAYLOAD, 1).
-define(BPV7_BLOCK_PREVIOUS_NODE, 6).
-define(BPV7_BLOCK_BUNDLE_AGE, 7).
-define(BPV7_BLOCK_HOP_COUNT, 10).

%% Bundle Processing Control Flags (bit masks)
-define(BPV7_FLAG_IS_FRAGMENT,       16#000001).
-define(BPV7_FLAG_ADMIN_RECORD,      16#000002).
-define(BPV7_FLAG_NOT_FRAGMENTABLE,  16#000004).
-define(BPV7_FLAG_ACK_REQUESTED,     16#000020).
-define(BPV7_FLAG_STATUS_TIME_REQ,   16#000040).
-define(BPV7_FLAG_REQ_RECEPTION_RPT, 16#004000).
-define(BPV7_FLAG_REQ_FORWARD_RPT,   16#010000).
-define(BPV7_FLAG_REQ_DELIVERY_RPT,  16#020000).
-define(BPV7_FLAG_REQ_DELETION_RPT,  16#040000).

%% Administrative Record Types
-define(BPV7_ADMIN_STATUS_REPORT, 1).

%% Status Report Reason Codes
-define(BPV7_REASON_NO_INFO, 0).
-define(BPV7_REASON_LIFETIME_EXPIRED, 1).
-define(BPV7_REASON_FORWARDED_OVER_UNIDIR_LINK, 2).
-define(BPV7_REASON_TRANSMISSION_CANCELLED, 3).
-define(BPV7_REASON_DEPLETED_STORAGE, 4).
-define(BPV7_REASON_DEST_UNINTELLIGIBLE, 5).
-define(BPV7_REASON_NO_KNOWN_ROUTE, 6).
-define(BPV7_REASON_NO_TIMELY_CONTACT, 7).
-define(BPV7_REASON_BLOCK_UNINTELLIGIBLE, 8).
-define(BPV7_REASON_HOP_LIMIT_EXCEEDED, 9).

%% Records
-record(vector3, {
    x = 0.0 :: float(),
    y = 0.0 :: float(),
    z = 0.0 :: float()
}).

-record(quaternion, {
    w = 1.0 :: float(),
    x = 0.0 :: float(),
    y = 0.0 :: float(),
    z = 0.0 :: float()
}).

-record(matrix3, {
    r11 = 1.0 :: float(), r12 = 0.0 :: float(), r13 = 0.0 :: float(),
    r21 = 0.0 :: float(), r22 = 1.0 :: float(), r23 = 0.0 :: float(),
    r31 = 0.0 :: float(), r32 = 0.0 :: float(), r33 = 1.0 :: float()
}).

-record(geodetic, {
    lat = 0.0 :: float(), % degrees
    lon = 0.0 :: float(), % degrees
    alt = 0.0 :: float()  % km above WGS-84 ellipsoid
}).

-record(tle, {
    name = <<>> :: binary(),
    sat_num = 0 :: non_neg_integer(),
    classification = $U :: char(),
    id_year = 0 :: non_neg_integer(),
    id_launch = 0 :: non_neg_integer(),
    id_piece = <<>> :: binary(),
    epoch_year = 0 :: non_neg_integer(),
    epoch_day = 0.0 :: float(),
    bstar = 0.0 :: float(),
    inclination = 0.0 :: float(),    % radians
    raan = 0.0 :: float(),           % radians (right ascension of ascending node)
    eccentricity = 0.0 :: float(),
    arg_perigee = 0.0 :: float(),    % radians (argument of perigee)
    mean_anomaly = 0.0 :: float(),   % radians
    mean_motion = 0.0 :: float(),    % rad/s
    rev_num = 0 :: non_neg_integer()
}).

-record(orbit_state, {
    epoch = 0.0 :: float(), % Julian Date
    pos = #vector3{} :: #vector3{}, % km TEME
    vel = #vector3{} :: #vector3{}  % km/s TEME
}).

-record(ccsds_packet, {
    version = 0 :: non_neg_integer(),
    type = ?CCSDS_TYPE_TM :: 0 | 1,
    sec_hdr_flag = 0 :: 0 | 1,
    apid = 0 :: 0..2047,
    seq_flags = ?CCSDS_SEQ_UNSEGMENTED :: 0..3,
    seq_count = 0 :: 0..16383,
    data_length = 0 :: non_neg_integer(),
    timestamp = 0 :: non_neg_integer(),
    payload = <<>> :: binary()
}).

-record(bpv7_bundle, {
    version = ?BPV7_VERSION :: non_neg_integer(),
    flags = 0 :: non_neg_integer(),
    crc_type = ?BPV7_CR_CRC32 :: non_neg_integer(),
    destination = <<>> :: binary(),
    source = <<>> :: binary(),
    report_to = <<>> :: binary(),
    creation_time = 0 :: non_neg_integer(),
    sequence_number = 0 :: non_neg_integer(),
    lifetime_ms = 86400000 :: non_neg_integer(),
    fragment_offset = 0 :: non_neg_integer(),
    total_app_data_len = 0 :: non_neg_integer(),
    previous_node = undefined :: binary() | undefined,
    hop_count = undefined :: {non_neg_integer(), non_neg_integer()} | undefined, % {limit, count}
    bundle_age_ms = 0 :: non_neg_integer(),
    payload = <<>> :: binary(),
    custody_id = undefined :: binary() | undefined
}).

-record(contact, {
    id = <<>> :: binary(),
    from_node = <<>> :: binary(),
    to_node = <<>> :: binary(),
    start_time = 0.0 :: float(),     % Julian Date or seconds
    end_time = 0.0 :: float(),       % Julian Date or seconds
    data_rate_bps = 1000000 :: non_neg_integer(), % bits per second
    range_delay_s = 0.0 :: float(),  % one-way light time in seconds
    confidence = 1.0 :: float(),     % probability of contact [0.0, 1.0]
    total_capacity_bytes = 0 :: non_neg_integer(),
    reserved_bytes = 0 :: non_neg_integer()
}).

-record(tc_frame, {
    version = 0 :: 0..3,
    bypass_flag = 0 :: 0 | 1,
    control_cmd_flag = 0 :: 0 | 1,
    scid = 0 :: 0..1023,
    vcid = 0 :: 0..63,
    frame_seq_num = 0 :: 0..255,
    data = <<>> :: binary(),
    fecf = 0 :: non_neg_integer()
}).

-record(clcw, {
    version = 0 :: 0..3,
    status_field = 0 :: 0..7,
    cop_in_effect = 1 :: 0..3,
    vcid = 0 :: 0..63,
    no_rf = false :: boolean(),
    no_bit_lock = false :: boolean(),
    lockout = false :: boolean(),
    wait = false :: boolean(),
    retransmit = false :: boolean(),
    farm_b_counter = 0 :: 0..3,
    report_value = 0 :: 0..255
}).

-record(ground_pass, {
    station_id = <<>> :: binary(),
    sat_id = <<>> :: binary(),
    aos_jd = 0.0 :: float(),
    los_jd = 0.0 :: float(),
    tca_jd = 0.0 :: float(),
    duration_s = 0.0 :: float(),
    max_elevation_deg = 0.0 :: float(),
    min_range_km = 0.0 :: float(),
    capacity_bytes = 0 :: non_neg_integer()
}).

-endif.
