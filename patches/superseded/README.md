# Superseded patches

Kept because they are GPL-2.0-or-later derivative works of OwnTone that were
written for this project and distributed once. Nothing here is applied by
`Scripts/build-owntone-runtime.sh`.

`owntone-29.3-rtsp-request-ownership.patch`

An earlier fix for the use-after-free that crashes OwnTone while an AirPlay 2
receiver is unreachable. It transfers ownership of the queued RTSP request in
`sequence_continue()` in `src/outputs/airplay.c`. The version in
`patches/OwnTone-29.3/rtsp-connect-failure-request-ownership.patch` replaces
it by fixing the same bug one layer down, in `src/evrtsp/rtsp.c`, so the
caller never receives a request the connection queue still owns.

Delete this directory if the older approach is not worth keeping.
