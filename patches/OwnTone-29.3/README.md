# OwnTone 29.3 patches

All patches in this directory apply to the OwnTone 29.3 source tree, in file
name order.

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

`zzz-timing-drift-diagnostics.patch`

It adds logging only; no packet, reply or timing value changes. An AirPlay 1
receiver drives the timing exchange and its request carries the receiver's own
clock, so the difference against ours - and above all how that difference moves
- is the receiver's clock skew with the one-way delay cancelled out. Every two
seconds per receiver, one line reports the current offset, the change since the
session's first exchange with its average ppm, and the last interval's ppm. The
observation outlives a receiver session on purpose, so reconnecting a speaker
does not hide a clock that kept walking. Retransmit requests are summarised the
same way, at most once every five seconds per session with running totals,
because timing that walks away because packets were lost looks nothing like a
clock that walks away. This patch exists to decide which of those two a drifting
AirPlay 1 receiver is doing.

`zzzz-live-playback-offset.patch`

It lets a playback offset change reach a session that is already streaming,
instead of only the next one. `struct output_definition` gains an optional
`device_offset_set`, `player.c` calls it when a speaker's `offset_ms` is saved,
and the RAOP and AirPlay 2 backends implement it by recomputing
`offset_samples` and sending one sync packet immediately rather than waiting
for the next scheduled one. Without it, changing a speaker's delay during
playback requires tearing the session down and reconnecting, and on this
network an AirPlay 1 reconnect is not reproducible: the RTSP handshake was
measured between 0 and 9 seconds, so every reconnect re-rolls where the
receiver anchors playback.

For AirPlay 1 the sync packet type is a switch, because which one a receiver
honours for a mid-stream change is not documented. By default the offset
travels in the routine 0x80 packet, the same one sent every second, which a
receiver may slew towards or discard as an outlier. Setting
`SOUNDFERRY_RAOP_LIVE_OFFSET_REANCHOR=1` sends 0x90 instead - the packet a
receiver is told to re-anchor on - at the risk of an audible step. Both forms
log the type and position they sent, so the two can be compared against the
`zzz-timing-drift-diagnostics.patch` output in one session. AirPlay 2 keeps
0x80 unconditionally; it has been applying live offsets that way in this
project for weeks.

This patch is a derivative of OwnTone's GPL source and is distributed under
GPL-2.0-or-later. Obtain the corresponding OwnTone 29.3 source from
<https://github.com/owntone/owntone-server/releases/tag/29.3> and retain its
`COPYING` file when applying or redistributing the patch.

`zzzzzzzzzz-resume-after-flush-failure.patch`

It completes the flush accounting even when an output fails or disappears.
Automatic playback suspension can then register its buffered-input resume
callback. Explicit pause, stop, and abort cancel that recovery so a late input
callback cannot restart playback against the user's command.

Apply from the OwnTone source root:

```sh
for patch in /path/to/patches/*.patch; do
  git apply --check "$patch"
  git apply "$patch"
done
make
make install
```

The loop relies on the file name order stated at the top of this file; applying
them in any other order is not supported.
