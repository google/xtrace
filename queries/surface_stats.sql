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

CREATE TABLE IF NOT EXISTS gpu_pids AS
SELECT DISTINCT upid FROM gpu_slice;

WITH gpu_events AS (
    /* --gpu1 --gpu2 Surface events */
    SELECT gs.upid, gs.ts, gs.dur
    FROM gpu_slice gs
    WHERE
        /* TODO: subtract Preempt events */
        gs.name IN ('Surface')
),
app_frames AS (
    SELECT
        EXTRACT_ARG(arg_set_id, 'debug.sourcePid') AS pid,
        ts
    FROM slice
    WHERE (name = 'GPU' AND category = 'cpm' AND pid IS NOT NULL)
),
app_frames2 AS (
    SELECT
        EXTRACT_ARG(arg_set_id, 'debug.sourcePid') AS pid,
        ts
    FROM slice
    /* Newer traces have one ready event per app frame */
    WHERE (name = 'ready' AND category = 'cpm' AND pid IS NOT NULL)
),
cpu_frames_pre1 AS (
    /* CPM compositor frames */
    SELECT upid, ts
    FROM thread_slice
    WHERE name = 'frame' AND category = 'cpm'
    UNION ALL
    /* XR app frames */
    SELECT upid, ts
    FROM app_frames2
    JOIN process USING (pid)
),
cpu_frames_pre2 AS (
    SELECT upid, ts
    FROM cpu_frames_pre1
    UNION ALL
    /* Backwards compat XR app frames */
    SELECT process.upid, app_frames.ts
    FROM app_frames
    JOIN process USING (pid)
    LEFT JOIN cpu_frames_pre1 existing_frames ON process.upid = existing_frames.upid
    WHERE existing_frames.upid IS NULL
),
cpu_frames_pre3 AS (
    SELECT upid, ts
    FROM cpu_frames_pre2
    UNION ALL
    /* 2D app frames */
    SELECT thread_slice.upid, thread_slice.ts
    FROM thread_slice
    LEFT JOIN cpu_frames_pre2 existing_frames ON thread_slice.upid = existing_frames.upid
    WHERE
        existing_frames.upid IS NULL
        /* Alternate app frame events.
           This only works if a single process uses only one of these. */
        AND thread_slice.name IN (
            'oxr_xrEndFrame', /* OpenXR event from ATRACE gfx category */
            'SkiaRenderer::SwapBuffers', /* Chrome compositor frame */
            'Choreographer#scheduleVsyncLocked') /* Android app frame */
),
cpu_frames AS (
    SELECT upid, ts
    FROM cpu_frames_pre3
    UNION ALL
    /* Any other GPU usage by a process that does not have a known CPU frame
       gets 1 CPU frame per GPU slice. */
    SELECT ge.upid, ge.ts
    FROM gpu_events ge
    LEFT JOIN cpu_frames_pre3 existing_frames ON ge.upid = existing_frames.upid
    WHERE existing_frames.upid IS NULL
),
combined_extents AS (
    SELECT
        upid,
        MIN(ts) AS min_ts,
        MAX(ts) AS max_ts
    FROM cpu_frames
    GROUP BY upid
    UNION ALL
    SELECT
        upid,
        MIN(ts) AS min_ts,
        MAX(ts) AS max_ts
    FROM gpu_events
    GROUP BY upid
    /* Don't clip by GPU events if there are only a few: */
    HAVING COUNT(ts) > 8
),
ts_extents AS (
    SELECT
        upid,
        MAX(min_ts) + 1000000 AS start_ts,
        MIN(max_ts) - 1000000 AS end_ts
    FROM combined_extents
    GROUP BY upid
),
frame_counts AS (
    SELECT
        upid,
        MAX(1, COUNT(cpu_frames.ts)) AS count
    FROM ts_extents
    JOIN cpu_frames USING (upid)
    WHERE cpu_frames.ts BETWEEN start_ts AND end_ts
    GROUP BY upid
),

surface_slices AS (
    SELECT
        upid,
        ts,
        dur,
        EXTRACT_ARG(arg_set_id, 'width') AS width,
        EXTRACT_ARG(arg_set_id, 'height') AS height,
        EXTRACT_ARG(arg_set_id, 'numBins') AS numBins,
        EXTRACT_ARG(arg_set_id, 'binWidth') AS binWidth,
        EXTRACT_ARG(arg_set_id, 'binHeight') AS binHeight,
        EXTRACT_ARG(arg_set_id, 'MSAA') AS msaa,
        EXTRACT_ARG(arg_set_id, 'numRenderTargets') AS render_targets,
        (
            SELECT SUM(CAST(COALESCE(int_value, string_value) AS INT))
            FROM args
            WHERE arg_set_id = gpu_slice.arg_set_id
              AND key GLOB 'Render Target * BPP'
        ) AS render_target_bpp,
        (row_number() OVER (PARTITION BY upid ORDER BY ts) - 1) %
            MAX(1, (SELECT COUNT(*) FROM gpu_slice g2 WHERE g2.upid = gpu_slice.upid AND name = 'Surface') /
                   MAX(1, (SELECT count FROM frame_counts WHERE frame_counts.upid = gpu_slice.upid))) + 1 AS surface_index
    FROM gpu_slice
    WHERE name = 'Surface'
      AND upid IN (SELECT upid FROM gpu_pids)
),
gpu_stages AS (
    SELECT
      upid, ts, dur,
      name AS stage_type
    FROM gpu_slice
    WHERE upid IN (SELECT upid FROM gpu_pids)
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
    surface_slices.surface_index || '/' || (MAX(surface_slices.surface_index) OVER (PARTITION BY surface_slices.upid)) AS SurfaceID,
    CAST(AVG(surface_slices.width) AS INT) AS W,
    CAST(AVG(surface_slices.height) AS INT) AS H,
    CAST(AVG(surface_slices.msaa) AS INT) AS MSAA,
    CAST(AVG(surface_slices.render_targets) AS INT) AS RTs,
    CAST(AVG(surface_slices.render_target_bpp) AS INT) AS RTBPP,
    printf('%.3f', (SUM(surface_slices.dur) - COALESCE(SUM(filtered_stages.preempt_dur), 0)) / 1000000.0 / MAX(1, COUNT(*))) AS GpuMSPF,
    printf('%.3f', COALESCE(SUM(filtered_stages.bin_dur), 0) / 1000000.0 / MAX(1, COUNT(*))) AS BinMSPF,
    printf('%.3f', COALESCE(SUM(filtered_stages.render_dur), 0) / 1000000.0 / MAX(1, COUNT(*))) AS RenderMSPF,
    printf('%.3f', COALESCE(MAX(filtered_stages.max_render_dur), 0) / 1000000.0) AS RenderMaxMS,
    COUNT(*) AS Frames,
    CAST(AVG(surface_slices.numBins) AS INT) AS Bins,
    CAST(AVG(surface_slices.binWidth) AS INT) AS BinW,
    CAST(AVG(surface_slices.binHeight) AS INT) AS BinH
FROM surface_slices
LEFT JOIN filtered_stages ON surface_slices.upid = filtered_stages.upid AND surface_slices.ts = filtered_stages.surface_ts
JOIN process ON process.upid = surface_slices.upid
GROUP BY surface_slices.upid, surface_slices.surface_index
ORDER BY SUM(surface_slices.dur) DESC;
