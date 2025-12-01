/*
 * Copyright 2025 Google LLC
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
/* This version only uses the kgsl ftrace events to get GPU usage data */
INCLUDE PERFETTO MODULE slices.with_context;

CREATE TABLE IF NOT EXISTS _kgsl_ftrace_event
AS
SELECT id, ts, name, utid, arg_set_id
FROM ftrace_event
WHERE
  name IN (
    'adreno_cmdbatch_queued', 'adreno_cmdbatch_sync', 'adreno_cmdbatch_retired',
    'kgsl_adreno_cmdbatch_queued', 'kgsl_adreno_cmdbatch_sync', 'kgsl_adreno_cmdbatch_retired');

CREATE TABLE IF NOT EXISTS kgsl_gpu
AS
WITH
  _with_args AS (
    SELECT
      event.*,
      MIN(CASE key WHEN 'active' THEN int_value END) AS active,
      MIN(CASE key WHEN 'prio' THEN int_value END) AS prio,
      MIN(CASE key WHEN 'retire' THEN int_value END) AS retire,
      MIN(CASE key WHEN 'start' THEN int_value END) AS start,
      MIN(CASE key WHEN 'submitted_to_rb' THEN int_value END) AS submitted_to_rb,
      MIN(CASE key WHEN 'ticks' THEN int_value END) AS ticks,
      MIN(CASE key WHEN 'timestamp' THEN int_value END) AS gpu_queue_id,
      MIN(CASE key WHEN 'retired_on_gmu' THEN int_value END) AS retired_on_gmu
    FROM _kgsl_ftrace_event event
    JOIN args
      ON args.arg_set_id = event.arg_set_id
    WHERE
      args.key IN (
        'active', 'prio', 'retire', 'start', 'submitted_to_rb', 'ticks', 'timestamp',
        'retired_on_gmu')
    GROUP BY event.arg_set_id
    ORDER BY event.ts
  ),
  _with_queue_id AS (
    SELECT
      *,
      MAX(
        CASE
          WHEN name = 'adreno_cmdbatch_queued' OR name = 'kgsl_adreno_cmdbatch_queued' THEN id
          END)
        OVER (PARTITION BY gpu_queue_id ORDER BY ts RANGE 1e9 PRECEDING) AS queue_id
    FROM _with_args
    ORDER BY ts
  ),
  _merged AS (
    SELECT
      queue_id,
      COUNT(*),
      prio AS priority,
      MIN(
        CASE
          WHEN name = 'adreno_cmdbatch_queued' OR name = 'kgsl_adreno_cmdbatch_queued' THEN utid
          END) AS utid,
      MIN(
        CASE
          WHEN name = 'adreno_cmdbatch_queued' OR name = 'kgsl_adreno_cmdbatch_queued' THEN ts
          END) AS queued_ts,
      MIN(CASE WHEN name = 'adreno_cmdbatch_sync' OR name = 'kgsl_adreno_cmdbatch_sync' THEN ts END)
        AS sync_ts,
      MIN(
        CASE
          WHEN name = 'adreno_cmdbatch_sync' OR name = 'kgsl_adreno_cmdbatch_sync' THEN ticks
          END) AS sync_ticks,
      MIN(
        CASE
          WHEN name = 'adreno_cmdbatch_retired' OR name = 'kgsl_adreno_cmdbatch_retired' THEN active
          END) AS active,
      MIN(
        CASE
          WHEN name = 'adreno_cmdbatch_retired' OR name = 'kgsl_adreno_cmdbatch_retired' THEN retire
          END) AS retire,
      MIN(
        CASE
          WHEN name = 'adreno_cmdbatch_retired' OR name = 'kgsl_adreno_cmdbatch_retired' THEN start
          END) AS start,
      MIN(
        CASE
          WHEN name = 'adreno_cmdbatch_retired' OR name = 'kgsl_adreno_cmdbatch_retired'
            THEN submitted_to_rb
          END) AS submitted_to_rb,
      MIN(
        CASE
          WHEN name = 'adreno_cmdbatch_retired' OR name = 'kgsl_adreno_cmdbatch_retired'
            THEN retired_on_gmu
          END) AS retired_on_gmu
    FROM _with_queue_id
    GROUP BY queue_id
    HAVING COUNT(*) = 3
  )
