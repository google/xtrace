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
DROP TABLE IF EXISTS kgsl_gpu;
CREATE TABLE IF NOT EXISTS kgsl_gpu
AS
WITH
  raw_events AS (SELECT * FROM ftrace_event WHERE name LIKE '%adreno_%'),
  with_args AS (
    SELECT
      raw_events.*,
      args.arg_set_id,
      min(CASE key WHEN 'active' THEN CAST(display_value AS int) END) AS active,
      min(CASE key WHEN 'prio' THEN CAST(display_value AS int) END) AS prio,
      min(CASE key WHEN 'retire' THEN CAST(display_value AS int) END) AS retire,
      min(CASE key WHEN 'retired_on_gmu' THEN CAST(display_value AS int) END) AS retired_on_gmu,
      min(CASE key WHEN 'start' THEN CAST(display_value AS int) END) AS start,
      min(CASE key WHEN 'submitted_to_rb' THEN CAST(display_value AS int) END) AS submitted_to_rb,
      min(CASE key WHEN 'ticks' THEN CAST(display_value AS int) END) AS ticks,
      min(CASE key WHEN 'timestamp' THEN CAST(display_value AS int) END) AS gpu_queue_id
    FROM raw_events
    JOIN args
      ON args.arg_set_id = raw_events.arg_set_id
    GROUP BY raw_events.arg_set_id
    ORDER BY raw_events.ts
  ),
  with_queue_id AS (
    SELECT
      *,
      max(CASE WHEN (name IS 'adreno_cmdbatch_queued' OR name IS 'kgsl_adreno_cmdbatch_queued') THEN id ELSE NULL END)
        OVER (PARTITION BY gpu_queue_id ORDER BY ts RANGE BETWEEN 1e9 PRECEDING AND CURRENT ROW)
        AS queue_id
    FROM with_args
    ORDER BY ts
  ),
  with_queue_info AS (
    SELECT
      queue_id,
      process.name AS process,
      thread.name AS thread,
      process.upid,
      process.pid,
      thread.utid,
      thread.tid
    FROM with_queue_id
    LEFT JOIN thread
      ON with_queue_id.utid = thread.utid AND (with_queue_id.name IS 'adreno_cmdbatch_queued' OR with_queue_id.name IS 'kgsl_adreno_cmdbatch_queued')
    LEFT JOIN process
      ON thread.upid = process.upid
    WHERE (with_queue_id.name IS 'adreno_cmdbatch_queued' OR with_queue_id.name IS 'kgsl_adreno_cmdbatch_queued') AND queue_id IS NOT NULL
    ORDER BY queue_id
  ),
  with_process_info AS (
    SELECT with_queue_id.*, upid, process, thread, pid, tid
    FROM with_queue_id
    LEFT JOIN with_queue_info
      ON with_queue_id.queue_id = with_queue_info.queue_id
    WHERE with_queue_id.queue_id IS NOT NULL
    ORDER BY with_queue_id.ts
  )
SELECT
  sync.queue_id,
  sync.process AS process,
  sync.thread AS thread,
  sync.pid AS pid,
  sync.upid AS upid,
  sync.tid AS tid,
  /* GPU clock ticks at 19.2 Mhz, so converting to nanos:
   *     (t / 19.2) * 1000 => t * 52.0833 */
  CAST(retired.active * 52.0833 AS int) AS active_dur,
  CAST((retired.retire - retired.start) * 52.0833 AS int)
    AS total_dur,  /* includes time while preempted */
  sync.ts as sync_ts,
  CAST(sync.ts + (retired.submitted_to_rb - sync.ticks) * 52.0833 AS int) AS submit_ts,
  CAST(sync.ts + (retired.start - sync.ticks) * 52.0833 AS int) AS start_ts,
  CAST(sync.ts + (retired.retire - sync.ticks) * 52.0833 AS int) AS end_ts,
  CAST(sync.ts + (retired.retired_on_gmu - sync.ticks) * 52.0833 AS int) AS exit_gpu_ts
