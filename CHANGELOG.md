# Changelog

## [0.2.0](https://github.com/seuros/shuttlebay/compare/v0.1.4...v0.2.0) (2026-10-17)


### Features

* drop the middleware Mothership does, edge cache helpers ([718aa6f](https://github.com/seuros/shuttlebay/commit/718aa6f39f9a37c26a6b679d97eed1a9e7423a7d))
* Process.warmup before serving, fork_from bays ([064eeac](https://github.com/seuros/shuttlebay/commit/064eeac54079c5434e1f3e998f1d380e42dd9c1c))


### Bug Fixes

* each fork worker serves one bay, as that bay ([6a7ea9d](https://github.com/seuros/shuttlebay/commit/6a7ea9d65d23ebe5bd68c41c6c8641b8afba06d8))


### Performance Improvements

* **engine:** interned env keys, shared values, whole replies in one write ([8a6b557](https://github.com/seuros/shuttlebay/commit/8a6b55733ba131464f57476de92a3e41dab77b7e))

## [0.1.4](https://github.com/seuros/shuttlebay/compare/v0.1.3...v0.1.4) (2026-10-07)


### Bug Fixes

* **release:** pack linux platform gems without compiling for the host ([155c6c5](https://github.com/seuros/shuttlebay/commit/155c6c526db8f0f6f248472c3b86cd52282302ad))

## [0.1.3](https://github.com/seuros/shuttlebay/compare/v0.1.2...v0.1.3) (2026-10-07)


### Bug Fixes

* **release:** build platform gems with the host's stable Rust (rb-sys images ship 1.98) ([a301118](https://github.com/seuros/shuttlebay/commit/a3011183061a6c621d841070c32e2d171a174cdd))

## [0.1.2](https://github.com/seuros/shuttlebay/compare/v0.1.1...v0.1.2) (2026-10-07)


### Bug Fixes

* **release:** let rb-sys-dock pick the cross Ruby instead of forcing 4.0.0 ([0dd6dbe](https://github.com/seuros/shuttlebay/commit/0dd6dbe96e504da50fb073a1a24de2382d86f37b))

## [0.1.1](https://github.com/seuros/shuttlebay/compare/v0.1.0...v0.1.1) (2026-10-07)


### Bug Fixes

* **ci:** drop rustfmt and clippy, dictator lints the tree ([05fffa5](https://github.com/seuros/shuttlebay/commit/05fffa5996308568e5c4bf03757f154029ad6043))
