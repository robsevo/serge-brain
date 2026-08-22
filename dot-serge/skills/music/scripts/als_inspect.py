#!/usr/bin/env python3
"""Inspect an Ableton Live file without Live. READ-ONLY — never writes.

Usage: python3 als_inspect.py FILE.als
Works on .als (project), .adg (device group), .adv (preset) — all gzipped XML.
Prints JSON: tempo, tracks (type/name/devices/clip names), or a generic XML
outline when the schema isn't recognized (Live versions differ; smoke-tested
on synthetic data — verify once against a real project).
"""
import gzip, json, sys
from collections import Counter
from pathlib import Path

from defusedxml import ElementTree as ET

TRACK_TAGS = {"AudioTrack", "MidiTrack", "ReturnTrack", "GroupTrack"}


def localname(el):
    return el.tag.rsplit("}", 1)[-1]


def value_attr(el):
    return el.get("Value") if el is not None else None


def first_by_tag(root, tag):
    for el in root.iter():
        if localname(el) == tag:
            return el
    return None


def inspect(path: Path):
    with gzip.open(path, "rb") as f:
        root = ET.parse(f).getroot()

    out = {"file": str(path), "root_tag": localname(root)}

    tempo_el = first_by_tag(root, "Tempo")
    if tempo_el is not None:
        manual = first_by_tag(tempo_el, "Manual")
        if value_attr(manual):
            try:
                out["tempo_bpm"] = float(value_attr(manual))
            except ValueError:
                # A non-numeric tempo means an unexpected .als layout: report the
                # rest of the project rather than failing the whole inspection.
                pass

    tracks = []
    for el in root.iter():
        if localname(el) not in TRACK_TAGS:
            continue
        t = {"type": localname(el)}
        # NB: childless Elements are falsy — never chain them with `or`.
        name_el = first_by_tag(el, "EffectiveName")
        if name_el is None:
            name_el = first_by_tag(el, "UserName")
        if value_attr(name_el):
            t["name"] = value_attr(name_el)
        devices_el = first_by_tag(el, "Devices")
        if devices_el is not None:
            t["devices"] = [localname(d) for d in list(devices_el)][:20]
        clips = []
        for c in el.iter():
            if localname(c) in {"AudioClip", "MidiClip"}:
                cn = first_by_tag(c, "Name")
                clips.append(value_attr(cn) or localname(c))
        if clips:
            t["clips"] = clips[:40]
        tracks.append(t)

    if tracks:
        out["n_tracks"] = len(tracks)
        out["tracks"] = tracks
    else:
        # Unrecognized schema: give an honest generic outline instead of nothing.
        out["note"] = "no known track tags found — generic element outline follows"
        out["top_level"] = [localname(c) for c in list(root)]
        out["element_histogram"] = dict(Counter(localname(e) for e in root.iter()).most_common(25))
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    print(json.dumps(inspect(Path(sys.argv[1])), indent=2))
