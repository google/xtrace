#!/usr/bin/env python

# Copyright (C) 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from __future__ import print_function
import sys
import csv
import math
import os
import re

COUNTER_METADATA = {
    # Lower values are better (-1)
    "Clocks": -1,
    "% Vertex Fetch Stall": -1,
    "% Texture Fetch Stall": -1,
    "L1 Texture Cache Miss": -1,
    "% Texture L1 Miss": -1,
    "% Texture L2 Miss": -1,
    "% Stalled on System Memory": -1,
    "% ICache Miss": -1,
    "% Shaders Stalled": -1,
    "Preemption Delay": -1,
    "Pre-Clipped Polygons": -1,
    "% Prims Clipped": -1,
    "% Prims Trivially Rejected": -1,
    "Vertices Shaded": -1,
    "Fragments Shaded": -1,
    "Vertex Instructions": -1,
    "Fragment Instructions": -1,
    "ALU Instructions": -1,
    "EFU Instructions": -1,
    "Read Total": -1,
    "Write Total": -1,
    "Texture Memory Read": -1,
    "Vertex Memory Read": -1,
    "SP Memory Read": -1,
    "Textures / Vertex": -1,
    "Textures / Fragment": -1,
    "ALU / Vertex": -1,
    "ALU / Fragment": -1,
    "EFU / Fragment": -1,
    "EFU / Vertex": -1,
    "Bytes / Fragment": -1,
    "Bytes / Vertex": -1,
    "GPU MS": -1,
    "Overdraw": -1,

    # Higher values are better (1)
    "Reused Vertices": 1,
    "% Wave Context Occupancy": 1,
    "% Shader ALU Capacity Utilized": 1,

    # Neutral (0)
    "Vertices / Polygon": 0,
    "Polygon Area": 0,
    "% Shaders Busy": 0,
    "% Time ALUs Working": 0,
    "% Time EFUs Working": 0,
    "% Time Shading Fragments": 0,
    "% Time Shading Vertices": 0,
    "% Nearest Filtered": 0,
    "% Linear Filtered": 0,
    "% Anisotropic Filtered": 0,
    "% Non-Base Level Textures": 0,
    "% Non Base Level Textures": 0,
    "% Texture Pipes Busy": 0,
    "Frame Count": 0,
    "Events / Frame": 0,
    "Clocks / Second": 0,
    "Resolution Width": 0,
    "Resolution Height": 0
}

# Pre-process metadata into a sorted list of (lowercase_name, direction) for fast substring matching
# Longest strings first to ensure specific matches hit before generic ones.
PROCESSED_METADATA = sorted(
    [(k.lower(), v) for k, v in COUNTER_METADATA.items()],
    key=lambda item: len(item[0]),
    reverse=True
)

def get_counter_direction(name):
    name_lower = name.lower()
    for key, direction in PROCESSED_METADATA:
        if key in name_lower:
            return direction
    return 0

def parse_args():
    if "--" not in sys.argv:
        print("Usage: compare_counters.py <trace names...> -- <csv files...>")
        sys.exit(1)

    idx = sys.argv.index("--")
    trace_names = sys.argv[1:idx]
    csv_paths = sys.argv[idx + 1:]

    if len(trace_names) != len(csv_paths):
        print("Error: mismatch between trace names and csv files.")
        sys.exit(1)

    # Simplify trace names down to their basenames for cleaner output
    trace_names = [os.path.basename(t) for t in trace_names]
    return trace_names, csv_paths

def read_csv(path):
    data = {}

    # Python 2 csv module expects bytes ('rb'), Python 3 expects text with newline='' ('r')
    if sys.version_info[0] < 3:
        f = open(path, 'rb')
    else:
        f = open(path, 'r', newline='')

    with f:
        reader = csv.reader(f)
        try:
            headers = next(reader)
        except StopIteration:
            return [], {}

        # Validate that it's the expected CSV (starts with Counter)
        if not headers or headers[0] != "Counter":
            return [], {}

        for row in reader:
            if not row or not row[0]:
               continue
            counter_name = row[0]
            # row: [Counter, Binning, Render, Dispatch]
            values = []
            for val in row[1:]:
                try:
                    values.append(float(val))
                except ValueError:
                    values.append(0.0)
            data[counter_name] = values
    return headers[1:], data

def format_color(rgb, text):
    # RGB is a tuple (r,g,b). Default terminal text is when rgb is None
    if rgb is None:
        return text

    r, g, b = rgb
    return "\x1b[38;2;{0};{1};{2}m{3}\x1b[0m".format(int(r), int(g), int(b), text)