SELECT
  kgsl.queue_id AS queue_id,
  kgsl.priority AS priority,
  process.name AS process,
  thread.name AS thread,
  process.upid AS upid,
  process.pid AS pid,
  thread.tid AS tid,
  /* GPU clock ticks at 19.2 Mhz, so converting to nanos:
       (t / 19.2) * 1000 => t * 52.083333 */
  CAST(kgsl.active * 52.083333 AS int) AS active_dur,
  /* total_dur includes time while preempted */
  CAST((kgsl.retire - kgsl.start) * 52.083333 AS int) AS total_dur,
  kgsl.queued_ts AS queued_ts,
  kgsl.sync_ts AS sync_ts,
  CAST(kgsl.sync_ts + (kgsl.submitted_to_rb - kgsl.sync_ticks) * 52.083333 AS int) AS submit_ts,
  CAST(kgsl.sync_ts + (kgsl.start - kgsl.sync_ticks) * 52.083333 AS int) AS start_ts,
  CAST(kgsl.sync_ts + (kgsl.retire - kgsl.sync_ticks) * 52.083333 AS int) AS end_ts,
  CAST(kgsl.sync_ts + (kgsl.retired_on_gmu - kgsl.sync_ticks) * 52.083333 AS int) AS exit_gpu_ts
FROM _merged kgsl
LEFT JOIN thread
  ON kgsl.utid = thread.utid
LEFT JOIN process
  ON thread.upid = process.upid
ORDER BY start_ts;

CREATE TABLE IF NOT EXISTS _xrc_cpu_gpu_slices
AS
SELECT id, name, ts, dur, arg_set_id
FROM slice
WHERE
  track_id IN (
    SELECT id
    FROM track
    WHERE name = 'Compositor Timeline (Recorded)'
  )
  AND dur BETWEEN 0 AND 1e9;

CREATE TABLE IF NOT EXISTS _xrc_strip_slices
AS
SELECT
  slices.name,
  ts,
  dur,
  MIN(CASE key WHEN 'debug.frameId' THEN int_value END) AS frame_id,
  MIN(CASE key WHEN 'debug.strip' THEN int_value END) AS strip_index,
  MIN(CASE key WHEN 'debug.Real duration' THEN int_value END) AS vk_timestamp_dur
FROM _xrc_cpu_gpu_slices slices
JOIN args
  ON args.arg_set_id = slices.arg_set_id
WHERE
  args.key IN ('debug.frameId', 'debug.strip', 'debug.Real duration')
  AND dur BETWEEN 0 AND 1e9
GROUP BY slices.id
ORDER BY slices.ts;

CREATE TABLE IF NOT EXISTS _xrc_strips
AS
SELECT
  frame_id * 2 + strip_index AS id,
  frame_id,
  strip_index,
  'Strip ' || strip_index AS name,
  MIN(CASE name WHEN 'CPU' THEN ts END) AS ts,
  MIN(CASE name WHEN 'CPU' THEN dur END) AS cpu_dur,
  MIN(vk_timestamp_dur) AS vk_query_dur,
  MIN(CASE name WHEN 'Deadline' THEN ts END) AS deadline,
  MIN(CASE name WHEN 'Missed' THEN TRUE ELSE FALSE END) AS fence_missed
FROM _xrc_strip_slices
GROUP BY frame_id, strip_index
HAVING
  cpu_dur > 0
  AND vk_query_dur > 0
ORDER BY ts;

