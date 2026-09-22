# OwnTone 29.3 patches

All three patches in this directory apply to the OwnTone 29.3 source tree.

`macos-monotonic-player-timer.patch`

It replaces the macOS `setitimer`/`SIGALRM` player fallback with a libevent
timeout whose missed 10 ms ticks are recovered from an absolute
`CLOCK_MONOTONIC` deadline. Linux `timerfd` and platforms with POSIX
`timer_getoverrun` are unchanged.

`chromecast-4s-playback-offset.patch`

It extends the JSON output offset validation to ±4,000 ms and grows the
Chromecast RTP history from six to ten seconds. The larger history is required
for the managed four-second common start buffer plus a positive four-second
Chromecast correction. Output offset changes made through the JSON API are
saved to the speaker database immediately; a save failure is returned to the
API caller instead of leaving a memory-only value. Each new Chromecast session
also logs its device name, configured offset, and effective total start delay at
info level. The app leaves AirPlay controls at ±2,000 ms. As an experimental
receiver-buffering adjustment, every Chromecast audio OFFER declares
`storeTime: 0` and `targetDelay: 0`; the unused video stream declaration also
declares `targetDelay: 0`. For diagnosis, the first receiver-reported RTCP
`target_delay_ms` value in each Chromecast session, and each subsequent change,
is logged at info level.

`rtsp-connect-failure-request-ownership.patch`

It fixes the immediate RTSP connect-failure path so a request returned to its
caller is first removed from the connection queue. Without that ownership
transfer, the caller frees the request and AirPlay session cleanup frees the
same queued request again, crashing OwnTone while an unreachable receiver is
being probed.

This patch is a derivative of OwnTone's GPL source and is distributed under
GPL-2.0-or-later. Obtain the corresponding OwnTone 29.3 source from
<https://github.com/owntone/owntone-server/releases/tag/29.3> and retain its
`COPYING` file when applying or redistributing the patch.

Apply from the OwnTone source root:

```sh
git apply --check /path/to/macos-monotonic-player-timer.patch
git apply /path/to/macos-monotonic-player-timer.patch
git apply --check /path/to/chromecast-4s-playback-offset.patch
git apply /path/to/chromecast-4s-playback-offset.patch
git apply --check /path/to/rtsp-connect-failure-request-ownership.patch
git apply /path/to/rtsp-connect-failure-request-ownership.patch
make
make install
```
