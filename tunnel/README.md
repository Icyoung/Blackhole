# blackhole-wg

`blackhole-wg` is the vendored WireGuard/tunnel library shared by the Blackhole
VPN stack.

It serves two roles:

- `horizon/daemon` links it as a Rust path dependency for the host-side
  WireGuard server.
- `voyager` packet tunnel targets consume its exported `bh_wg_*` C FFI symbols
  and public header for iOS/macOS Network Extension builds.

## Source Layout

- `src/` Rust implementation and FFI surface
- `include/blackhole_wg.h` public C header for Apple targets
- `build-apple.sh` helper script that builds release static libraries and packs
  them into an XCFramework under `target/`

## Repository Rules

- Keep the crate source in this repository; it is not an external dependency.
- Do not commit generated output from `target/`.
- Rebuild Apple artifacts from source when native target wiring changes.