CREATE TABLE IF NOT EXISTS _xrc_gpu_to_cpu
AS
WITH
  timeline AS (
    SELECT *
    FROM
      (
        SELECT id, 'cpu' AS type, ts, ts + cpu_dur AS end_ts
        FROM _xrc_strips
      ) UNION
    SELECT *
    FROM
      (
        SELECT queue_id AS id, 'gpu' AS type, queued_ts AS ts, queued_ts AS end_ts
        FROM kgsl_gpu
        WHERE thread = 'compositor'
      )
    ORDER BY ts
  ),
  strip_work AS (
    SELECT
      type,
      id,
      CASE type
        WHEN 'gpu'
          THEN
            CASE
              WHEN
                MAX(CASE type WHEN 'cpu' THEN id END) OVER (ORDER BY ts)
                = MIN(CASE type WHEN 'cpu' THEN id END) OVER (ORDER BY end_ts DESC)
                THEN MAX(CASE type WHEN 'cpu' THEN id END) OVER (ORDER BY ts)
              END
        END AS strip_id
    FROM timeline
    ORDER BY ts
  )
SELECT id AS gpu_id, (MAX(strip_id) OVER (ORDER BY id)) / 2 AS frame_id, strip_id
FROM strip_work
WHERE type = 'gpu'
ORDER BY id;

CREATE TABLE IF NOT EXISTS _xr_miss_type
AS
SELECT column1 AS none, column2 AS tear, column3 AS fence, column4 AS dropped
FROM
  (VALUES(0, 1, 2, 3));

CREATE TABLE IF NOT EXISTS xr_compositor_strips
AS
SELECT
  strips.id,
  strips.frame_id,
  strips.strip_index,
  strips.name,
  strips.deadline,
  strips.ts,
  gpu.end_ts - strips.ts AS dur,
  strips.cpu_dur,
  gpu.start_ts AS gpu_start,
  gpu.total_dur AS gpu_dur,
  gpu.end_ts AS end_ts,
  CASE
    WHEN gpu.end_ts > strips.deadline THEN 1
    ELSE 0
    END AS tear
FROM _xrc_gpu_to_cpu fkm
JOIN _xr_miss_type miss
JOIN kgsl_gpu gpu
  ON fkm.gpu_id = gpu.queue_id
JOIN _xrc_strips strips
  ON fkm.strip_id = strips.id
WHERE fkm.strip_id IS NOT NULL
GROUP BY fkm.strip_id
HAVING ABS(strips.vk_query_dur - gpu.total_dur) = MIN(ABS(strips.vk_query_dur - gpu.total_dur));

CREATE TABLE IF NOT EXISTS xr_compositor_frames
AS
WITH
  from_strips AS (
    SELECT
      strips.frame_id,
      MIN(strips.ts) AS ts,
      SUM(strips.tear) > 0 AS was_torn
    FROM xr_compositor_strips strips
    JOIN _xr_miss_type miss
    GROUP BY frame_id
    HAVING COUNT(DISTINCT strip_index) = 2
  )
SELECT
  gpu.upid AS upid,
  from_strips.*,
  SUM(gpu.active_dur) AS frame_gpu_dur
FROM from_strips
JOIN _xrc_gpu_to_cpu fkm
  USING (frame_id)
JOIN kgsl_gpu gpu
  ON fkm.gpu_id = gpu.queue_id
GROUP BY frame_id;

CREATE TABLE IF NOT EXISTS xr_compositor_frame_metrics
AS
WITH
  frames AS (
    SELECT
      upid,
      frame_id,
      was_torn
    FROM xr_compositor_frames
  )
SELECT
  upid,
  COUNT() FILTER(WHERE NOT was_torn) AS good_frames,
  COUNT() FILTER(WHERE was_torn) AS torn_frames
FROM frames;

