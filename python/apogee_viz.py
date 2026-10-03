#!/usr/bin/env python3
"""
Apogee Orbital Constellation & Contact Schedule Visualizer.
Author: Aneesh Krishna

Generates vector SVG orbital projections, 3D celestial sphere ground tracks,
and Contact Graph Routing (CGR) contact window Gantt schedules.
Zero external dependencies: uses standard library math, json, and svg writing.
"""

import math
import json
import argparse
import sys
from typing import List, Dict, Tuple, Any

EARTH_RADIUS_KM = 6378.137
EARTH_MU = 398600.4418
DEG_TO_RAD = math.pi / 180.0
RAD_TO_DEG = 180.0 / math.pi


def generate_walker_delta(
    total_sats: int,
    planes: int,
    phasing: int,
    altitude_km: float = 550.0,
    inclination_deg: float = 53.0
) -> List[Dict[str, Any]]:
    """Generates orbital state parameters for Walker-Delta constellation."""
    sats_per_plane = total_sats // planes
    a = EARTH_RADIUS_KM + altitude_km
    n_rad_s = math.sqrt(EARTH_MU / (a ** 3))
    inc_rad = inclination_deg * DEG_TO_RAD

    sats = []
    for p in range(planes):
        raan = (p * 2.0 * math.pi) / planes
        for s in range(sats_per_plane):
            m_anom = (
                (s * 2.0 * math.pi / sats_per_plane)
                + (p * phasing * 2.0 * math.pi / total_sats)
            ) % (2.0 * math.pi)
            sat_id = f"SAT-P{p+1:02d}-S{s+1:02d}"
            sats.append({
                "id": sat_id,
                "plane": p + 1,
                "sat_num": s + 1,
                "semi_major_axis_km": a,
                "inclination_deg": inclination_deg,
                "raan_rad": raan,
                "mean_anomaly_rad": m_anom,
                "mean_motion_rad_s": n_rad_s
            })
    return sats


def propagate_orbit_sample(sat: Dict[str, Any], time_s: float) -> Tuple[float, float, float]:
    """Computes simplified inertial Cartesian position (x, y, z) at time_s."""
    a = sat["semi_major_axis_km"]
    inc = sat["inclination_deg"] * DEG_TO_RAD
    raan = sat["raan_rad"]
    m = (sat["mean_anomaly_rad"] + sat["mean_motion_rad_s"] * time_s) % (2.0 * math.pi)

    # Position in orbital plane
    x_orb = a * math.cos(m)
    y_orb = a * math.sin(m)

    # Rotate by inclination and RAAN
    x = x_orb * math.cos(raan) - y_orb * math.cos(inc) * math.sin(raan)
    y = x_orb * math.sin(raan) + y_orb * math.cos(inc) * math.cos(raan)
    z = y_orb * math.sin(inc)
    return (x, y, z)


def render_svg_constellation(sats: List[Dict[str, Any]], out_path: str, width: int = 800, height: int = 800):
    """Renders 3D orthographic projection of the Earth and orbital planes into SVG."""
    cx = width / 2.0
    cy = height / 2.0
    scale = (width * 0.38) / (EARTH_RADIUS_KM + 1000.0)
    earth_r = EARTH_RADIUS_KM * scale

    svg_parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
        f'width="{width}" height="{height}" style="background-color: #0b0f19;">',
        f'<defs>',
        f'  <radialGradient id="earthGrad" cx="40%" cy="35%" r="65%">',
        f'    <stop offset="0%" stop-color="#1e3a5f"/>',
        f'    <stop offset="70%" stop-color="#0d1b2a"/>',
        f'    <stop offset="100%" stop-color="#050811"/>',
        f'  </radialGradient>',
        f'</defs>',
        f'<text x="30" y="45" fill="#e0e6ed" font-family="monospace" font-size="18" font-weight="bold">'
        f'APOGEE :: ORBITAL CONSTELLATION VISUALIZER</text>',
        f'<text x="30" y="70" fill="#78909c" font-family="monospace" font-size="12">'
        f'Walker-Delta {len(sats)} Satellites | Pure SVG Orthographic Projection</text>',
        # Earth Sphere
        f'<circle cx="{cx}" cy="{cy}" r="{earth_r}" fill="url(#earthGrad)" stroke="#264653" stroke-width="2"/>',
        f'<line x1="{cx - earth_r}" y1="{cy}" x2="{cx + earth_r}" y2="{cy}" stroke="#2a9d8f" stroke-dasharray="4,4" stroke-width="1"/>'
    ]

    # Draw orbits and satellites
    colors = ["#e76f51", "#f4a261", "#e9c46a", "#2a9d8f", "#457b9d"]
    for i, sat in enumerate(sats):
        col = colors[sat["plane"] % len(colors)]
        # Trace orbital ellipse
        pts = []
        for t in range(0, 5600, 100):
            x, y, z = propagate_orbit_sample(sat, float(t))
            sx = cx + x * scale
            sy = cy - z * scale
            pts.append(f"{sx:.1f},{sy:.1f}")
        svg_parts.append(f'<polyline points="{" ".join(pts)}" fill="none" stroke="{col}" stroke-opacity="0.3" stroke-width="1.2"/>')

        # Current satellite dot
        x, y, z = propagate_orbit_sample(sat, 0.0)
        sx = cx + x * scale
        sy = cy - z * scale
        svg_parts.append(f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="4" fill="{col}" stroke="#ffffff" stroke-width="1.5"/>')
        svg_parts.append(f'<text x="{sx + 6:.1f}" y="{sy + 3:.1f}" fill="{col}" font-family="monospace" font-size="9">{sat["id"]}</text>')

    svg_parts.append('</svg>')
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(svg_parts))


