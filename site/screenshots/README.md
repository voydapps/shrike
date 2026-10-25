# Shrike interface screenshots

These are actual Shrike captures taken from a 0.2.12 development build, made on 17 October 2026 using local arm64 builds on macOS 26.5.2 in Dark appearance. Later releases, including 0.2.30, may differ in small details. Five captures use source dc95509; Browser, Compare and Contact Sheet use source a65854d. Earlier captures are not relabelled as the later build.

Sample imagery: NASA/JSC. No NASA affiliation or endorsement is implied. Three distinct Earth observations are used:

- https://images.nasa.gov/details/iss043e000030
- https://images.nasa.gov/details/iss040e030547
- https://images.nasa.gov/details/iss042e013697

The files in `full/` are the largest versions kept, and the ones the recorded hashes below describe. They contain JPEG data although their names end in `.png` (checked with `file`); browsers detect the real format, so the site's Enlarge links work, and the names are kept so the recorded hashes and links stay valid. Display PNGs are proportionately resized (hero maximum width 2400 pixels, others 1400; never enlarged), ICC-converted to sRGB, with non-color metadata removed after conversion. WebP versions use the same dimensions at quality 85. No cropping, stretching or UI compositing was applied. One retouch: in `contact-sheet.png` and its WebP twin, a stray mouse pointer and its faint halo were painted over with the flat dialog background colour (the full-size capture is untouched).

## Capture and asset identity

### batch

- Version: 0.2.12 development build
- Product source: `dc95509c2363b866c471b119edc40bba60ee5948`
- App executable SHA256: `bf147b13f78e9f8df89b93f59e8c5e243323a136a39cf7b9e4210e94d52e608f`
- Capture saved UTC: 2026-10-17T14:04:27.157660+00:00
- Timestamp meaning: filesystem saved-at after awaited native screenshot; exact screenshot acquisition time not separately recorded
- Raw pixels: 1760 × 1264; display pixels: 1400 × 1005
- `screenshots/full/batch.png`: 212111 bytes; SHA256 `0cc63bb5be3c35fcd7ed9d5a0fbeae914465b66c2c35b8e290b665408e7ac016`
- `screenshots/batch.png`: 385879 bytes; SHA256 `9a071011daa042f8f99343215e2d127017d3d8a4ccf050270a97b21e5f4c22be`
- `screenshots/batch.webp`: 60162 bytes; SHA256 `59d12357dd273d12753af0f8ab713ca22917a8373755459eecf968198bba70d9`

### browser

- Version: 0.2.12 development build
- Product source: `a65854d419185e1b1cbd07a5daa4b84543a1db7b`
- App executable SHA256: `9a409a2f7301b2701e3680158638f580031ae3cf386403b575281b073a33289a`
- Capture saved UTC: 2026-10-17T14:16:39.604Z
- Timestamp meaning: explicit UTC before awaited native screenshot and UTC after saving original returned pixels
- Raw pixels: 2402 × 1602; display pixels: 1400 × 934
- `screenshots/full/browser.png`: 509339 bytes; SHA256 `27820ea8661ace9f8eb7ca456caade898541fc39c0fb8b86d18301520009194f`
- `screenshots/browser.png`: 1021876 bytes; SHA256 `64aab4b76ff46471395d81763e8d0297806d6b8bc235f88df116a930f065522e`
- `screenshots/browser.webp`: 98444 bytes; SHA256 `434a8984ca167bb4c6d7e3404580b2276d50cd2cff6c3681d732926ad6ab6f56`

### compare

- Version: 0.2.12 development build
- Product source: `a65854d419185e1b1cbd07a5daa4b84543a1db7b`
- App executable SHA256: `9a409a2f7301b2701e3680158638f580031ae3cf386403b575281b073a33289a`
- Capture saved UTC: 2026-10-17T14:16:17.459Z
- Timestamp meaning: explicit UTC before awaited native screenshot and UTC after saving original returned pixels
- Raw pixels: 3500 × 1000; display pixels: 1400 × 400
- `screenshots/full/compare.png`: 865765 bytes; SHA256 `34ee12ff592ad0ddf0f2f3acc300c51a22f3b5c610f98d7eccda3e8f2a81911d`
- `screenshots/compare.png`: 713876 bytes; SHA256 `8cca92ae18703a0178ec0637562a97bbd476fd3dd8ac7cc77a334f7c6cf96a01`
- `screenshots/compare.webp`: 92530 bytes; SHA256 `ed0e64e30f00fde01900b7863794c142294d2c5029ed3cb61ea657da16cafbf8`

### contact-sheet