WITH wattage_table AS (
    SELECT
        ts,
        -MIN(value)/ 1000000 * MAX(value) / 1000000 as wattage
    FROM counter AS c LEFT JOIN counter_track t ON c.track_id = t.id
    WHERE name = 'batt.current_ua'
    OR name = 'batt.voltage_uv'
    AND value != 0
    GROUP BY ts
),
global_power_stats AS (
    SELECT
        AVG(wattage) as avg_power,
        COUNT(*) as num_samples
    FROM
        wattage_table
),
gpu_frequency AS (
    /* -- Optionally inject starting GPU frequency sample here -- */
    /* Format:
     *   SELECT (SELECT MIN(ts) FROM ftrace_event) AS ts, <GPU_FREQ> AS freq_khz UNION ALL
     * Without the starting GPU frequency, short traces (< 10 seconds) may have partial or
     * no GPU frequency data, because these events only occur when the frequency changes. */
    SELECT ts, EXTRACT_ARG(arg_set_id, 'gpu_freq') AS freq_khz
    FROM ftrace_event
    WHERE name = 'gpu_frequency'
),
gpu_frequency_dur AS (
    SELECT
        ts,
        LEAD(ts, 1, (SELECT MAX(ts) FROM ftrace_event))
            OVER (ORDER BY ts) - ts AS dur,
        freq_khz
    FROM gpu_frequency
),
global_gpu_stats AS (
    SELECT
        CAST(SUM(freq_khz * dur) * 1.0 / SUM(dur) AS INTEGER) AS avg_gpu_freq,
        SUM(gpu_frequency_dur.dur) / 1e9 AS total_dur
    FROM gpu_frequency_dur
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
gpu_dims AS (
    SELECT
        upid,
        MAX(CAST(EXTRACT_ARG(arg_set_id, 'width') AS int)) width,
        MAX(CAST(EXTRACT_ARG(arg_set_id, 'height') AS int)) height
    FROM gpu_slice
    WHERE name = 'Surface'
    GROUP BY upid
),
gpu_events_kgsl AS (
    SELECT
        upid, start_ts AS ts, active_dur AS dur, process AS name
    FROM kgsl_gpu
),
gpu_events_gpu1 AS (
    SELECT upid, ts, dur, name
    FROM gpu_events_kgsl
    UNION ALL
    /* --gpu1 events */
    SELECT gs.upid, gs.ts, gs.dur, gs.name
    FROM gpu_slice gs
    LEFT JOIN gpu_events_kgsl existing_frames ON gs.upid = existing_frames.upid
    WHERE
        existing_frames.upid IS NULL
        /* Workload is render, Dispatch is compute */
        /* Both are separate from Preempt so we do not subtract Preempt events */
        AND gs.name IN ('Workload', 'Dispatch')
),
gpu_events_compositor_upper_bound AS (
    SELECT process_track.upid, ts, dur
    FROM slice
    JOIN process_track ON slice.track_id = process_track.id
    JOIN track ON slice.track_id = track.id
    WHERE (
        track.name = 'Compositor Timeline (Recorded)'
        AND slice.name = 'GPU' AND category = 'cpm'
    )
),
gpu_events_compositor_preempt AS (
    SELECT ts, dur
    FROM gpu_slice
    WHERE name = 'Preempt'
),
gpu_events_compositor_fallback AS (
    SELECT
        ub.upid,
        /* If a valid preempt exists, use its ts, otherwise keep the upper bound ts */
        COALESCE(p.ts, ub.ts) AS ts,
        /* If a valid preempt exists, use its dur, otherwise keep the upper bound dur */
        COALESCE(p.dur, ub.dur) AS dur
    FROM gpu_events_compositor_upper_bound ub
    LEFT JOIN gpu_events_compositor_preempt p
        ON p.ts > ub.ts
        AND p.ts < (ub.ts + ub.dur)
),
gpu_events AS (
    SELECT upid, ts, dur
    FROM gpu_events_gpu1
    UNION ALL
    /* compositor fallback GPU events when kgsl not available */
    SELECT fb.upid, fb.ts, fb.dur
    FROM gpu_events_compositor_fallback fb
    LEFT JOIN gpu_events_gpu1 existing_frames ON fb.upid = existing_frames.upid
    WHERE existing_frames.upid IS NULL
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
frame_drops AS (
    SELECT
        upid,
        process.name AS name,
        SUM(CASE WHEN frames.name = 'Reprojected' THEN 1 ELSE 0 END) AS drops
        /*COUNT(frames.name) AS total*/
    FROM (
        SELECT
            EXTRACT_ARG(arg_set_id, 'debug.sourcePid') AS pid,
            name
        FROM slice
        WHERE (
            name IN ('Display', 'LATE Display', 'Reprojected') AND
            pid IS NOT NULL
        )
    ) frames
    JOIN process USING (pid)
    GROUP BY upid
    UNION ALL
    SELECT
        upid,
        process.name AS name,
        xr_compositor_frame_metrics.torn_frames AS drops
    FROM xr_compositor_frame_metrics
    JOIN process USING (upid)
    GROUP BY upid
),
frame_counts AS (
    SELECT
        upid,
        COUNT(cpu_frames.ts) AS count
    FROM ts_extents
    JOIN cpu_frames USING (upid)
    WHERE cpu_frames.ts BETWEEN start_ts AND end_ts
    GROUP BY upid
),
gpu_pids AS (
    SELECT upid, name
    FROM frame_counts
    JOIN process USING (upid)
    UNION
    SELECT upid, name
    FROM frame_drops
),
gpu_results AS (
    SELECT
        upid,
        gpu_dims.width AS width,
        gpu_dims.height AS height,
        /* These gpu event dur values do not include preemption times (see active_dur above). */
        SUM(gpu_events.dur) AS gpu_ms
    FROM gpu_events
    LEFT JOIN gpu_dims USING (upid)
    JOIN ts_extents USING (upid)
    WHERE gpu_events.ts BETWEEN start_ts AND end_ts
    GROUP BY upid
),
process_thread_running_metrics AS (
    SELECT
        upid,
        tid,
        proc.process AS process,
        proc.thread AS thread,
        proc.priority AS priority,
        proc.dur_ms AS duration_ms
    FROM
    (
        SELECT
            upid,
            utid,
            p.name process,
            t.name thread,
            t.tid tid,
            min(priority) priority,
            sum(dur / 1e6) dur_ms
        FROM sched
        LEFT JOIN thread t USING (utid)
        LEFT JOIN process p USING (upid)
        WHERE (process IS NOT NULL OR thread != 'swapper')
        GROUP BY 1, 2
    ) proc
),
ranked_threads AS (
    SELECT
        upid,
        process,
        tid,
        thread,
        priority,
        duration_ms,
        ROW_NUMBER() OVER (PARTITION BY upid ORDER BY duration_ms DESC, tid ASC) as duration_rank
    FROM
        process_thread_running_metrics
),
top_cpu_users AS (
    SELECT
        rt.upid,
        MAX(CASE WHEN rt.duration_rank = 1 THEN rt.priority || ':' || rt.thread ELSE NULL END)
            AS top_thread1,
        SUM(CASE WHEN rt.duration_rank = 1 THEN rt.duration_ms ELSE 0 END) AS thread1_cpu_dur_ms,
        MAX(CASE WHEN rt.duration_rank = 2 THEN rt.priority || ':' || rt.thread ELSE NULL END)
            AS top_thread2,
        SUM(CASE WHEN rt.duration_rank = 2 THEN rt.duration_ms ELSE 0 END) AS thread2_cpu_dur_ms,
        SUM(rt.duration_ms) AS all_cpu_dur_ms
    FROM ranked_threads rt
    GROUP BY rt.upid
    ORDER BY all_cpu_dur_ms DESC
),
openxr_layer_dims AS (
    SELECT
        EXTRACT_ARG(arg_set_id, 'debug.clientId') AS clientId,
        EXTRACT_ARG(arg_set_id, 'debug.width') AS width,
        EXTRACT_ARG(arg_set_id, 'debug.height') AS height
    FROM slice
    WHERE name = 'RenderXRLayer' AND category = 'cpm'
),
openxr_clients AS (
    SELECT
        EXTRACT_ARG(arg_set_id, 'debug.clientId') AS clientId,
        EXTRACT_ARG(arg_set_id, 'debug.clientPid') AS clientPid
    FROM slice
        WHERE name = 'XRSession::queueTransaction' AND category = 'cpm'
),
openxr_clients_upid AS (
    SELECT
      process.upid as upid,
      openxr_clients.clientId as clientId
    FROM openxr_clients
    JOIN process
    ON process.pid = openxr_clients.clientPid
    GROUP BY openxr_clients.clientId
),
openxr_dims AS (
    SELECT
        openxr_clients_upid.upid as upid,
        MAX(openxr_layer_dims.width) as width,
        MAX(openxr_layer_dims.height) height
    FROM openxr_layer_dims
    JOIN openxr_clients_upid USING(clientId)
    GROUP BY openxr_layer_dims.clientId
),
combined_dims AS (
    SELECT
        IFNULL(gpu_dims.upid, openxr_dims.upid) AS upid,
        IFNULL(gpu_dims.width, openxr_dims.width) AS width,
        IFNULL(gpu_dims.height, openxr_dims.height) AS height
    FROM
        gpu_dims
    FULL OUTER JOIN openxr_dims USING(upid)
)
SELECT
    CASE
        WHEN (LENGTH(gpu_pids.name) > 40) THEN SUBSTR(gpu_pids.name, 0, 40) || '+'
        ELSE gpu_pids.name
        END AS ProcessName,
    combined_dims.width AS W,
    combined_dims.height AS H,
    printf('%g', ROUND(gpu_results.gpu_ms / 1000000.0 / frame_counts.count, 3))
        AS GpuMSPF,
    printf('%g', ROUND(frame_counts.count / ((end_ts - start_ts) / 1000000000.0), 3)) AS FPS,
    frame_counts.count AS Frames,
    frame_drops.drops AS Drops,
    printf('%g', ROUND(60.0 * frame_drops.drops / ((end_ts - start_ts) / 1000000000.0), 2)) AS DropsPM,
    printf('%g', ROUND(top_cpu_users.all_cpu_dur_ms / frame_counts.count, 3)) AS CpuMSPF,
    top_thread1 AS TopThread1,
    printf('%g', ROUND(top_cpu_users.thread1_cpu_dur_ms / frame_counts.count, 3)) AS MSPF1,
    top_thread2 AS TopThread2,
    printf('%g', ROUND(top_cpu_users.thread2_cpu_dur_ms / frame_counts.count, 3)) AS MSPF2,
    printf('%g', ROUND((end_ts - start_ts) / 1000000000.0, 1)) AS Dur,
    /* template stat insert */
    /* ie: ( SELECT AVG(dur) / 1000000.0 FROM thread_slice WHERE name = 'MyEvent' AND upid = gpu_pids.upid ) AS MyStatAvg, */
    global_gpu_stats.avg_gpu_freq AS GpuFreq,
    CASE
        WHEN global_power_stats.num_samples < 1 THEN NULL
        ELSE printf('%g', ROUND(global_power_stats.avg_power, 3))
        END AS Watts
FROM gpu_pids
JOIN ts_extents USING (upid)
JOIN frame_counts USING (upid)
LEFT JOIN frame_drops USING (upid)
LEFT JOIN gpu_results USING (upid)
LEFT JOIN combined_dims USING (upid)
CROSS JOIN global_power_stats
CROSS JOIN global_gpu_stats
LEFT JOIN top_cpu_users USING (upid)
GROUP BY upid
ORDER BY GpuMSPF DESC;