def render_svg_gantt(contacts: List[Dict[str, Any]], out_path: str, width: int = 900, height: int = 400):
    """Renders Contact Graph Routing (CGR) contact intervals into an SVG Gantt chart."""
    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
        f'width="{width}" height="{height}" style="background-color: #0b0f19;">',
        f'<text x="30" y="40" fill="#e0e6ed" font-family="monospace" font-size="16" font-weight="bold">'
        f'APOGEE :: CONTACT GRAPH ROUTING (CGR) SCHEDULE</text>',
        f'<line x1="160" y1="80" x2="850" y2="80" stroke="#37474f" stroke-width="1"/>'
    ]

    links = sorted(list({c["from_to"] for c in contacts}))
    y_offset = 110
    time_max = max(c["end_s"] for c in contacts) if contacts else 3600.0
    scale_x = 680.0 / max(1.0, time_max)

    for i, link in enumerate(links):
        svg.append(f'<text x="30" y="{y_offset + 14}" fill="#90a4ae" font-family="monospace" font-size="11">{link}</text>')
        # Axis guide
        svg.append(f'<line x1="160" y1="{y_offset + 10}" x2="850" y2="{y_offset + 10}" stroke="#1c2833" stroke-width="1"/>')
        y_offset += 35

    for c in contacts:
        link_idx = links.index(c["from_to"])
        y = 110 + link_idx * 35
        x = 160 + c["start_s"] * scale_x
        bar_w = max(4.0, (c["end_s"] - c["start_s"]) * scale_x)
        svg.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w:.1f}" height="18" rx="3" '
            f'fill="#00b4d8" fill-opacity="0.8" stroke="#90e0ef" stroke-width="1"/>'
        )

    svg.append('</svg>')
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(svg))


def main():
    parser = argparse.ArgumentParser(description="Apogee Orbital Constellation & CGR Visualizer")
    parser.add_argument("--demo", action="store_true", help="Generate demonstration visualizer SVG files")
    parser.add_argument("--sats", type=int, default=12, help="Total satellites (default: 12)")
    parser.add_argument("--planes", type=int, default=3, help="Orbital planes (default: 3)")
    parser.add_argument("--out", type=str, default="constellation.svg", help="Output file path")
    args = parser.parse_args()

    sats = generate_walker_delta(args.sats, args.planes, 1, 550.0, 53.0)
    print(f"Generated {len(sats)} satellites in {args.planes} planes.")
    
    render_svg_constellation(sats, args.out)
    print(f"Wrote constellation projection SVG to {args.out}")

    if args.demo:
        demo_contacts = [
            {"from_to": "SAT-01 -> SGS-Svalbard", "start_s": 100, "end_s": 720},
            {"from_to": "SAT-01 -> WSS-WhiteSands", "start_s": 1400, "end_s": 1950},
            {"from_to": "SAT-02 -> KRU-Kourou", "start_s": 500, "end_s": 1100},
            {"from_to": "SAT-01 -> SAT-02 (ISL)", "start_s": 0, "end_s": 3600}
        ]
        gantt_out = "cgr_schedule.svg"
        render_svg_gantt(demo_contacts, gantt_out)
        print(f"Wrote CGR schedule Gantt chart to {gantt_out}")


if __name__ == "__main__":
    main()
