# xtrace --perf-dump Report

Two traces are captured below. First is with --gpu1 to get accurate GPU frame stats, surface stats, drop stats, and top stats. Second is with --gpu2 --counters to get detailed GPU counters, binning and tile render stats.

## Instructions for AI Agent

Help pinpoint performance problems with deep knowledge of Android XR, Adreno GPU architectures, and rendering performance debugging. Use the following context and guidelines to analyze the data. Focus on the most significant issues and make recommendations for fixing them. Use objective language and avoid hyperbole.

## How to read the data

### --top tips:
*   Watch for a nearly saturated CPU (ie: "idle cpu" below 100 or so), although keep in mind the app can not use all of the cores, so it's possible for the app cpuset to be completely saturated while idle cpu is non-zero.

### --frame-stats tips:
*   Drops and DropsPM (drops per minute) are the critical metrics - a few drops may be okay but higher drop rates can cause real discomfort in XR.
*   If the GpuMSPF is too high, the simplest fix for XR applications is to reduce the Render Scale or MSAA (MSAA 2 is often enough and 4 can be costly).
*   surfaceflinger Drops (compositor frame drops in Android XR) should be zero. Otherwise there may be another process with very expensive shaders or overdraw (to confirm that, look at the --gpu2 trace --surface-stats for a "RenderMaxMS" of more than 1 or 2 ms).
*   surfaceflinger FPS should be close to the display FPS (ie: 60, 72, or 90), and is typically what each rendering process should match (except for spacewarp apps which may show as half framerate).
*   The XR app's GPU budget is NOT the display period. It is display period MINUS surfaceflinger GpuMSPF (compositor GPU usage). The GPU cost of compositing increases with higher app resolution and content detail (more detail is less efficient with UBWC).
*   TopThread1 and TopThread2 are often the app's "main" and "render" threads. Their corresponding MSPF1 and MSPF2 can indicate whether the app is CPU bound (ie: if MSPF is close to the frame period).
*   CpuMSPF == TOTAL app CPU usage SUMMED ACROSS ALL THREADS so it is often okay to be more than the display period.
*   Typically these stats show at least 3 processes: the app, surfaceflinger and SysUI.
*   The Watts power results are typically only accurate in longer 60+ second traces.

### --drop-stats tips:
*   Goal of this table is to show why frame drops are happening.
*   Drops count > 0 (problem cases): These rows show cases of consecutive frame drops.
*   Drops count == 0 (nominal case): This row shows the longest sequence of good frames for comparison with the frame drop cases.
*   Each row looks at a window of trace data whose range is the Vsyncs count. For drop cases, the window goes from a few frames before the drops to 1 frame after. For the nominal case, the window is reduced to focus on the good frame data.
*   The GpuMSPF is only the app GPU usage and the value can be a little off because of our small window size, but watch for increases compared to nominal. OtherGpuMSPF shows preemption overheads and other visible GPU activity.
*   Watch for CpuIdlePct very low compared to nominal, as CPU saturation can cause drops.
*   Watch TopEventDiffMS for differences in event durations that might indicate the root cause. Ex: 1.1 -> 7.0 indicates a ~6ms jump in that event's duration compared to nominal.
*   Watch the MSPF of the top threads. Engines like Unity are given RT prio on the main and render thread (ie: 98), but if they are using 9+ ms per frame they can still miss deadlines and cause a drop. If the top threads still look like main or render threads and they are not RT prio, then that's also a potential red flag (may need to fix engine code).
*   If a GC finalizer thread shows on drop cases, a GC pause probably caused the drop.
*   We may not see the SysUI GPU usage, so if there is any evidence of SysUI rendering in --frame-stats or --top (like high CPU usage) then that could explain app frame drops where it appears the app CPU and GPU usage is okay. If so, and this is not intended, then the user needs to trace again without triggering SysUI activity.
*   If the problem appears to be background CPU activity from other system processes, then it can help to determine if this was a temporary issue or not by running another --perf-dump trace.
*   TopProcessPct shows the % of window time consumed by the top processes. Can identify changes in background process behavior.
*   RunnableMSPF shows the MS per frame that the process threads were in runnable state. This includes background threads that are not synchronized with per-frame code, so it may not always correlate well with frame drop cases where the time per frame is higher than the nominal case.

### --surface-stats tips:
*   A surface in these stats is a full renderpass that resolves out to DDR.
*   For the first trace, use the surface stats for overall surface render times and surface attributes. Mobile XR apps perform best with one GPU surface, but sometimes more are necessary. If there are more than one with the same resolution, that can indicate a misconfigured render pass that prevents multiple sub-passes from merging into a single surface event.
*   For the second --gpu2 --counters trace remember that the GpuMSPF values may be inflated due to tracing overhead, and the Bin and Render times may also be off, but are useful ballpark figures.
*   Only the second trace will have numbers for RenderMaxMS, which is important as noted above to be less than a couple ms to avoid compositor tearing.
*   Watch for interesting abnormalities in RTs (render target count, ie: 2 for color + depth), RTBPP (total bits per pixel, ie: 64 for for 32-bit color and depth).
*   Check the RenderMode for direct vs binning. A direct-mode surface is often a problem on XR because they may not be preemptible or they may be faster with tiled rendering. To force binning mode, dev can try adding a second draw call with a single degenerate triangle.
*   GpuMaxMS is the longest GPU usage duration for a single Surface event. Useful to explain some frame drops if the sum of these is higher than the average GpuMSPF and looks close to the frame period after accounting for additional compositor overhead.

### --counter-stats tips:
*   The $$$ counters are synthesized from other data.
*   Binning Resolution is the individual tile size, while Render Resolution is the full framebuffer size.
*   These numbers can occasionally be corrupted, so if there are clearly wrong values then restart the app and try another trace.

### Troubleshooting
*   When it's not clear from the stats what is causing frame drops, we may need to query other details about what was happening in the trace around the frame drop timestamps.
