# Offline map-pack contract

`wtr.map-pack.v1` is the shared application's operator-controlled geographic
context format. It is a bounded public presentation input, not Tracker evidence,
a tile protocol or a route-matching source. The UI reads no map network endpoint.

## Document

The document is closed and has exactly these fields:

```json
{
  "schema": "wtr.map-pack.v1",
  "id": "stockholm-core",
  "revision": "2026-09",
  "attribution": "Example operator map data",
  "coverage": {
    "west": 17.0,
    "south": 59.0,
    "east": 19.0,
    "north": 60.0
  },
  "features": [
    {
      "class": "road",
      "points": [[59.31, 18.03], [59.36, 18.10]]
    }
  ]
}
```

`id` and `revision` are 1–64 byte ASCII tokens containing letters, digits,
periods, underscores and hyphens. `attribution` is a single valid UTF-8 line of
1–256 bytes. Coverage uses ordinary latitude and longitude bounds. A west value
greater than east declares an antimeridian-crossing rectangle; equal west and
east values are invalid.

`features` contains 1–128 lines and at most 4,096 points in total. One line has
2–256 `[latitude, longitude]` points and exactly one of the classes `boundary`,
`road` or `water`. Every point must fall inside the declared coverage. Unknown
keys, classes and schema revisions fail admission. The format has no URL, HTML,
script, style, credential, Tracker identifier or fetch instruction.

## Presentation semantics

The complete pack is admitted once by its host before the endpoint starts. A
route page projects only its bounded line work. The pack is drawn only when its
coverage contains every qualified route point on the current page; otherwise
the UI reports that complete coverage is unavailable and draws no partial
background. An absent pack is separately reported as not configured.

Map lines are clipped behind the latitude/longitude graticule and retained route.
They never change evidence coordinates, gaps, service segments, page continuity,
authorization or exports. Attribution and the admitted pack identity/revision are
visible beside the map. Exact coordinate tables remain the accessible and
authoritative alternative.

## Host admission

- The optional standalone browser uses `wtr.browser.v2` and embeds the document
  as `map_pack`. Its existing private-file policy caps the complete browser JSON
  at 64 KiB. Version-one browser documents remain valid without a pack.
- The Pi kiosk uses `wtr.browser.v3`, retaining its version-two `device_session`
  and adding `map_pack`. Versions one and two remain valid without a pack.
- The mobile host accepts the decoded document through its `:map_pack` startup
  option and passes only the admitted value to the loopback endpoint.

Map content is independent of the account-bound mobile projection cache. It
cannot grant offline authority, disclose retained locations to a map provider or
turn an incomplete cached route into a complete one.