def get_color(value, baseline, direction, is_percent=False):
    if baseline == 0.0 and value == 0.0:
        return None

    if is_percent:
        diff = abs(value - baseline) / 100.0
    elif baseline == 0.0:
        diff = 1.0
    else:
        diff = abs(value - baseline) / baseline

    if diff < 0.01:
        return None

    diff_val = value - baseline

    if direction == 0:
        return None

    is_better = (diff_val < 0) if direction == -1 else (diff_val > 0)

    if is_better:
        return (60, 150, 60) # Green target
    else:
        return (190, 80, 80) # Red target

def make_dot_pad(pad_len, right=True):
    if pad_len <= 1:
        return " " * pad_len
    if right:
        dots = "." * (pad_len - 1)
        return " \x1b[90m{0}\x1b[0m".format(dots)
    else:
        dots = "." * (pad_len - 1)
        return "\x1b[90m{0}\x1b[0m ".format(dots)

def render_ascii(trace_names, stages, all_data):
    # Identify max counter name length (avoiding the py3-only default=0 in max())
    keys = list(all_data.keys())
    max_name_len = max(len(name) for name in keys) if keys else 0
    max_name_len = max(max_name_len, len("Counter Name"))

    # Print main header
    val_width = 15
    diff_width = 10

    header_row = "{0:>{1}}     ".format('Counter Name', max_name_len)
    for stage_name in stages:
        header_row += "{0:>{1}}{2:<{3}}".format(stage_name, val_width, '', diff_width)
    print("\x1b[1m{0}\x1b[0m".format(header_row))

    # Loop counters
    for counter_name in sorted(all_data.keys()):
        direction = get_counter_direction(counter_name)
        for trace_idx in range(len(trace_names)):
            if trace_idx == 0:
                row_str = "{0:>{1}} : 1 ".format(counter_name, max_name_len)
            else:
                row_str = "{0:>{1}}   {2} ".format('', max_name_len, trace_idx+1)

            is_percent = '%' in counter_name

            for stage_idx in range(len(stages)):
                val = all_data[counter_name][trace_idx][stage_idx]
                baseline = all_data[counter_name][0][stage_idx]

                diff_str = ""
                if trace_idx > 0 and (baseline != 0.0 or is_percent):
                    if is_percent:
                        pct = (val - baseline) / 100.0
                    else:
                        pct = (val - baseline) / baseline

                    abs_pct = abs(pct)
                    if abs_pct >= 0.001:
                        if abs_pct >= 0.1:
                            diff_str = " {0:+.0%}".format(pct)
                        else:
                            diff_str = " {0:+.1%}".format(pct)
                elif trace_idx > 0 and baseline == 0.0 and val != 0.0:
                    diff_str = " +inf%" if val > 0 else " -inf%"

                val_str_raw = "{0:.2f}".format(val)
                val_pad_len = max(0, val_width - len(val_str_raw))
                diff_pad_len = max(0, diff_width - len(diff_str))

                is_last_row = (trace_idx == len(trace_names) - 1)
                is_last_stage = (stage_idx == len(stages) - 1)

                if is_last_row:
                    v_pad = make_dot_pad(val_pad_len, False)
                    d_pad = " " * diff_pad_len if is_last_stage else make_dot_pad(diff_pad_len, True)
                else:
                    v_pad = " " * val_pad_len
                    d_pad = " " * diff_pad_len

                color = get_color(val, baseline, direction, is_percent)

                if color:
                    val_colored = format_color(color, val_str_raw)
                    diff_colored = format_color(color, diff_str)
                else:
                    val_colored = val_str_raw
                    diff_colored = diff_str

                cell_str = "{0}{1}{2}{3}".format(v_pad, val_colored, diff_colored, d_pad)

                row_str += cell_str

            print(row_str)

def main():
    trace_names, csv_paths = parse_args()

    stages = []
    # Structure: all_data[counter_name][trace_idx] = [stage_val1, stage_val2...]
    all_data = {}

    for trace_idx, path in enumerate(csv_paths):
        headers, data = read_csv(path)
        if not stages and headers:
            stages = headers

        for counter_name, values in data.items():
            if counter_name not in all_data:
                # If stages is still empty, something went wrong with all files
                if not stages:
                    continue
                all_data[counter_name] = [[0.0] * len(stages) for _ in range(len(trace_names))]

            # fill in for this trace
            for i, v in enumerate(values):
                if i < len(stages):
                    all_data[counter_name][trace_idx][i] = v

    if not all_data:
        print("No valid counter statistics found to compare.")
        return

    render_ascii(trace_names, stages, all_data)

if __name__ == "__main__":
    main()
