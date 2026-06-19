/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

INCLUDE PERFETTO MODULE slices.with_context;

CREATE TABLE IF NOT EXISTS target_procs AS
SELECT DISTINCT upid FROM gpu_slice;

WITH surface_slices_raw AS (
    SELECT
        upid,
        ts,
        dur,
        arg_set_id,
        EXTRACT_ARG(arg_set_id, 'width') AS width,
        EXTRACT_ARG(arg_set_id, 'height') AS height,
        EXTRACT_ARG(arg_set_id, 'numBins') AS numBins,
        EXTRACT_ARG(arg_set_id, 'binWidth') AS binWidth,
        EXTRACT_ARG(arg_set_id, 'binHeight') AS binHeight,
        EXTRACT_ARG(arg_set_id, 'MSAA') AS msaa,
        EXTRACT_ARG(arg_set_id, 'numRenderTargets') AS render_targets,
        EXTRACT_ARG(arg_set_id, 'renderMode') AS renderMode,
        (
            SELECT SUM(CAST(COALESCE(int_value, string_value) AS INT))
            FROM args
            WHERE arg_set_id = gpu_slice.arg_set_id
              AND key GLOB 'Render Target * BPP'
        ) AS render_target_bpp,
        CAST(COALESCE(NULLIF(NULLIF(EXTRACT_ARG(arg_set_id, 'render_pass'), '0'), 0),
                      EXTRACT_ARG(arg_set_id, 'surfaceID')) AS TEXT) AS surface_key
    FROM gpu_slice
    WHERE name = 'Surface'
      AND upid IN (SELECT upid FROM target_procs)
),
surface_slices_with_count AS (
    SELECT
        *,
        COUNT(*) OVER (PARTITION BY upid, surface_key) AS key_count
    FROM surface_slices_raw
),
surface_slices AS (
    SELECT
        *,
        CASE
            WHEN key_count = 1 THEN
                FIRST_VALUE(surface_key) OVER (
                    PARTITION BY upid, key_count, width, height, msaa, render_target_bpp, binWidth, binHeight, numBins
                    ORDER BY ts
                )
            ELSE surface_key
        END AS consolidated_key
    FROM surface_slices_with_count
),
gpu_stages AS (
    SELECT
      upid, ts, dur,
      name AS stage_type
    FROM gpu_slice
    WHERE upid IN (SELECT upid FROM target_procs)
      AND name IN ('Binning', 'Render', 'Preempt')
),
combined_events AS (
    SELECT upid, ts, 'surface' as type, ts as surface_ts, NULL as stage_type, 0 as dur
    FROM surface_slices
    UNION ALL
    SELECT upid, ts, 'stage' as type, NULL as surface_ts, stage_type, dur
    FROM gpu_stages
),
ordered_events AS (
    SELECT
       upid, ts, type, surface_ts, stage_type, dur,
       SUM(CASE WHEN type = 'surface' THEN 1 ELSE 0 END) OVER (PARTITION BY upid ORDER BY ts) as surface_group_id
    FROM combined_events
),
group_selection AS (
    SELECT
      upid, surface_group_id, MAX(surface_ts) as surface_ts
    FROM ordered_events
    WHERE type = 'surface'
    GROUP BY upid, surface_group_id
),
filtered_stages AS (
    SELECT
      o.upid,
      g.surface_ts,
      SUM(CASE WHEN o.stage_type = 'Binning' THEN o.dur ELSE 0 END) as bin_dur,
      SUM(CASE WHEN o.stage_type = 'Render' THEN o.dur ELSE 0 END) as render_dur,
      SUM(CASE WHEN o.stage_type = 'Preempt' THEN o.dur ELSE 0 END) as preempt_dur,
      MAX(CASE WHEN o.stage_type = 'Render' THEN o.dur ELSE NULL END) as max_render_dur
    FROM ordered_events o
    JOIN group_selection g ON o.surface_group_id = g.surface_group_id AND o.upid = g.upid
    WHERE o.type = 'stage' AND g.surface_group_id > 0
    GROUP BY o.upid, g.surface_ts
)
SELECT
    process.name AS ProcessName,
    surface_slices.consolidated_key AS SurfaceID,
    CAST(AVG(surface_slices.width) AS INT) AS W,
    CAST(AVG(surface_slices.height) AS INT) AS H,
    CAST(AVG(surface_slices.msaa) AS INT) AS MSAA,
    CAST(AVG(surface_slices.render_targets) AS INT) AS RTs,
    CAST(AVG(surface_slices.render_target_bpp) AS INT) AS RTBPP,
    printf('%.3f', (SUM(surface_slices.dur) - COALESCE(SUM(filtered_stages.preempt_dur), 0)) / 1000000.0 / MAX(1, COUNT(*))) AS GpuMSPF,
    printf('%.3f', MAX(surface_slices.dur - COALESCE(filtered_stages.preempt_dur, 0)) / 1000000.0) AS GpuMaxMS,
    printf('%.3f', COALESCE(SUM(filtered_stages.bin_dur), 0) / 1000000.0 / MAX(1, COUNT(*))) AS BinMSPF,
    printf('%.3f', COALESCE(SUM(filtered_stages.render_dur), 0) / 1000000.0 / MAX(1, COUNT(*))) AS RenderMSPF,
    printf('%.3f', COALESCE(MAX(filtered_stages.max_render_dur), 0) / 1000000.0) AS RenderMaxMS,
    COUNT(*) AS Frames,
    CAST(AVG(surface_slices.numBins) AS INT) AS Bins,
    CAST(AVG(surface_slices.binWidth) AS INT) AS BinW,
    CAST(AVG(surface_slices.binHeight) AS INT) AS BinH,
    MAX(surface_slices.renderMode) AS RenderMode
FROM surface_slices
LEFT JOIN filtered_stages ON surface_slices.upid = filtered_stages.upid AND surface_slices.ts = filtered_stages.surface_ts
JOIN process ON process.upid = surface_slices.upid
GROUP BY surface_slices.upid, surface_slices.consolidated_key
ORDER BY SUM(surface_slices.dur) DESC;
