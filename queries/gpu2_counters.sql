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
  target_process AS (
    SELECT upid
    FROM gpu_slice
    WHERE /* template target filter processing */ name IN ('Binning', 'Render', 'Dispatch', 'Compute')
    GROUP BY upid
    ORDER BY COUNT(*) DESC
    LIMIT 1
  ),
  tracks_to_fix AS (
    SELECT id, name FROM gpu_counter_track
  ),
  fixed_counters AS (
    SELECT
      ts,
      track_id,
      LAG(value) OVER (PARTITION BY track_id ORDER BY ts) AS value,
      t.name AS counter_name
    FROM counter c
    JOIN tracks_to_fix t ON c.track_id = t.id
  ),
  all_surfaces AS (
    SELECT
      ts,
      EXTRACT_ARG(arg_set_id, 'width') AS width,
      EXTRACT_ARG(arg_set_id, 'height') AS height,
      EXTRACT_ARG(arg_set_id, 'binWidth') AS binWidth,
      EXTRACT_ARG(arg_set_id, 'binHeight') AS binHeight,
      CASE WHEN 1=1 /* template surface filter */ THEN 1 ELSE 0 END AS is_selected
    FROM gpu_slice
    WHERE upid IN (SELECT upid FROM target_process)
      AND name = 'Surface'
  ),
  gpu_stages AS (
    SELECT
      ts,
      dur,
      upid,
      CASE
        WHEN name GLOB '*Binning*' THEN 'Binning'
        WHEN name GLOB '*Render*' THEN 'Render'
        WHEN (name GLOB '*Compute*' OR name GLOB '*Dispatch*') THEN 'Dispatch'
        ELSE 'Other'
      END AS stage_type
    FROM gpu_slice
    WHERE upid IN (SELECT upid FROM target_process)
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