FROM with_process_info sync
JOIN with_process_info retired
  ON
    sync.queue_id = retired.queue_id
    AND (sync.name IS 'adreno_cmdbatch_sync' OR sync.name IS 'kgsl_adreno_cmdbatch_sync')
    AND (retired.name IS 'adreno_cmdbatch_retired' OR retired.name IS 'kgsl_adreno_cmdbatch_retired')
ORDER BY start_ts;

WITH process_thread_running_metrics
AS (
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
      CASE
          WHEN (p.name IS NOT NULL OR t.name != 'swapper') THEN p.name
          ELSE '-- idle cpu --'
          END AS process,
      t.name thread,
      t.tid tid,
      min(priority) priority,
      sum(dur / 1e6) dur_ms
    FROM
      sched
    LEFT JOIN
      thread t
      USING (utid)
    LEFT JOIN
      process p
      USING (upid)
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
gpu_dur AS (
    SELECT
        upid, SUM(active_dur / 1e6) AS gpu_dur_ms
    FROM kgsl_gpu
    GROUP BY upid
),
top_cpu_users AS (
    SELECT
        rt.upid AS upid,
        rt.process AS name,
        SUM(rt.duration_ms) AS all_cpu_dur_ms,
        MAX(CASE WHEN rt.duration_rank = 1 THEN rt.priority || ':' || rt.thread ELSE NULL END) AS top_thread1,
        SUM(CASE WHEN rt.duration_rank = 1 THEN rt.duration_ms ELSE 0 END) AS thread1_cpu_dur_ms,
        MAX(CASE WHEN rt.duration_rank = 2 THEN rt.priority || ':' || rt.thread ELSE NULL END) AS top_thread2,
        SUM(CASE WHEN rt.duration_rank = 2 THEN rt.duration_ms ELSE 0 END) AS thread2_cpu_dur_ms
    FROM ranked_threads rt
    GROUP BY rt.upid
    ORDER BY all_cpu_dur_ms DESC
),
trace_extents AS (
    SELECT
        (MAX(ts) - MIN(ts)) / 1000000 AS trace_ms
    FROM ftrace_event
),
final_results AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY all_cpu_dur_ms DESC) AS Rank,
        CASE
            WHEN (LENGTH(name) > 60) THEN SUBSTR(name, 0, 60) || '+'
            ELSE name
            END AS ProcessName,
        printf('%g', ROUND(100.0 * gpu_dur.gpu_dur_ms / trace_ms, 3)) AS GpuPct,
        printf('%g', ROUND(100.0 * all_cpu_dur_ms / trace_ms, 3)) AS CpuPct,
        top_thread1 AS TopThread1,
        printf('%g', ROUND(100.0 * thread1_cpu_dur_ms / trace_ms, 3)) AS CpuPct1,
        top_thread2 AS TopThread2,
        printf('%g', ROUND(100.0 * thread2_cpu_dur_ms / trace_ms, 3)) AS CpuPct2
    FROM top_cpu_users
    LEFT JOIN gpu_dur USING (upid)
    CROSS JOIN trace_extents
    LIMIT 20
)
SELECT Rank, ProcessName, GpuPct, CpuPct, TopThread1, CpuPct1, TopThread2, CpuPct2
FROM (
    SELECT 1 AS sort_key, Rank, ProcessName, GpuPct, CpuPct, TopThread1, CpuPct1, TopThread2, CpuPct2 FROM final_results
    UNION ALL
    SELECT
        2 AS sort_key,
        NULL AS Rank,
        '-- non-idle totals --' AS ProcessName,
        printf('%g', ROUND(100.0 * COALESCE((SELECT SUM(active_dur) / 1e6 FROM kgsl_gpu), 0) / MAX(1, trace_ms), 3)) AS GpuPct,
        printf('%g', ROUND(100.0 * COALESCE((SELECT SUM(dur) / 1e6 FROM sched LEFT JOIN thread t USING (utid) LEFT JOIN process p USING (upid) WHERE (p.name IS NOT NULL OR t.name != 'swapper')), 0) / MAX(1, trace_ms), 3)) AS CpuPct,
        NULL AS TopThread1,
        NULL AS CpuPct1,
        NULL AS TopThread2,
        NULL AS CpuPct2
    FROM trace_extents
)
ORDER BY sort_key, Rank;
