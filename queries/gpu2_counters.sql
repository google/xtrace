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

WITH
  target_procs AS (
    SELECT upid
    FROM gpu_slice
    WHERE /* template target filter processing */ name IN ('Binning', 'Render', 'Dispatch')
    GROUP BY upid
    ORDER BY COUNT(*) DESC
    LIMIT 1
  ),
  tracks_to_fix AS (
    SELECT id, name FROM gpu_counter_track
  ),
  fixed_counters_pre AS (
    SELECT
      ts,
      track_id,
      value AS value_no_lag,
      LAG(value) OVER (PARTITION BY track_id ORDER BY ts) AS value_lag,
      name AS counter_name
    FROM counter c
    JOIN tracks_to_fix t ON c.track_id = t.id
  ),
  /* older drivers have an offset that we need to check for and fix */
  need_lag_flag AS (
    SELECT
      CASE
        WHEN COUNT(*) > 0 THEN 1
        ELSE 0
      END AS need_lag
    FROM gpu_slice s
    JOIN fixed_counters_pre c ON c.ts = s.ts
    WHERE s.name IN ('Binning', 'Render', 'Dispatch')
      AND c.counter_name = 'Clocks'
      AND c.value_lag > 0
  ),
  fixed_counters AS (
    SELECT
      ts,
      track_id,
      counter_name,
      CASE
        WHEN (SELECT need_lag FROM need_lag_flag) = 1 THEN value_lag
        ELSE value_no_lag
      END AS value
    FROM fixed_counters_pre
  ),
  /* --- BEGIN IDENTICAL SURFACE CONSOLIDATION CTE BLOCK --- */
  surface_slices_raw AS (
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
  /* --- END IDENTICAL SURFACE CONSOLIDATION CTE BLOCK --- */
  all_surfaces AS (
    SELECT
      ts,
      width,
      height,
      binWidth,
      binHeight,
      CASE WHEN consolidated_key = (
        SELECT consolidated_key
        FROM surface_slices
        WHERE 1=1 /* template surface filter */
        LIMIT 1
      ) THEN 1 ELSE 0 END AS is_selected
    FROM surface_slices
  ),
  gpu_stages AS (
    SELECT
      ts,
      dur,
      upid,
      CASE
        WHEN name GLOB '*Binning*' THEN 'Binning'
        WHEN name GLOB '*Render*' THEN 'Render'
        WHEN name GLOB '*Dispatch*' THEN 'Dispatch'
        ELSE 'Other'
      END AS stage_type
    FROM gpu_slice
    WHERE upid IN (SELECT upid FROM target_procs)
  ),
  combined_events AS (
    SELECT ts, 'surface' as type, is_selected as val, width, height, binWidth, binHeight FROM all_surfaces
    UNION ALL
    SELECT ts, 'stage' as type, 0 as val, NULL, NULL, NULL, NULL FROM gpu_stages WHERE stage_type != 'Other' AND stage_type != 'Dispatch'
  ),
  ordered_events AS (
    SELECT
       ts, type, val, width, height, binWidth, binHeight,
       SUM(CASE WHEN type = 'surface' THEN 1 ELSE 0 END) OVER (ORDER BY ts) as surface_group_id
    FROM combined_events
  ),
  group_selection AS (
    SELECT
      surface_group_id,
      MAX(val) as is_selected,
      MAX(width) as width,
      MAX(height) as height,
      MAX(binWidth) as binWidth,
      MAX(binHeight) as binHeight
    FROM ordered_events
    WHERE type = 'surface'
    GROUP BY surface_group_id
  ),
  filtered_stages AS (
    SELECT
      s.ts, s.dur, s.upid, s.stage_type,
      COALESCE(g.is_selected, 0) as is_selected,
      g.width, g.height, g.binWidth, g.binHeight
    FROM gpu_stages s
    LEFT JOIN ordered_events o ON s.ts = o.ts AND o.type = 'stage'
    LEFT JOIN group_selection g ON o.surface_group_id = g.surface_group_id
    WHERE s.stage_type != 'Other' AND s.stage_type != 'Dispatch'
      AND (g.is_selected = 1 OR (g.is_selected IS NULL AND /* template filter active */ 0 = 0))
    UNION ALL
    SELECT ts, dur, upid, stage_type, 1 as is_selected, NULL, NULL, NULL, NULL
    FROM gpu_stages
    WHERE stage_type = 'Dispatch'
  ),
  stage_counters AS (
    SELECT
      s.upid,
      s.stage_type,
      s.dur,
      c.counter_name,
      c.value
    FROM filtered_stages s
    JOIN fixed_counters c ON c.ts = s.ts
    WHERE c.value IS NOT NULL
  ),
  frame_count AS (
    SELECT COUNT(*) AS count
    FROM all_surfaces
    WHERE is_selected = 1
  ),
  aggregated AS (
    SELECT
      CASE
        WHEN counter_name GLOB '*%*' OR counter_name GLOB '*/**' OR counter_name GLOB 'Average*' OR counter_name GLOB 'Avg*' OR counter_name GLOB '* Per *' THEN counter_name
        ELSE counter_name || ' / Frame'
      END AS counter_name,
      /* Binning */
      CASE
        WHEN counter_name GLOB '*%*' OR counter_name GLOB '*/**' OR counter_name GLOB 'Average*' OR counter_name GLOB 'Avg*' OR counter_name GLOB '* Per *' THEN
          SUM(CASE WHEN stage_type = 'Binning' THEN value * dur ELSE 0 END) /
          NULLIF(SUM(CASE WHEN stage_type = 'Binning' THEN dur ELSE 0 END), 0)
        ELSE
          SUM(CASE WHEN stage_type = 'Binning' THEN value ELSE 0 END) /
          CAST(COALESCE(NULLIF((SELECT count FROM frame_count), 0), 1) AS FLOAT)
      END AS Binning,
      /* Render */
      CASE
        WHEN counter_name GLOB '*%*' OR counter_name GLOB '*/**' OR counter_name GLOB 'Average*' OR counter_name GLOB 'Avg*' OR counter_name GLOB '* Per *' THEN
          SUM(CASE WHEN stage_type = 'Render' THEN value * dur ELSE 0 END) /
          NULLIF(SUM(CASE WHEN stage_type = 'Render' THEN dur ELSE 0 END), 0)
        ELSE
          SUM(CASE WHEN stage_type = 'Render' THEN value ELSE 0 END) /
          CAST(COALESCE(NULLIF((SELECT count FROM frame_count), 0), 1) AS FLOAT)
      END AS Render,
      /* Dispatch */
      CASE
        WHEN counter_name GLOB '*%*' OR counter_name GLOB '*/**' OR counter_name GLOB 'Average*' OR counter_name GLOB 'Avg*' OR counter_name GLOB '* Per *' THEN
          SUM(CASE WHEN stage_type = 'Dispatch' THEN value * dur ELSE 0 END) /
          NULLIF(SUM(CASE WHEN stage_type = 'Dispatch' THEN dur ELSE 0 END), 0)
        ELSE
          SUM(CASE WHEN stage_type = 'Dispatch' THEN value ELSE 0 END) /
          CAST(COALESCE(NULLIF((SELECT count FROM frame_count), 0), 1) AS FLOAT)
      END AS Dispatch
    FROM stage_counters
    GROUP BY counter_name
  ),
  synthesized AS (
    SELECT
      '$$$ Frame Count' AS counter_name,
      CASE WHEN (SELECT COUNT(*) FROM filtered_stages WHERE stage_type = 'Binning') > 0 THEN (SELECT count FROM frame_count) ELSE 0 END AS Binning,
      CASE WHEN (SELECT COUNT(*) FROM filtered_stages WHERE stage_type = 'Render') > 0 THEN (SELECT count FROM frame_count) ELSE 0 END AS Render,
      CASE WHEN (SELECT COUNT(*) FROM filtered_stages WHERE stage_type = 'Dispatch') > 0 THEN (SELECT count FROM frame_count) ELSE 0 END AS Dispatch
    UNION ALL
    SELECT
      '$$$ Events / Frame' AS counter_name,
      CAST(SUM(CASE WHEN stage_type = 'Binning' THEN 1 ELSE 0 END) AS FLOAT) / CAST(COALESCE(NULLIF((SELECT count FROM frame_count), 0), 1) AS FLOAT) AS Binning,
      CAST(SUM(CASE WHEN stage_type = 'Render' THEN 1 ELSE 0 END) AS FLOAT) / CAST(COALESCE(NULLIF((SELECT count FROM frame_count), 0), 1) AS FLOAT) AS Render,
      CAST(SUM(CASE WHEN stage_type = 'Dispatch' THEN 1 ELSE 0 END) AS FLOAT) / CAST(COALESCE(NULLIF((SELECT count FROM frame_count), 0), 1) AS FLOAT) AS Dispatch
    FROM filtered_stages
    UNION ALL
    SELECT
      '$$$ Clocks / Second' AS counter_name,
      SUM(CASE WHEN stage_type = 'Binning' THEN value ELSE 0 END) / NULLIF(SUM(CASE WHEN stage_type = 'Binning' THEN dur ELSE 0 END) / 1e6, 0) AS Binning,
      SUM(CASE WHEN stage_type = 'Render' THEN value ELSE 0 END) / NULLIF(SUM(CASE WHEN stage_type = 'Render' THEN dur ELSE 0 END) / 1e6, 0) AS Render,
      SUM(CASE WHEN stage_type = 'Dispatch' THEN value ELSE 0 END) / NULLIF(SUM(CASE WHEN stage_type = 'Dispatch' THEN dur ELSE 0 END) / 1e6, 0) AS Dispatch
    FROM stage_counters
    WHERE counter_name = 'Clocks'
    UNION ALL
    SELECT
      '$$$ Resolution Width' AS counter_name,
      AVG(CASE WHEN stage_type = 'Binning' THEN binWidth END) as Binning,
      AVG(CASE WHEN stage_type = 'Render' THEN width END) as Render,
      0 as Dispatch
    FROM filtered_stages
    UNION ALL
    SELECT
      '$$$ Resolution Height' AS counter_name,
      AVG(CASE WHEN stage_type = 'Binning' THEN binHeight END) as Binning,
      AVG(CASE WHEN stage_type = 'Render' THEN height END) as Render,
      0 as Dispatch
    FROM filtered_stages
    UNION ALL
    SELECT
      '$$$ Fragments / Pixel (Overdraw)' AS counter_name,
      0 AS Binning,
      (SELECT SUM(value) FROM stage_counters WHERE counter_name = 'Fragments Shaded' AND stage_type = 'Render') /
        CAST(COALESCE(NULLIF((SELECT count FROM frame_count), 0), 1) AS FLOAT) /
        NULLIF(
          (SELECT AVG(width) FROM filtered_stages WHERE stage_type = 'Render') *
          (SELECT AVG(height) FROM filtered_stages WHERE stage_type = 'Render')
        , 0) AS Render,
      0 AS Dispatch
    UNION ALL
    SELECT
      '$$$ GPU MS / Frame' AS counter_name,
      SUM(CASE WHEN stage_type = 'Binning' THEN dur ELSE 0 END) / 1e6 / CAST(COALESCE(NULLIF((SELECT count FROM frame_count), 0), 1) AS FLOAT) AS Binning,
      SUM(CASE WHEN stage_type = 'Render' THEN dur ELSE 0 END) / 1e6 / CAST(COALESCE(NULLIF((SELECT count FROM frame_count), 0), 1) AS FLOAT) AS Render,
      SUM(CASE WHEN stage_type = 'Dispatch' THEN dur ELSE 0 END) / 1e6 / CAST(COALESCE(NULLIF((SELECT count FROM frame_count), 0), 1) AS FLOAT) AS Dispatch
    FROM filtered_stages
  ),
  combined AS (
    SELECT * FROM aggregated
    UNION ALL
    SELECT * FROM synthesized
  )
SELECT
  counter_name AS Counter,
  printf('%.2f', IFNULL(Binning, 0)) AS Binning,
  printf('%.2f', IFNULL(Render, 0)) AS Render,
  printf('%.2f', IFNULL(Dispatch, 0)) AS Dispatch
FROM combined
WHERE Binning > 0 OR Render > 0 OR Dispatch > 0
ORDER BY Counter;
