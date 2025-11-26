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
/* Show KGSL events in the Perfetto UI via "Show debug track" */
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
      min(CASE key WHEN 'dispatch_queue' THEN CAST(display_value AS int) END) AS dispatch_queue,
      min(CASE key WHEN 'fault_recovery' THEN CAST(display_value AS int) END) AS fault_recovery,
      min(CASE key WHEN 'flags' THEN CAST(display_value AS int) END) AS flags,
      min(CASE key WHEN 'id' THEN CAST(display_value AS int) END) AS source_id,
      min(CASE key WHEN 'inflight' THEN CAST(display_value AS int) END) AS inflight,
      min(CASE key WHEN 'prio' THEN CAST(display_value AS int) END) AS prio,
      min(CASE key WHEN 'queued' THEN CAST(display_value AS int) END) AS queued,
      min(CASE key WHEN 'q_inflight' THEN CAST(display_value AS int) END) AS q_inflight,
      min(CASE key WHEN 'rb_id' THEN CAST(display_value AS int) END) AS rb_id,
      min(CASE key WHEN 'recovery' THEN CAST(display_value AS int) END) AS recovery,
      min(CASE key WHEN 'requeue_cnt' THEN CAST(display_value AS int) END) AS requeue_cnt,
      min(CASE key WHEN 'retire' THEN CAST(display_value AS int) END) AS retire,
      min(CASE key WHEN 'retired_on_gmu' THEN CAST(display_value AS int) END) AS retired_on_gmu,
      min(CASE key WHEN 'rptr' THEN CAST(display_value AS int) END) AS rptr,
      min(CASE key WHEN 'secs' THEN CAST(display_value AS int) END) AS secs,
      min(CASE key WHEN 'start' THEN CAST(display_value AS int) END) AS start,
      min(CASE key WHEN 'submitted_to_rb' THEN CAST(display_value AS int) END) AS submitted_to_rb,
      min(CASE key WHEN 'ticks' THEN CAST(display_value AS int) END) AS ticks,
      min(CASE key WHEN 'timestamp' THEN CAST(display_value AS int) END) AS gpu_queue_id,
      min(CASE key WHEN 'usecs' THEN CAST(display_value AS int) END) AS usecs,
      min(CASE key WHEN 'wptr' THEN CAST(display_value AS int) END) AS wptr
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
    SELECT with_queue_id.*, process, thread, pid, tid
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

select *, start_ts as ts, total_dur as dur, concat(thread, ' (', process, ')') as name from kgsl_gpu