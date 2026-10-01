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
proc_pct_calculated AS (
    SELECT
        row_id,
        proc_name,
        dur_ns,
        CAST(ROUND(100.0 * dur_ns / (wb.w_end - wb.w_start)) AS INTEGER) AS pct
    FROM process_cpu_in_window
    JOIN window_bounds wb USING (row_id)
),
nominal_proc_pct AS (
    SELECT proc_name, pct AS good_pct
    FROM proc_pct_calculated
    WHERE row_id = 11
),
ranked_window_processes AS (
    SELECT
        p.row_id,
        p.proc_name,
        p.pct AS bad_pct,
        COALESCE(np.good_pct, 0) AS good_pct,
        ROW_NUMBER() OVER (PARTITION BY p.row_id ORDER BY p.dur_ns DESC) AS duration_rank
    FROM proc_pct_calculated p
    LEFT JOIN nominal_proc_pct np USING (proc_name)
),
top_processes_pivoted AS (
    SELECT
        row_id,
        MAX(CASE WHEN duration_rank = 1 THEN
            CASE WHEN row_id = 11 THEN printf('%d:%s', bad_pct, proc_name)
                 ELSE printf('%d -> %d:%s', good_pct, bad_pct, proc_name) END
            ELSE NULL END) AS top_process1,
        MAX(CASE WHEN duration_rank = 2 THEN
            CASE WHEN row_id = 11 THEN printf('%d:%s', bad_pct, proc_name)
                 ELSE printf('%d -> %d:%s', good_pct, bad_pct, proc_name) END
            ELSE NULL END) AS top_process2,
        MAX(CASE WHEN duration_rank = 3 THEN
            CASE WHEN row_id = 11 THEN printf('%d:%s', bad_pct, proc_name)
                 ELSE printf('%d -> %d:%s', good_pct, bad_pct, proc_name) END
            ELSE NULL END) AS top_process3,
        MAX(CASE WHEN duration_rank = 4 THEN
            CASE WHEN row_id = 11 THEN printf('%d:%s', bad_pct, proc_name)
                 ELSE printf('%d -> %d:%s', good_pct, bad_pct, proc_name) END
            ELSE NULL END) AS top_process4
    FROM ranked_window_processes
    GROUP BY row_id
),
/* All threads of the target processes. */
target_threads AS MATERIALIZED (
    SELECT DISTINCT t.utid, p.name AS proc_name
    FROM thread t
    JOIN process p USING (upid)
    WHERE p.name IN (SELECT ProcessName FROM window_bounds)
),
window_extent AS MATERIALIZED (
    SELECT MIN(w_start) AS ext_start, MAX(w_end) AS ext_end FROM window_bounds
),
/* Single pass over sched / thread_state for the target threads within the window extent.
   Joining these large tables per window directly can pick very slow query plans. */
target_sched AS MATERIALIZED (
    SELECT sc.utid, sc.ts, sc.dur, sc.priority
    FROM sched sc, window_extent we
    WHERE sc.utid IN (SELECT utid FROM target_threads)
      AND sc.ts < we.ext_end AND sc.ts + sc.dur > we.ext_start
),
target_runnable AS MATERIALIZED (
    SELECT ts.utid, ts.ts, ts.dur
    FROM thread_state ts, window_extent we
    WHERE ts.utid IN (SELECT utid FROM target_threads)
      AND ts.state IN ('R', 'R+')
      AND ts.ts < we.ext_end AND ts.ts + ts.dur > we.ext_start
),
/* Sched slices of the window's process threads that overlap each window. */
window_sched AS MATERIALIZED (
    SELECT wb.row_id, sc.utid, sc.ts, sc.dur, sc.priority
    FROM window_bounds wb
    JOIN target_threads tt ON tt.proc_name = wb.ProcessName
    JOIN target_sched sc ON sc.utid = tt.utid
    WHERE sc.ts < wb.w_end AND sc.ts + sc.dur > wb.w_start
),
/* Runnable (R / R+) thread states of the window's process threads that overlap each window. */
window_runnable AS MATERIALIZED (
    SELECT wb.row_id, tr.utid, tr.ts, tr.dur
    FROM window_bounds wb
    JOIN target_threads tt ON tt.proc_name = wb.ProcessName
    JOIN target_runnable tr ON tr.utid = tt.utid
    WHERE tr.ts < wb.w_end AND tr.ts + tr.dur > wb.w_start
),
/* Highest scheduling priority (lowest number) each thread of the process had
   within each window. Kernel prio: <100 RT, 100-119 elevated, 120 default (nice 0), >120 background. */
