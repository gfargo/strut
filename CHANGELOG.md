# Changelog

## [0.38.0](https://github.com/gfargo/strut/compare/v0.37.0...v0.38.0) (2026-07-12)


### Features

* **adopt:** non-destructive adoption of hand-deployed stacks ([#368](https://github.com/gfargo/strut/issues/368)) ([46b9cb5](https://github.com/gfargo/strut/commit/46b9cb565d21896e7addf93f5595278061c3b50c))


### Bug Fixes

* **backup:** validate Neo4j .dump before restore wipes the live database ([#412](https://github.com/gfargo/strut/issues/412)) ([b361a01](https://github.com/gfargo/strut/commit/b361a0182ad58a9da23b2baff9d5a7fad6198595)), closes [#373](https://github.com/gfargo/strut/issues/373)
* **cli:** safely parse the env file instead of sourcing it ([#408](https://github.com/gfargo/strut/issues/408)) ([dd36e49](https://github.com/gfargo/strut/commit/dd36e494aa3b7674b7c2516b738dbad03b754cef)), closes [#370](https://github.com/gfargo/strut/issues/370)
* **keys:** revoke SSH keys by fingerprint, not comment field ([#411](https://github.com/gfargo/strut/issues/411)) ([dcc463b](https://github.com/gfargo/strut/commit/dcc463b2471e4d98e93be85eaa9d44dcd221f6ee)), closes [#372](https://github.com/gfargo/strut/issues/372)
* **mcp:** validate tool-call arguments before invoking strut ([#409](https://github.com/gfargo/strut/issues/409)) ([5244db9](https://github.com/gfargo/strut/commit/5244db9ff89676fcf78beb9b46bbe0bb8b44cc7f)), closes [#371](https://github.com/gfargo/strut/issues/371)

## [0.37.0](https://github.com/gfargo/strut/compare/v0.36.0...v0.37.0) (2026-07-11)


### Features

* **release:** add --backup-first for a pre-deploy database snapshot ([#365](https://github.com/gfargo/strut/issues/365)) ([7309585](https://github.com/gfargo/strut/commit/7309585c3c629c347ddbae89aa480790b285413d))


### Bug Fixes

* **release:** preview git clean -fd in dry-run instead of just describing it ([#367](https://github.com/gfargo/strut/issues/367)) ([0cb32ed](https://github.com/gfargo/strut/commit/0cb32edb9cd78f39ea8a13955cae5a05cf2e59b9))

## [0.36.0](https://github.com/gfargo/strut/compare/v0.35.2...v0.36.0) (2026-07-11)


### Features

* **history:** deploy/release/rollback audit trail ([#363](https://github.com/gfargo/strut/issues/363)) ([9efa3ab](https://github.com/gfargo/strut/commit/9efa3abb77a566c1ce9103c188c1d6d85f9c529f))
* **release:** health-gated auto-rollback on the release command ([#362](https://github.com/gfargo/strut/issues/362)) ([60ebe7b](https://github.com/gfargo/strut/commit/60ebe7ba9c9d3237243b6bc300a29296680c8581))


### Bug Fixes

* **fleet:** fail clearly when deploy_dir has no .git checkout ([#358](https://github.com/gfargo/strut/issues/358)) ([e00f142](https://github.com/gfargo/strut/commit/e00f142d15d837fbe47e1e15d8f64089cebbb8ea)), closes [#330](https://github.com/gfargo/strut/issues/330)
* **remote-init:** verify the strut binary actually works before reporting success ([#359](https://github.com/gfargo/strut/issues/359)) ([06130c9](https://github.com/gfargo/strut/commit/06130c9fd7d19e438f058916c9014e476c98e599)), closes [#356](https://github.com/gfargo/strut/issues/356)
* **secrets:** pull writes to the stack-level path, not always project root ([#360](https://github.com/gfargo/strut/issues/360)) ([735c572](https://github.com/gfargo/strut/commit/735c5727da14b30dbf7575e465e86edf1922c42e)), closes [#357](https://github.com/gfargo/strut/issues/357)

## [0.35.2](https://github.com/gfargo/strut/compare/v0.35.1...v0.35.2) (2026-07-10)


### Bug Fixes

* **tests:** close three DB/container readiness races behind flaky Integration Tests ([#354](https://github.com/gfargo/strut/issues/354)) ([e0c38e4](https://github.com/gfargo/strut/commit/e0c38e44abbae9e12f98c874b7ecc5ed5fd8440b))

## [0.35.1](https://github.com/gfargo/strut/compare/v0.35.0...v0.35.1) (2026-07-10)


### Bug Fixes

* **release:** give release-please a real token so downstream workflows fire ([#348](https://github.com/gfargo/strut/issues/348)) ([44fcbbc](https://github.com/gfargo/strut/commit/44fcbbcbfa1775fd35e0b38d842e9021599f173b))
* **utils:** validate VPS_DEPLOY_DIR for spaces; update Known Limitations ([#352](https://github.com/gfargo/strut/issues/352)) ([6eaccec](https://github.com/gfargo/strut/commit/6eaccec62a71f9c77ff0547d019e3def6f168e98))

## [0.35.0](https://github.com/gfargo/strut/compare/v0.34.0...v0.35.0) (2026-07-10)


### Features

* **skills:** install skills via agent-add for real Agent Skills support ([#346](https://github.com/gfargo/strut/issues/346)) ([f46eae8](https://github.com/gfargo/strut/commit/f46eae8ce44d21b3c4e3166a4f916740bc6024e6))


### Bug Fixes

* **blue-green:** guard the health gate with Docker's RestartCount too ([#347](https://github.com/gfargo/strut/issues/347)) ([2ae0bd7](https://github.com/gfargo/strut/commit/2ae0bd715fad7bd855c3ada7d42ecdf96a74d493))
* **mcp:** advertise tools capability and read version from VERSION ([2c4e7b8](https://github.com/gfargo/strut/commit/2c4e7b85cfd7444d9a4b7cfe1eaf05310ea40875))
* **mcp:** prepend nvm bin to PATH so npx shebang resolves correctly ([2ec9df7](https://github.com/gfargo/strut/commit/2ec9df79df9e0275eda9b5a1c127af86cd62fce4))
* **mcp:** resolve npx from nvm when lazy-loaded shells mask it ([86e0be1](https://github.com/gfargo/strut/commit/86e0be131c2dfd253cacaaface0bc821f1dc5ad2))
* **mcp:** use bare 'strut' command in MCP config when on PATH ([047aa2e](https://github.com/gfargo/strut/commit/047aa2e7a128249b7a097e2cad6722022cab2fc4))
* two real bugs behind main's red Tests workflow ([#344](https://github.com/gfargo/strut/issues/344)) ([5041327](https://github.com/gfargo/strut/commit/5041327836a2b54c8253867a71e499e753b74f9b))

## [0.34.0](https://github.com/gfargo/strut/compare/v0.33.0...v0.34.0) (2026-07-09)


### Features

* **mcp:** use agent-add for multi-editor MCP install ([28b9ac9](https://github.com/gfargo/strut/commit/28b9ac9b9b16f2ae8e535801407cc6d916c9afc9))


### Bug Fixes

* resolve CI failures (completions sync + shellcheck) ([7e57cb5](https://github.com/gfargo/strut/commit/7e57cb5b3c915351054fd8106e38fde6b353504c))
* **test:** export POSTGRES_DB for backup/restore integration test ([810c8c3](https://github.com/gfargo/strut/commit/810c8c3ce622d2da1ff2ab56101499378fc16b5c))

## [0.33.0](https://github.com/gfargo/strut/compare/v0.32.0...v0.33.0) (2026-07-08)


### Features

* **mcp:** built-in MCP server for AI agent integration ([280241c](https://github.com/gfargo/strut/commit/280241c684d842d58a8c203cbbb6bef9245f2845))
* **mcp:** built-in MCP server for AI agent integration ([e5e1626](https://github.com/gfargo/strut/commit/e5e16260c57434f366b9b07e18827f2132d1fa19)), closes [#332](https://github.com/gfargo/strut/issues/332)

## [0.32.0](https://github.com/gfargo/strut/compare/v0.31.1...v0.32.0) (2026-07-08)


### Features

* **ssl:** auto-provision Let's Encrypt certs on deploy ([c0e018a](https://github.com/gfargo/strut/commit/c0e018a19373c50e53c361ac5a7f80baa3e7aa3c))
* **ssl:** auto-provision Let's Encrypt certs on deploy ([f1e761d](https://github.com/gfargo/strut/commit/f1e761d1fab33486c4eb09448c188f619623498c)), closes [#334](https://github.com/gfargo/strut/issues/334)
* **webhook:** push-to-deploy automation ([774f90e](https://github.com/gfargo/strut/commit/774f90e56bf18931c4aef92aa829e1c3ad653b43))
* **webhook:** push-to-deploy automation (poll + serve + install) ([086580e](https://github.com/gfargo/strut/commit/086580ec671655a442313d370317d1b6e4c1e487)), closes [#331](https://github.com/gfargo/strut/issues/331)

## [0.31.1](https://github.com/gfargo/strut/compare/v0.31.0...v0.31.1) (2026-07-07)


### Bug Fixes

* **skills:** install kiro skills per Agent Skills spec ([6a98e60](https://github.com/gfargo/strut/commit/6a98e606e8ec8ba2195fb9fc8e3758476d642b51))
* **skills:** install kiro skills per Agent Skills spec ([b066612](https://github.com/gfargo/strut/commit/b066612cbacbfa4fc55f99861099cd97d8d2fb78))

## [0.31.0](https://github.com/gfargo/strut/compare/v0.30.4...v0.31.0) (2026-07-07)


### Features

* **backup:** restore --dry-run rehearsal ([fad007e](https://github.com/gfargo/strut/commit/fad007e4c99ad39963c307334671c886b69016f1))
* **backup:** restore --dry-run rehearsal + verify-after primitive ([473b42a](https://github.com/gfargo/strut/commit/473b42aef5c3e3c258324acd76e99ee3bdd180e2)), closes [#259](https://github.com/gfargo/strut/issues/259)
* **drift:** add image-digest drift detection ([d7cfd5f](https://github.com/gfargo/strut/commit/d7cfd5f21e23f4a4690daf901e702d7e963e16c0))
* **drift:** add image-digest drift detection ([14a56c4](https://github.com/gfargo/strut/commit/14a56c4f8d3c25cc31d70a01ebd8cf45bfd578a4)), closes [#258](https://github.com/gfargo/strut/issues/258)
* **fleet:** add 'strut fleet status' command ([94f807b](https://github.com/gfargo/strut/commit/94f807b687bef67c44134f8691b6a50df5d864e7)), closes [#257](https://github.com/gfargo/strut/issues/257)
* **fleet:** add strut fleet status command ([9d6415c](https://github.com/gfargo/strut/commit/9d6415cf2ee40613dd84cd19f25a9d55286e4623))


### Bug Fixes

* auto-source connection.sh from topology.sh for standalone usage ([4200021](https://github.com/gfargo/strut/commit/4200021a2bd008a5d365c13c4646fcc90bd9971c))
* **drift:** correct hashing + graceful config-only stacks ([fbb4d64](https://github.com/gfargo/strut/commit/fbb4d64cf27af75a447f5a33b80b372a75ea6c43))
* **skills:** honor positional format arg, backup before overwrite, include generic in all ([2cb5289](https://github.com/gfargo/strut/commit/2cb52893482b4e1fa5a4a8e7402d9ad3838b3985)), closes [#263](https://github.com/gfargo/strut/issues/263)
* **skills:** honor positional format, backup before overwrite, include generic in all ([64d8099](https://github.com/gfargo/strut/commit/64d8099c056220e7276f8a8ab0db93b085bd10f5))

## [0.30.4](https://github.com/gfargo/strut/compare/v0.30.3...v0.30.4) (2026-07-07)


### Bug Fixes

* resolve pre-existing CI failures (shellcheck + tests) ([923e0c1](https://github.com/gfargo/strut/commit/923e0c13037b15b5ee7735e6aa0208fd25812fa0))
* **security:** safe env parser + SSH accept-new + fleet PAT gating ([2f541f9](https://github.com/gfargo/strut/commit/2f541f939c460842a26b4749589cc444cb0ccc64)), closes [#236](https://github.com/gfargo/strut/issues/236) [#240](https://github.com/gfargo/strut/issues/240)
* **security:** safe env parser, SSH accept-new, fleet PAT gating ([e9588a2](https://github.com/gfargo/strut/commit/e9588a2c7b1f956c76a450542996730284fb1451))

## [0.30.3](https://github.com/gfargo/strut/compare/v0.30.2...v0.30.3) (2026-07-07)


### Bug Fixes

* **backup:** isolate engine failures in backup all, run offsite sync ([64db3c6](https://github.com/gfargo/strut/commit/64db3c6a3fb5c11503bdf1f2d24c28aa2b421d3f))
* **backup:** isolate engine failures in backup all, run offsite sync ([3966a34](https://github.com/gfargo/strut/commit/3966a3496abd669ceb2ffe8c7ba0970958bba2ea)), closes [#230](https://github.com/gfargo/strut/issues/230)
* **deploy:** blue-green teardown no longer destroys shared volumes ([f925af7](https://github.com/gfargo/strut/commit/f925af7ffdc6ec6f7253a2dab11231c3754c7bed))
* **deploy:** blue-green teardown no longer destroys shared volumes ([e8e2f2e](https://github.com/gfargo/strut/commit/e8e2f2ef869ff742f5fb1c62e4d8248bfc7ffdb5)), closes [#247](https://github.com/gfargo/strut/issues/247)
* **deploy:** replace eval with safe indirect expansion in required_vars ([b90f9f9](https://github.com/gfargo/strut/commit/b90f9f99ab0d0dfe684d4066421df237251f0e7b))
* **deploy:** replace eval with safe indirect expansion in required_vars check ([007672d](https://github.com/gfargo/strut/commit/007672d74d9503a06a1f1a77565477938683320b)), closes [#223](https://github.com/gfargo/strut/issues/223)
* **init:** validate --org against safe character set ([1042ff6](https://github.com/gfargo/strut/commit/1042ff67113c7a9c396e9f986dbb4d3b04a22c6d))
* **init:** validate --org against safe character set, quote on write ([5cbcb93](https://github.com/gfargo/strut/commit/5cbcb93b3f22a0829d1d16739aebf0db9ccffdac)), closes [#239](https://github.com/gfargo/strut/issues/239)
* **portability:** macOS-safe alternatives for free/timeout/nproc ([0a8f000](https://github.com/gfargo/strut/commit/0a8f000ceb802f942583b822206a671f05758297))
* **portability:** replace free/timeout/nproc with macOS-safe alternatives ([c114cd7](https://github.com/gfargo/strut/commit/c114cd78be6cff981012eb52adce6486d4b5ebe7)), closes [#241](https://github.com/gfargo/strut/issues/241)
* **secrets:** secure temp files and mask values in ci:init ([099a0e5](https://github.com/gfargo/strut/commit/099a0e5a3823e38d805798e58cd8cb44620c1163))
* **secrets:** use mktemp for temp files, mask values in ci:init output ([07822e6](https://github.com/gfargo/strut/commit/07822e63b62a4b540c39074f051ac92af332152b))

## [0.30.2](https://github.com/gfargo/strut/compare/v0.30.1...v0.30.2) (2026-07-06)


### Bug Fixes

* **anonymize:** make hash irreversible and fail-safe on statement errors ([#299](https://github.com/gfargo/strut/issues/299)) ([3e29ac3](https://github.com/gfargo/strut/commit/3e29ac316c260dc078e30120e5daa29a06544cf4))
* **backup:** route retention, verify, list, and health through BACKUP_LOCAL_DIR ([2d3b2f9](https://github.com/gfargo/strut/commit/2d3b2f956930962107b7e1afb0ac5ee968d68e23)), closes [#229](https://github.com/gfargo/strut/issues/229)
* **backup:** route retention/verify/list/health through BACKUP_LOCAL_DIR ([001c653](https://github.com/gfargo/strut/commit/001c653fbc916302f773e58c388aa0081f68a2c2))
* **backup:** verify catches truncated/empty/garbage dumps ([#269](https://github.com/gfargo/strut/issues/269)) ([7a41cf2](https://github.com/gfargo/strut/commit/7a41cf26a4db2f3748cf626de3e1dfe4f6369cee))
* **cli:** route gateway by STACK and fix host-alias lookup ([#214](https://github.com/gfargo/strut/issues/214)) ([#271](https://github.com/gfargo/strut/issues/271)) ([8b8e068](https://github.com/gfargo/strut/commit/8b8e0688cf551bb5b0e0e5c7d128360133032766))
* **deploy:** thread --force-clean to fleet_sync, scope orphan cleanup to owning project ([699c4f1](https://github.com/gfargo/strut/commit/699c4f10330c101d6b5421caa06dfe890a21dca1))
* **deploy:** thread --force-clean, scope orphan cleanup to owning project ([5e9cfc9](https://github.com/gfargo/strut/commit/5e9cfc920157717cb48f55407466c5a679ae2b19))
* **diff:** distinguish SSH fetch failure from missing remote file ([#281](https://github.com/gfargo/strut/issues/281)) ([0f1b581](https://github.com/gfargo/strut/commit/0f1b58108f193b6a9b4f4375cfb106462729a75b))
* **dry-run:** make deploy and volumes init truly side-effect-free ([#294](https://github.com/gfargo/strut/issues/294)) ([ab6789e](https://github.com/gfargo/strut/commit/ab6789e8d7c4227dad13e427f57a53fa4dc7a275))
* **gateway:** validate Caddyfile before installing, fail loud on reload ([41cb864](https://github.com/gfargo/strut/commit/41cb864dbdd3ea4c4fcd7f25f70e126cfd448b72))
* **gateway:** validate Caddyfile before installing, fail loud on reload ([827edba](https://github.com/gfargo/strut/commit/827edba28ef344ee73588b1d7669286a839fbe34))
* **init:** gitignore .rollback/ and .bluegreen state files ([897ab50](https://github.com/gfargo/strut/commit/897ab503442c68048121861c86b937ca16ccfcd9))
* **init:** gitignore .rollback/ and .bluegreen state files ([03ace46](https://github.com/gfargo/strut/commit/03ace46a4c0675167bfc4b08543160a063ddf3de))
* **keys:** verify rotation writes before committing, backup before mutating DB ([15fb36f](https://github.com/gfargo/strut/commit/15fb36f31165bbb42f2843ee2451aa9b4a6b7f94))
* **keys:** verify rotation writes before committing, backup before mutating DB ([d446969](https://github.com/gfargo/strut/commit/d446969068b88584158b3d26b3632ce1b0fb4a5d))
* **migrate:** deploy and health-gate new stack before stopping old one in cutover ([#292](https://github.com/gfargo/strut/issues/292)) ([50505b3](https://github.com/gfargo/strut/commit/50505b34b4f389e9adfabd14f8f30d954b5e30cb))
* **release:** match release-please tag format to existing v* tags ([#296](https://github.com/gfargo/strut/issues/296)) ([c526700](https://github.com/gfargo/strut/commit/c52670089089f5fdcd31fb18a0ea8fd540ab69f6))
* **rollback:** blue-green rollback actually restores + post-restore health gates ([#265](https://github.com/gfargo/strut/issues/265)) ([6d32b3b](https://github.com/gfargo/strut/commit/6d32b3bdd46080405a349eeeff8455b9b864a05f))
* **rollback:** filter snapshots by env and dispatch remotely on VPS stacks ([#291](https://github.com/gfargo/strut/issues/291)) ([7d268a6](https://github.com/gfargo/strut/commit/7d268a62c46ca52b0c5b0d80dba6168920f75224))
* **rollback:** stop cmd_rollback falling through after a missing-snapshot fail() ([7aea3b2](https://github.com/gfargo/strut/commit/7aea3b25b5761bf48d4f2279136093e85f84eabe))
* **rollback:** stop on missing snapshot, fix shadowed test stub ([709a313](https://github.com/gfargo/strut/commit/709a31364eb0a7b8c590b6314c961431c0cbbb1d))
* **scaffold:** resolve env-indirected recipe bind mounts into .gitignore ([#272](https://github.com/gfargo/strut/issues/272)) ([b899c2f](https://github.com/gfargo/strut/commit/b899c2fe420ef7f6ca0ca4da464aed965f0e8af5))
* **test:** drop stale GDrive assertion from dry-run backup-all test ([2fc75ec](https://github.com/gfargo/strut/commit/2fc75ec89fd6ce0862bec71b4bc4fe611ad9fa98))
* **test:** update stubs for merge with main's backup engine registry ([fb52bb1](https://github.com/gfargo/strut/commit/fb52bb11b111edb8395729619b7f1378a63d8892))
* **test:** use literal substring match in dispatch-sync awk parser ([9c4f22b](https://github.com/gfargo/strut/commit/9c4f22b389e231b63ec63122d461bcc1a882ace4))
* **tui:** generate command list from dispatch table, fix stack-level env resolution ([#298](https://github.com/gfargo/strut/issues/298)) ([0e93cbe](https://github.com/gfargo/strut/commit/0e93cbe5468aa6227011c113c7b5936db749b96f))
