WITH trace_extents AS (
    SELECT MIN(ts) AS min_ts, MAX(ts) AS max_ts FROM ftrace_event
),
all_slices_on_track AS (
    SELECT
        s.ts, s.dur, s.name, s.track_id, t.name AS track_name,
        ROW_NUMBER() OVER (PARTITION BY s.track_id ORDER BY s.ts) AS seq_num
    FROM slice s
    JOIN track t ON s.track_id = t.id
    CROSS JOIN trace_extents
    WHERE t.name GLOB 'XRClient #*'
      AND s.ts > trace_extents.min_ts + 100000000
      AND s.ts < trace_extents.max_ts - 100000000
),
reprojected_only AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY track_id ORDER BY ts) AS rep_seq_num
    FROM all_slices_on_track WHERE name = 'Reprojected'
),
islands AS (
    SELECT *, (seq_num - rep_seq_num) AS island_id FROM reprojected_only
),
top_reprojected AS (
    SELECT
        track_id,
        track_name,
        /* Extract process name from track name "XRClient #<num> '<process name>'" */
        SUBSTR(track_name, INSTR(track_name, "'") + 1, LENGTH(track_name) - INSTR(track_name, "'") - 1) AS ProcessName,
        COUNT(*) AS DropCount,
        MIN(ts) AS Timestamp,
        MAX(ts) AS LastTimestamp,
        CAST(AVG(dur) AS INT) AS display_period
    FROM islands
    GROUP BY track_id, island_id
    ORDER BY DropCount DESC
    LIMIT 10
),
top_process AS (
    SELECT ProcessName FROM top_reprojected LIMIT 1
),
display_only AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY track_id ORDER BY ts) AS disp_seq_num
    FROM all_slices_on_track WHERE name = 'Display'
),
display_islands AS (
    SELECT *, (seq_num - disp_seq_num) AS island_id FROM display_only
),
largest_good_block AS (
    SELECT
        track_id,
        track_name,
        SUBSTR(track_name, INSTR(track_name, "'") + 1, LENGTH(track_name) - INSTR(track_name, "'") - 1) AS ProcessName,
        COUNT(*) AS GoodCount,
        MIN(ts) AS Timestamp,
        MAX(ts) AS LastTimestamp,
        CAST(AVG(dur) AS INT) AS display_period
    FROM display_islands
    WHERE SUBSTR(track_name, INSTR(track_name, "'") + 1, LENGTH(track_name) - INSTR(track_name, "'") - 1) = (SELECT ProcessName FROM top_process)
    GROUP BY track_id, island_id
    ORDER BY GoodCount DESC
    LIMIT 1
),
combined_results AS (
    SELECT ROW_NUMBER() OVER () AS row_id, track_id, track_name, ProcessName, DropCount, Timestamp, LastTimestamp, display_period, DropCount AS EventCount FROM top_reprojected
    UNION ALL
    SELECT 11 AS row_id, track_id, track_name, ProcessName, 0 AS DropCount, Timestamp, LastTimestamp, display_period, GoodCount AS EventCount FROM largest_good_block
),
window_bounds AS (
    SELECT
        *,
        CASE WHEN DropCount > 0 THEN Timestamp - 3 * display_period ELSE Timestamp END AS w_start,
        CASE WHEN DropCount > 0 THEN LastTimestamp + 2 * display_period ELSE LastTimestamp - 2 * display_period END AS w_end,
        CASE WHEN DropCount > 0 THEN EventCount + 4 ELSE EventCount - 3 END AS expected_frames
    FROM combined_results
),
client_cpu_only AS (
    SELECT s.ts, s.dur, s.name, s.track_id, t.name AS track_name
    FROM slice s
    JOIN track t ON s.track_id = t.id
    WHERE t.name GLOB 'XRClient #*' AND s.name = 'clientCPU'
),
client_cpu_intersections AS (
    SELECT
        wb.row_id,
        SUM(
            CASE
                WHEN s.ts + s.dur > wb.w_start AND s.ts < wb.w_end
                THEN (MIN(s.ts + s.dur, wb.w_end) - MAX(s.ts, wb.w_start)) * 1.0 / s.dur
                ELSE 0
            END
        ) AS fractional_count
    FROM window_bounds wb
    JOIN client_cpu_only s ON wb.track_name = s.track_name
    GROUP BY wb.row_id
),
gpu_slices_intersecting AS (
    SELECT
        wb.row_id,
        SUM(
            CASE
                WHEN gs.ts + gs.dur > wb.w_start AND gs.ts < wb.w_end
                THEN (MIN(gs.ts + gs.dur, wb.w_end) - MAX(gs.ts, wb.w_start))
                ELSE 0
            END
        ) / 1e6 AS gpu_dur_ms
    FROM window_bounds wb
    JOIN process p ON wb.ProcessName = p.name
    JOIN gpu_slice gs ON p.upid = gs.upid
    WHERE gs.name IN ('Workload', 'Dispatch')
    GROUP BY wb.row_id
),
other_gpu_slices_intersecting AS (
    SELECT
        wb.row_id,
        SUM(
            CASE
                WHEN gs.ts + gs.dur > wb.w_start AND gs.ts < wb.w_end
                THEN (MIN(gs.ts + gs.dur, wb.w_end) - MAX(gs.ts, wb.w_start))
                ELSE 0
            END
        ) / 1e6 AS other_gpu_dur_ms
    FROM window_bounds wb
    JOIN gpu_slice gs
    WHERE (gs.name IN ('Workload', 'Dispatch') AND gs.upid NOT IN (SELECT upid FROM process WHERE name = wb.ProcessName))
       OR (gs.name = 'Preempt')
    GROUP BY wb.row_id
),
cpu_idle_sum AS (
    SELECT
        wb.row_id,
        SUM(
            CASE
                WHEN s.ts + s.dur > wb.w_start AND s.ts < wb.w_end
                THEN (MIN(s.ts + s.dur, wb.w_end) - MAX(s.ts, wb.w_start))
                ELSE 0
            END
        ) AS total_idle_dur
    FROM window_bounds wb
    JOIN sched s ON s.ts + s.dur > wb.w_start AND s.ts < wb.w_end
    JOIN thread t USING (utid)
    WHERE t.name = 'swapper'
    GROUP BY wb.row_id
),
cpu_in_window AS (
    SELECT
        wb.row_id,
        t.tid,
        t.name AS thread_name,
        CAST(AVG(priority) AS INT) AS priority,
        SUM(s.dur / 1e6) AS dur_ms
    FROM window_bounds wb
    JOIN process p ON wb.ProcessName = p.name
    JOIN thread t ON p.upid = t.upid
    JOIN sched s ON t.utid = s.utid
    WHERE s.ts BETWEEN wb.w_start AND wb.w_end
      AND (p.name IS NOT NULL OR t.name != 'swapper')
    GROUP BY wb.row_id, t.utid
),
ranked_window_threads AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY row_id ORDER BY dur_ms DESC, tid ASC) AS duration_rank
    FROM cpu_in_window
),
top_threads_pivoted AS (
    SELECT
        row_id,
        SUM(dur_ms) AS all_cpu_dur_ms,
        MAX(CASE WHEN duration_rank = 1 THEN priority || ':' || thread_name ELSE NULL END) AS top_thread1,
        SUM(CASE WHEN duration_rank = 1 THEN dur_ms ELSE 0 END) AS mspf1,
        MAX(CASE WHEN duration_rank = 2 THEN priority || ':' || thread_name ELSE NULL END) AS top_thread2,
        SUM(CASE WHEN duration_rank = 2 THEN dur_ms ELSE 0 END) AS mspf2,
        MAX(CASE WHEN duration_rank = 3 THEN priority || ':' || thread_name ELSE NULL END) AS top_thread3,
        SUM(CASE WHEN duration_rank = 3 THEN dur_ms ELSE 0 END) AS mspf3
    FROM ranked_window_threads
    GROUP BY row_id
),
process_cpu_in_window AS (
    SELECT
        wb.row_id,
        COALESCE(p.name, t.name, 'swapper') AS proc_name,
        SUM(
            CASE
                WHEN s.ts + s.dur > wb.w_start AND s.ts < wb.w_end
                THEN (MIN(s.ts + s.dur, wb.w_end) - MAX(s.ts, wb.w_start))
                ELSE 0
            END
        ) AS dur_ns
    FROM window_bounds wb
    JOIN sched s ON s.ts + s.dur > wb.w_start AND s.ts < wb.w_end
    LEFT JOIN thread t USING (utid)
    LEFT JOIN process p USING (upid)
    WHERE t.name != 'swapper' AND t.name IS NOT NULL
    GROUP BY wb.row_id, COALESCE(p.name, t.name)
),
ranked_window_processes AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY row_id ORDER BY dur_ns DESC) AS duration_rank
    FROM process_cpu_in_window
),
top_processes_pivoted AS (
    SELECT
        row_id,
        MAX(CASE WHEN duration_rank = 1 THEN printf('%d', ROUND(100.0 * dur_ns / (wb.w_end - wb.w_start))) || ':' || proc_name ELSE NULL END) AS top_process1,
        MAX(CASE WHEN duration_rank = 2 THEN printf('%d', ROUND(100.0 * dur_ns / (wb.w_end - wb.w_start))) || ':' || proc_name ELSE NULL END) AS top_process2,
        MAX(CASE WHEN duration_rank = 3 THEN printf('%d', ROUND(100.0 * dur_ns / (wb.w_end - wb.w_start))) || ':' || proc_name ELSE NULL END) AS top_process3,
        MAX(CASE WHEN duration_rank = 4 THEN printf('%d', ROUND(100.0 * dur_ns / (wb.w_end - wb.w_start))) || ':' || proc_name ELSE NULL END) AS top_process4
    FROM ranked_window_processes
    JOIN window_bounds wb USING (row_id)
    GROUP BY row_id
),
runnable_durations AS (
    SELECT
        wb.row_id,
        SUM(
            CASE
                WHEN ts.ts + ts.dur > wb.w_start AND ts.ts < wb.w_end
                THEN (MIN(ts.ts + ts.dur, wb.w_end) - MAX(ts.ts, wb.w_start))
                ELSE 0
            END
        ) AS total_runnable_dur
    FROM window_bounds wb
    JOIN process p ON wb.ProcessName = p.name
    JOIN thread t ON p.upid = t.upid
    JOIN thread_state ts ON t.utid = ts.utid
    WHERE ts.state IN ('R', 'R+')
    GROUP BY wb.row_id
),
slices_in_windows AS (
    SELECT
        wb.row_id,
        s.name AS event_name,
        s.dur
    FROM window_bounds wb
    JOIN process p ON wb.ProcessName = p.name
    JOIN thread t ON p.upid = t.upid
    JOIN thread_track tr ON t.utid = tr.utid
    JOIN slice s ON tr.id = s.track_id
    JOIN (
        SELECT utid, priority
        FROM sched_slice
        GROUP BY utid
    ) ss ON t.utid = ss.utid
    WHERE s.ts >= wb.w_start AND s.ts + s.dur <= wb.w_end
      AND s.name IS NOT NULL
      AND ss.priority <= 130
),
window_slice_stats AS (
    SELECT
        row_id,
        event_name,
        AVG(dur) AS avg_dur,
        MAX(dur) AS max_dur
    FROM slices_in_windows
    GROUP BY row_id, event_name
),
good_slice_stats AS (
    SELECT event_name, avg_dur AS good_dur
    FROM window_slice_stats
    WHERE row_id = 11
),
bad_slice_stats AS (
    SELECT row_id, event_name, max_dur AS bad_dur
    FROM window_slice_stats
    WHERE row_id != 11
),
merged_stats AS (
    SELECT
        bss.row_id,
        bss.event_name,
        gss.good_dur,
        bss.bad_dur,
        (bss.bad_dur - COALESCE(gss.good_dur, 0)) AS dur_difference
    FROM bad_slice_stats bss
    LEFT JOIN good_slice_stats gss USING (event_name)
),
ranked_differences AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY row_id ORDER BY dur_difference DESC) AS diff_rank
    FROM merged_stats
),
top_events_pivoted AS (
    SELECT
        row_id,
        MAX(CASE WHEN diff_rank = 1 THEN printf('%.1f -> %.1f: %s', COALESCE(good_dur, 0) / 1e6, bad_dur / 1e6, event_name) ELSE NULL END) AS top_event_diff1,
        MAX(CASE WHEN diff_rank = 2 THEN printf('%.1f -> %.1f: %s', COALESCE(good_dur, 0) / 1e6, bad_dur / 1e6, event_name) ELSE NULL END) AS top_event_diff2,
        MAX(CASE WHEN diff_rank = 3 THEN printf('%.1f -> %.1f: %s', COALESCE(good_dur, 0) / 1e6, bad_dur / 1e6, event_name) ELSE NULL END) AS top_event_diff3
    FROM ranked_differences
    GROUP BY row_id
)
SELECT
    cr.ProcessName,
    cr.Timestamp,
    cr.DropCount AS Drops,
    printf('%.2f', COALESCE(cci.fractional_count, 0)) AS AppFrames,
    wb.expected_frames AS Vsyncs,
    printf('%g', ROUND(COALESCE(cis.total_idle_dur * 100.0 / (wb.w_end - wb.w_start), 0), 1)) AS CpuIdlePct,
    printf('%g', ROUND(COALESCE(gsi.gpu_dur_ms, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS GpuMSPF,
    printf('%g', ROUND(COALESCE(ogsi.other_gpu_dur_ms, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS OtherGpuMSPF,
    printf('%g', ROUND(COALESCE(ttp.all_cpu_dur_ms, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS CpuMSPF,
    printf('%g', ROUND(COALESCE(rd.total_runnable_dur / 1e6, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS RunnableMSPF,
    ttp.top_thread1 AS TopThread1,
    printf('%g', ROUND(COALESCE(ttp.mspf1, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS MSPF1,
    ttp.top_thread2 AS TopThread2,
    printf('%g', ROUND(COALESCE(ttp.mspf2, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS MSPF2,
    ttp.top_thread3 AS TopThread3,
    printf('%g', ROUND(COALESCE(ttp.mspf3, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS MSPF3,
    tep.top_event_diff1 AS TopEventDiffMS1,
    tep.top_event_diff2 AS TopEventDiffMS2,
    tep.top_event_diff3 AS TopEventDiffMS3,
    tpp.top_process1 AS TopProcessPct1,
    tpp.top_process2 AS TopProcessPct2,
    tpp.top_process3 AS TopProcessPct3,
    tpp.top_process4 AS TopProcessPct4
FROM combined_results cr
JOIN window_bounds wb USING (row_id)
LEFT JOIN top_threads_pivoted ttp USING (row_id)
LEFT JOIN top_processes_pivoted tpp USING (row_id)
LEFT JOIN top_events_pivoted tep USING (row_id)
LEFT JOIN runnable_durations rd USING (row_id)
LEFT JOIN client_cpu_intersections cci USING (row_id)
LEFT JOIN gpu_slices_intersecting gsi USING (row_id)
LEFT JOIN other_gpu_slices_intersecting ogsi USING (row_id)
LEFT JOIN cpu_idle_sum cis USING (row_id)
ORDER BY cr.DropCount DESC;