- Version: 0.2.12 development build
- Product source: `a65854d419185e1b1cbd07a5daa4b84543a1db7b`
- App executable SHA256: `9a409a2f7301b2701e3680158638f580031ae3cf386403b575281b073a33289a`
- Capture saved UTC: 2026-10-17T14:15:23.570Z
- Timestamp meaning: explicit UTC before awaited native screenshot and UTC after saving original returned pixels
- Raw pixels: 1320 × 724; display pixels: 1320 × 724
- `screenshots/full/contact-sheet.png`: 84040 bytes; SHA256 `21c8235fb3ca2b6b36956e8e4f59fc9a05ca670aac79b00b248d6d945c4cc012`
- `screenshots/contact-sheet.png`: 174341 bytes; SHA256 `d806768b85ab2d2b6b88af9fc4f54657db84c919f883023f61256e0f81c1fbad`
- `screenshots/contact-sheet.webp`: 28288 bytes; SHA256 `5c0eb5a5edb45123d1c968b74ec75642abad505d7cb51c7df1fa236ee28c6c8b`

### edit

- Version: 0.2.12 development build
- Product source: `dc95509c2363b866c471b119edc40bba60ee5948`
- App executable SHA256: `bf147b13f78e9f8df89b93f59e8c5e243323a136a39cf7b9e4210e94d52e608f`
- Capture saved UTC: 2026-10-17T14:03:41.618005+00:00
- Timestamp meaning: filesystem saved-at after awaited native screenshot; exact screenshot acquisition time not separately recorded
- Raw pixels: 3522 × 2478; display pixels: 1400 × 985
- `screenshots/full/edit.png`: 1718581 bytes; SHA256 `ce6934ed85dc66bc23781a1113ebcb9f7d3097e19596ddfb4106b65c618add69`
- `screenshots/edit.png`: 1691749 bytes; SHA256 `3248f9ced5c4e6152c8ce480f04f725274c0153c4390547f514e6d31a17d023f`
- `screenshots/edit.webp`: 216890 bytes; SHA256 `6e233355492db8ab2b15d7babf64f2a595bd60cf628546fc969b9bc7a7c91edb`

### fullscreen

- Version: 0.2.12 development build
- Product source: `dc95509c2363b866c471b119edc40bba60ee5948`
- App executable SHA256: `bf147b13f78e9f8df89b93f59e8c5e243323a136a39cf7b9e4210e94d52e608f`
- Capture saved UTC: 2026-10-17T14:03:32.756375+00:00
- Timestamp meaning: filesystem saved-at after awaited native screenshot; exact screenshot acquisition time not separately recorded
- Raw pixels: 5120 × 3414; display pixels: 1400 × 934
- `screenshots/full/fullscreen.png`: 3372905 bytes; SHA256 `dc2d38d01faab7eac4220cf2f4a38e8c0a10187ba74a3dec41c10c8572af7fb9`
- `screenshots/fullscreen.png`: 2303495 bytes; SHA256 `39319a9e14782cbd26c5ee9307e31bc2787f612edac46d05bb9053caf9895921`
- `screenshots/fullscreen.webp`: 300552 bytes; SHA256 `6ad8b8982976248674109840782710a5e26fac7f2ad5772a935f7117601efcd2`

### info-histogram

- Version: 0.2.12 development build
- Product source: `dc95509c2363b866c471b119edc40bba60ee5948`
- App executable SHA256: `bf147b13f78e9f8df89b93f59e8c5e243323a136a39cf7b9e4210e94d52e608f`
- Capture saved UTC: 2026-10-17T14:03:29.749480+00:00
- Timestamp meaning: filesystem saved-at after awaited native screenshot; exact screenshot acquisition time not separately recorded
- Raw pixels: 3522 × 2478; display pixels: 1400 × 985
- `screenshots/full/info-histogram.png`: 1814900 bytes; SHA256 `3d709e957b33f1ba35fa929f6e3719ad130730b256bf8b0f1b5227fd1401e56a`
- `screenshots/info-histogram.png`: 1858377 bytes; SHA256 `8126a5eb5e2a17e4f68a5ee8fcfebd576a4fbb1fef6045b50231071e7788aece`
- `screenshots/info-histogram.webp`: 242754 bytes; SHA256 `119f9a889a1cb5b7d31ea112b30dc0fff1d7b83cb1a0f98e3c82caed77206334`

### viewer

- Version: 0.2.12 development build
- Product source: `dc95509c2363b866c471b119edc40bba60ee5948`
- App executable SHA256: `bf147b13f78e9f8df89b93f59e8c5e243323a136a39cf7b9e4210e94d52e608f`
- Capture saved UTC: 2026-10-17T14:03:23.286709+00:00
- Timestamp meaning: filesystem saved-at after awaited native screenshot; exact screenshot acquisition time not separately recorded
- Raw pixels: 3522 × 2478; display pixels: 2400 × 1689
- `screenshots/full/viewer.png`: 2070769 bytes; SHA256 `ed77a15c598f82d12cc74b66a68caa4ba38204d78a4970f21b983cf4cdd82333`
- `screenshots/viewer.png`: 6022479 bytes; SHA256 `fb992853095e7f42148eb3a68632d977e1848a58361f5b45c4438a069cf29717`
- `screenshots/viewer.webp`: 638716 bytes; SHA256 `20d5cd58073dae37d59ca5931d1b6fe973f9235989c45f89d6237c510b7c8519`
