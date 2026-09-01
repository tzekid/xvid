# Native X upstream reference

X's public metadata interfaces are undocumented, so xvid records the source
revision used when its native resolver was last reviewed.

Last reviewed: 2026-08-30 UTC.

| Fact | Reviewed value |
|---|---|
| yt-dlp Twitter extractor commit | `2bbfb9972c8f514740a5fcfdff38374d08e9c15c` |
| `twitter.py` blob | `ebac006e5a69a13ce55ddd24d4a47226420a932f` |
| `twitter.py` SHA-256 | `1a11f1b902faa077ad673a853b4c29a76d43df91513380b967d605be1b18ddc3` |
| GraphQL operation | `2ICDjqPd81tulZcYrtpTuQ/TweetResultByRestId` |

Reviewed source:

- [yt-dlp twitter.py](https://github.com/yt-dlp/yt-dlp/blob/2bbfb9972c8f514740a5fcfdff38374d08e9c15c/yt_dlp/extractor/twitter.py)
- [yt-dlp JavaScript number conversion](https://github.com/yt-dlp/yt-dlp/blob/2bbfb9972c8f514740a5fcfdff38374d08e9c15c/yt_dlp/jsinterp.py#L107)

Runtime destinations:

| Purpose | Destination |
|---|---|
| Guest activation | `https://api.x.com/1.1/guest/activate.json` |
| GraphQL | `https://x.com/i/api/graphql/` |
| Syndication fallback | `https://cdn.syndication.twimg.com/tweet-result` |
| Photos | `pbs.twimg.com` |
| Direct video | `video.twimg.com` |

The reviewed public web bearer is stored once in `src/x.zig`. Its reviewed
length is 104 bytes and its SHA-256 is
`11d3072e6af2d409dfc2453bc83fb1bd4bacc9db302556fa1eda60241c49e12e`.
It is intentionally absent from documentation, fixtures, logs, and operator
output.

The syndication token follows JavaScript's numeric conversion:

```text
((Number(status_id) / 1e15) * Math.PI)
  .toString(36)
  .replace(/(0+|\.)/g, "")
```

The compile-time feature map and response traversal live beside the resolver in
`src/x.zig`; duplicating those large constants here would create a second source
of truth.

`.github/workflows/x-upstream-watch.yml` runs weekly and calls
`scripts/check-x-upstream.sh`. When the reviewed upstream blob changes it opens
or refreshes one short issue with a comparison link. A human can then inspect
the diff, update the resolver and fixtures if behavior changed, run the existing
Zig tests, and verify one representative live X post before deployment.