thread_window_prio AS MATERIALIZED (
    SELECT row_id, utid, MIN(priority) AS priority
    FROM window_sched
    GROUP BY row_id, utid
),
/* Fallback for threads that did not run in a window. */
thread_trace_prio AS MATERIALIZED (
    SELECT utid, MIN(priority) AS priority
    FROM sched
    WHERE utid IN (SELECT utid FROM target_threads)
    GROUP BY utid
),
runnable_durations AS (
    SELECT
        wr.row_id,
        SUM(MIN(wr.ts + wr.dur, wb.w_end) - MAX(wr.ts, wb.w_start)) AS total_runnable_dur,
        SUM(
            CASE
                WHEN COALESCE(twp.priority, ttp.priority) < 120
                THEN (MIN(wr.ts + wr.dur, wb.w_end) - MAX(wr.ts, wb.w_start))
                ELSE 0
            END
        ) AS hi_prio_runnable_dur
    FROM window_runnable wr
    JOIN window_bounds wb USING (row_id)
    LEFT JOIN thread_window_prio twp ON twp.row_id = wr.row_id AND twp.utid = wr.utid
    LEFT JOIN thread_trace_prio ttp ON ttp.utid = wr.utid
    GROUP BY wr.row_id
),
cpu_freq_spans AS MATERIALIZED (
    SELECT
        t.cpu,
        c.ts,
        c.value AS freq_khz,
        LEAD(c.ts, 1, (SELECT MAX(ts) FROM ftrace_event)) OVER (PARTITION BY t.cpu ORDER BY c.ts) AS next_ts
    FROM counter c
    JOIN cpu_counter_track t ON c.track_id = t.id
    WHERE t.name = 'cpufreq'
),
cpu_freq_durations AS (
    SELECT
        wb.row_id,
        CAST(ROUND(SUM(fs.freq_khz * (MIN(fs.next_ts, wb.w_end) - MAX(fs.ts, wb.w_start)))
                   / NULLIF(SUM(MIN(fs.next_ts, wb.w_end) - MAX(fs.ts, wb.w_start)), 0) / 1000.0) AS INTEGER) AS avg_cpu_freq_mhz
    FROM window_bounds wb
    JOIN cpu_freq_spans fs
      ON fs.ts < wb.w_end AND fs.next_ts > wb.w_start
    GROUP BY wb.row_id
),
/* Slices of the window's process threads, excluding low priority background threads
   (based on the thread's highest priority within the window). */
