/**
 * Typed DTN BPv7 and CCSDS Telemetry Client for Apogee Kernel.
 * Author: Aneesh Krishna
 *
 * Provides strongly-typed models, binary framing, CRC calculation, and
 * serialization for ground station client applications interfacing with
 * the Apogee Erlang kernel.
 */

declare const require: any;
declare const module: any;

export interface Vector3 {
  x: number;
  y: number;
  z: number;
}

export interface Quaternion {
  w: number;
  x: number;
  y: number;
  z: number;
}

export interface OrbitState {
  epochJd: number;
  positionKm: Vector3;
  velocityKmS: Vector3;
}

export interface TelemetrySnapshot {
  satelliteId: string;
  missionElapsedTimeS: number;
  flightMode: 'safe_hold' | 'detumble' | 'sun_pointing' | 'nadir_pointing' | 'nominal_science';
  orbit: OrbitState;
  batterySoc: number;
  busVoltageV: number;
  solarPowerW: number;
  wheelRpm: Vector3;
  pointingErrorDeg: number;
  queuedBundles: number;
}

export interface Bpv7Bundle {
  version: number;
  flags: number;
  crcType: number;
  source: string;
  destination: string;
  reportTo: string;
  creationTimeMs: number;
  sequenceNumber: number;
  lifetimeMs: number;
  payload: Uint8Array;
}

export class ApogeeClient {
  /**
   * Computes CRC-16-CCITT checksum (polynomial 0x1021, initial value 0xFFFF).
   */
  public static crc16Ccitt(data: Uint8Array): number {
    let crc = 0xffff;
    for (let i = 0; i < data.length; i++) {
      crc ^= data[i] << 8;
      for (let j = 0; j < 8; j++) {
        if ((crc & 0x8000) !== 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xffff;
        } else {
          crc = (crc << 1) & 0xffff;
        }
      }
    }
    return crc;
  }

  /**
   * Constructs and serializes a CCSDS Space Packet primary header and payload.
   */
  public static encodeCcsdsPacket(apid: number, seqCount: number, payload: Uint8Array): Uint8Array {
    const packetLength = payload.length - 1; // CCSDS definition: data length - 1
    const buffer = new Uint8Array(6 + payload.length);
    const view = new DataView(buffer.buffer);

    // Byte 0-1: Version (3 bits = 0), Type (1 bit = 0 TM), SecHdr (1 bit = 0), APID (11 bits)
    const word1 = ((apid & 0x7ff) | (0 << 11) | (0 << 12) | (0 << 13)) & 0xffff;
    view.setUint16(0, word1, false);

    // Byte 2-3: SeqFlags (2 bits = 3 unsegmented), SeqCount (14 bits)
    const word2 = ((3 << 14) | (seqCount & 0x3fff)) & 0xffff;
    view.setUint16(2, word2, false);

    // Byte 4-5: Packet Data Length (16 bits)
    view.setUint16(4, packetLength & 0xffff, false);

    // Byte 6+: Payload
    buffer.set(payload, 6);
    return buffer;
  }

  /**
   * Verifies the Attached Sync Marker (ASM 0x1ACFFC1D) of a CCSDS transfer frame.
   */
  public static verifyAsm(frame: Uint8Array): boolean {
    if (frame.length < 4) return false;
    return (
      frame[0] === 0x1a &&
      frame[1] === 0xcf &&
      frame[2] === 0xfc &&
      frame[3] === 0x1d
    );
  }

  /**
   * Creates a typed BPv7 bundle model.
   */
  public static createBundle(
    source: string,
    destination: string,
    payloadText: string,
    lifetimeSec: number = 86400
  ): Bpv7Bundle {
    const encoder = new TextEncoder();
    return {
      version: 7,
      flags: 0,
      crcType: 2, // CRC-32
      source,
      destination,
      reportTo: source,
      creationTimeMs: Date.now(),
      sequenceNumber: Math.floor(Math.random() * 1000000),
      lifetimeMs: lifetimeSec * 1000,
      payload: encoder.encode(payloadText)
    };
  }
}

// Self-contained module verification run
if (typeof require !== 'undefined' && require.main === module) {
  console.log("Running Apogee TypeScript Client verification pass...");
  
  // Test ASM
  const testAsm = new Uint8Array([0x1a, 0xcf, 0xfc, 0x1d, 0x00, 0x01]);
  const isAsmValid = ApogeeClient.verifyAsm(testAsm);
  console.log(`ASM Verification: ${isAsmValid ? 'PASS' : 'FAIL'}`);

  // Test CRC-16
  const testBytes = new Uint8Array([0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39]); // "123456789"
  const crc = ApogeeClient.crc16Ccitt(testBytes);
  console.log(`CRC-16 ("123456789"): 0x${crc.toString(16).toUpperCase()} (Expected: 0x29B1)`);

  // Test Packet Encoding
  const payload = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
  const pkt = ApogeeClient.encodeCcsdsPacket(42, 100, payload);
  console.log(`Encoded CCSDS Packet length: ${pkt.length} bytes (Expected: 10 bytes)`);

  // Test Bundle Creation
  const bundle = ApogeeClient.createBundle("ipn:1.1", "ipn:2.1", "Hello from TypeScript client");
  console.log(`Created BPv7 bundle to ${bundle.destination} with payload length ${bundle.payload.length}`);
  console.log("TypeScript client verification complete.");
}
