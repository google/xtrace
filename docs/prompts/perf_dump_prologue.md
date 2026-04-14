# xtrace --perf-dump Report

This mode captures two traces. First is with --gpu1 to get accurate GPU frame stats, surface stats and top stats. Second is with --gpu2 --counters to get detailed GPU counters, binning and tile render stats.

## How to read the data

### --top tips:
*   Watch for a nearly saturated CPU (ie: "idle cpu" below 100 or so), although keep in mind the app can not use all of the cores, so it's possible for the app cpuset to be completely saturated while idle cpu is non-zero.

### --frame-stats tips:
*   Drops and DropsPM (drops per minute) are the critical metrics - a few drops may be okay but higher drop rates can cause real discomfort in XR.
*   surfaceflinger Drops (compositor frame drops in Android XR) should be zero. Otherwise it can be caused by another process with very expensive shaders or overdraw (to confirm that, look at the --gpu2 trace --surface-stats for a "RenderMaxMS" of more than 1 or 2 ms).
*   surfaceflinger FPS should be close to the display FPS (ie: 60, 72, or 90), and is typically what each rendering process should match (except for spacewarp apps which may show as half framerate).
*   The surfaceflinger (compositor) GPU time subtracts from the app's per-frame GPU budget. The GPU cost of compositing varies depending on the app buffer content and resolution.
*   TopThread1 and TopThread2 are often the app's "main" and "render" threads. Their corresponding MSPF1 and MSPF2 can indicate whether the app is CPU bound (ie: if MSPF is close to the frame period).
*   CpuMSPF indicates total app CPU usage, which can be compared to the number of CPU cores available to the app (ie: 3-4 on Galaxy XR).
*   Typically these stats show at least 3 processes: the app, surfaceflinger and SysUI.

### --surface-stats tips:
*   For the first trace, use the surface stats for overall surface render times and surface attributes.
*   For the second --gpu2 --counters trace remember that the GpuMSPF values may be inflated due to tracing overhead, and the Bin and Render times may also be off, but are useful ballpark figures.
*   Only the second trace will have numbers for RenderMaxMS, which is important as noted above to be less than a couple ms to avoid compositor tearing.
*   Watch for interesting abnormalities in RTs (render target count, ie: 2 for color + depth), RTBPP (total bits per pixel, ie: 64 for for 32-bit color and depth).
*   Check the RenderMode for direct vs binning. A direct-mode surface is often a problem on XR because they may not be preemptible or they may be faster with tiled rendering. To force binning mode, try adding a second draw call with a single degenerate triangle.

### --counter-stats tips:
*   The $$$ counters are synthesized from other data.
*   Binning Resolution is the individual tile size, while Render Resolution is the full framebuffer size.
*   These numbers can occasionally be corrupted, so if there are clearly wrong values then restart the app and try another trace.