slices_in_windows AS MATERIALIZED (
    SELECT
        wb.row_id,
        s.id AS slice_id,
        s.name AS event_name,
        s.ts,
        s.dur,
        t.utid,
        t.name AS thread_name,
        COALESCE(twp.priority, ttp.priority) AS thread_priority
    FROM window_bounds wb
    JOIN process p ON wb.ProcessName = p.name
    JOIN thread t ON p.upid = t.upid
    JOIN thread_track tr ON t.utid = tr.utid
    JOIN slice s ON tr.id = s.track_id
    LEFT JOIN thread_window_prio twp ON twp.row_id = wb.row_id AND twp.utid = t.utid
    LEFT JOIN thread_trace_prio ttp ON ttp.utid = t.utid
    WHERE s.ts >= wb.w_start AND s.ts + s.dur <= wb.w_end
      AND s.dur >= 0
      AND s.name IS NOT NULL
      AND COALESCE(twp.priority, ttp.priority) <= 130
),
ranked_instances AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY row_id, event_name ORDER BY dur DESC) AS inst_rank
    FROM slices_in_windows
),
good_vsyncs AS (
    SELECT expected_frames FROM window_bounds WHERE row_id = 11
),
good_slice_stats AS MATERIALIZED (
    SELECT
        event_name,
        COUNT(*) AS total_good_cnt,
        SUM(dur) AS total_good_dur
    FROM slices_in_windows
    WHERE row_id = 11
    GROUP BY event_name
),
bad_slice_stats AS MATERIALIZED (
    SELECT
        sw.row_id,
        sw.event_name,
        COUNT(*) AS bad_cnt,
        SUM(sw.dur) AS bad_dur
    FROM slices_in_windows sw
    WHERE sw.row_id != 11
    GROUP BY sw.row_id, sw.event_name
),
ranked_differences AS (
    SELECT
        bss.row_id,
        bss.event_name,
        bss.bad_cnt,
        bss.bad_dur,
        ROUND(COALESCE(gss.total_good_cnt, 0) * 1.0 * wb.expected_frames / gv.expected_frames) AS good_cnt_scaled,
        (COALESCE(gss.total_good_dur, 0) * 1.0 * wb.expected_frames / gv.expected_frames) AS good_dur_scaled,
        ((bss.bad_dur) - (COALESCE(gss.total_good_dur, 0) * 1.0 * wb.expected_frames / gv.expected_frames)) AS dur_difference,
        ROW_NUMBER() OVER (PARTITION BY bss.row_id ORDER BY ((bss.bad_dur) - (COALESCE(gss.total_good_dur, 0) * 1.0 * wb.expected_frames / gv.expected_frames)) DESC) AS diff_rank
    FROM bad_slice_stats bss
    JOIN window_bounds wb ON wb.row_id = bss.row_id
    CROSS JOIN good_vsyncs gv
    LEFT JOIN good_slice_stats gss ON gss.event_name = bss.event_name
),
top_differences AS MATERIALIZED (
    SELECT * FROM ranked_differences WHERE diff_rank <= 3
),
/* Only compute the CPU state breakdown for slices that are reported:
   the top events in drop windows and the nominal instances of the same events. */
