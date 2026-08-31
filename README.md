# Mower control app

Flutter control application for the mower.

## Production endpoints

The default build uses:

```text
wss://control.fxrbindi.com
https://camera.fxrbindi.com/front/whep
```

Only the front camera is enabled in the interface.

Endpoints can be overridden at build time:

```bash
flutter build apk \
  --dart-define=ROSBRIDGE_URL=wss://control.example.com \
  --dart-define=CAMERA_BASE_URL=https://camera.example.com \
  --dart-define=GPS_FIX_TOPIC=/fix \
  --dart-define=MAPBOX_TOKEN=your-scoped-public-token
```

Keep the Mapbox token out of source control and restrict it to the required
styles/origins in Mapbox. Builds without it show a clear satellite-map setup
message instead of silently using a bundled credential.

The code can attach a Cloudflare Access service token in native Android/iOS
builds for isolated bench testing:

```bash
flutter build apk \
  --dart-define=CF_ACCESS_CLIENT_ID=... \
  --dart-define=CF_ACCESS_CLIENT_SECRET=...
```

This is not a production credential design: Dart defines are compiled into the
APK/IPA and can be extracted, and one copied token can authorize both control
and camera access until it is revoked. Production release requires user login
or short-lived, per-device revocable credentials; do not ship a long-lived
service secret in the app. Rotate any token already distributed this way.

Web builds use the Cloudflare Access browser login cookie. The WHEP client uses
a credentialed `BrowserClient`; the camera origin must return an exact allowed
origin plus credentialed CORS headers (not `*`). Browsers still cannot attach
custom Access headers to a WebSocket handshake, so control should be same
origin or use an authenticated browser-compatible proxy/session.

`GPS_FIX_TOPIC` must match the backend's `gps_fix_topic` (production default
`/fix`). The backend additionally requires fresh `/odometry/gps`, so a raw fix
alone cannot authorize navigation.

The Gazebo test graph publishes `/gps/fix`; run the app against it with:

```bash
flutter run --dart-define=GPS_FIX_TOPIC=/gps/fix
```

For LAN development, enable saved mower IPs and derive the camera URL from the
same IP:

```bash
flutter run \
  --dart-define=USE_SAVED_ROBOT_IP=true \
  --dart-define=CAMERA_BASE_URL=
```

## Validation

```bash
flutter analyze
flutter test
```