breakdown_slices AS MATERIALIZED (
    SELECT sw.*
    FROM slices_in_windows sw
    WHERE (sw.row_id, sw.event_name) IN (SELECT row_id, event_name FROM top_differences)
       OR (sw.row_id = 11 AND sw.event_name IN (SELECT DISTINCT event_name FROM top_differences))
),
/* On-CPU time and highest priority while each slice was running. */
slice_sched AS (
    SELECT
        bs.row_id,
        bs.event_name,
        SUM(MIN(sc.ts + sc.dur, bs.ts + bs.dur) - MAX(sc.ts, bs.ts)) AS run_dur,
        MIN(sc.priority) AS priority,
        MIN(bs.thread_name) AS thread_name
    FROM breakdown_slices bs
    JOIN window_sched sc ON sc.row_id = bs.row_id AND sc.utid = bs.utid
    WHERE sc.ts < bs.ts + bs.dur AND sc.ts + sc.dur > bs.ts
    GROUP BY bs.row_id, bs.event_name
),
/* Runnable (preempted / waiting for CPU) time during each slice. */
slice_runnable AS (
    SELECT
        bs.row_id,
        bs.event_name,
        SUM(MIN(wr.ts + wr.dur, bs.ts + bs.dur) - MAX(wr.ts, bs.ts)) AS rbl_dur
    FROM breakdown_slices bs
    JOIN window_runnable wr ON wr.row_id = bs.row_id AND wr.utid = bs.utid
    WHERE wr.ts < bs.ts + bs.dur AND wr.ts + wr.dur > bs.ts
    GROUP BY bs.row_id, bs.event_name
),
good_breakdown AS (
    SELECT
        bs.event_name,
        ssc.run_dur AS nominal_run_dur,
        sr.rbl_dur AS nominal_rbl_dur
    FROM (SELECT DISTINCT event_name FROM breakdown_slices WHERE row_id = 11) bs
    LEFT JOIN slice_sched ssc ON ssc.row_id = 11 AND ssc.event_name = bs.event_name
    LEFT JOIN slice_runnable sr ON sr.row_id = 11 AND sr.event_name = bs.event_name
),
ranked_differences_desc AS (
    SELECT
        td.row_id,
        td.diff_rank,
        /* Format: "good -> bad (cnt good -> bad; run good -> bad; rbl good -> bad): prio:thread:event" (ms).
           No commas since the output is CSV. Blocked time = wall - run - rbl. */
        printf('%.1f -> %.1f (cnt %d -> %d; run %.1f -> %.1f; rbl %.1f -> %.1f): %d:%s:%s',
               COALESCE(td.good_dur_scaled, 0) / 1e6, td.bad_dur / 1e6,
               CAST(COALESCE(td.good_cnt_scaled, 0) AS INT), td.bad_cnt,
               (COALESCE(gb.nominal_run_dur, 0) * 1.0 * wb.expected_frames / gv.expected_frames) / 1e6, COALESCE(ssc.run_dur, 0) / 1e6,
               (COALESCE(gb.nominal_rbl_dur, 0) * 1.0 * wb.expected_frames / gv.expected_frames) / 1e6, COALESCE(sr.rbl_dur, 0) / 1e6,
               COALESCE(ssc.priority, (SELECT MIN(thread_priority) FROM breakdown_slices WHERE row_id = td.row_id AND event_name = td.event_name)),
               COALESCE(ssc.thread_name, (SELECT MIN(thread_name) FROM breakdown_slices WHERE row_id = td.row_id AND event_name = td.event_name), '?'),
               td.event_name) AS event_desc
    FROM top_differences td
    JOIN window_bounds wb ON wb.row_id = td.row_id
    CROSS JOIN good_vsyncs gv
    LEFT JOIN slice_sched ssc ON ssc.row_id = td.row_id AND ssc.event_name = td.event_name
    LEFT JOIN slice_runnable sr ON sr.row_id = td.row_id AND sr.event_name = td.event_name
    LEFT JOIN good_breakdown gb ON gb.event_name = td.event_name
),
top_events_pivoted AS (
    SELECT
        row_id,
        MAX(CASE WHEN diff_rank = 1 THEN event_desc ELSE NULL END) AS top_event_diff1,
        MAX(CASE WHEN diff_rank = 2 THEN event_desc ELSE NULL END) AS top_event_diff2,
        MAX(CASE WHEN diff_rank = 3 THEN event_desc ELSE NULL END) AS top_event_diff3
    FROM ranked_differences_desc
    GROUP BY row_id
)
SELECT
    cr.ProcessName,
    cr.Timestamp,
    cr.DropCount AS Drops,
    printf('%.2f', COALESCE(cci.fractional_count, 0)) AS AppFrames,
    wb.expected_frames AS Vsyncs,
    printf('%g', ROUND(COALESCE(cis.total_idle_dur * 100.0 / (wb.w_end - wb.w_start), 0), 1)) AS CpuIdlePct,
    COALESCE(cfd.avg_cpu_freq_mhz, 0) AS CpuFreq,
    printf('%g', ROUND(COALESCE(gsi.gpu_dur_ms, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS GpuMSPF,
    printf('%g', ROUND(COALESCE(ogsi.other_gpu_dur_ms, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS OtherGpuMSPF,
    printf('%g', ROUND(COALESCE(ttp.all_cpu_dur_ms, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS CpuMSPF,
    printf('%g', ROUND(COALESCE(rd.total_runnable_dur / 1e6, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS RunnableMSPF,
    printf('%g', ROUND(COALESCE(rd.hi_prio_runnable_dur / 1e6, 0) / COALESCE(NULLIF(cci.fractional_count, 0), wb.expected_frames), 3)) AS RunnableHiPrioMSPF,
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
LEFT JOIN cpu_freq_durations cfd USING (row_id)
ORDER BY cr.DropCount DESC;
