# Changelog

Notable changes to this project will be documented in this file.

## Distribution

- **Source Code and Documentation:** [GitHub Repository](https://github.com/ceveyne/draw-things-community/tree/main/Apps/gRPCServerManager)  
- **Releases:** [gRPC Server Manager Releases](https://github.com/ceveyne/draw-things-community/releases)  

---

## [0.1.3] - 2026-11-20

### Added

- **Receipt with canvas:** for Image2Image and Image to Video orders, the receipt shows the canvas image behind it, as the previews do (needs the canvas pixels in the request).
- **More accurate time left:** correct step counts for Image2Image and hires fix, and from the second run of the same kind on, the time after the last step (long for videos) is included. A model download shows its percentage.

### Changed

- **Videos are delivered one per pickup,** so several finished videos no longer end up in one long clip. No receipt is appended after a video.
- Queue Monitor: a click on a job's preview or icon brings an already open preview window to the front.

### Fixed

- **Queue Draw Things:** a text2image or text2video order with the same parameters and **another seed** is a new job now (before, three receipts led to one generation). A recognised receipt is always a pickup.

---

## [0.1.2] - 2026-11-19

### Changed

- Queue Monitor: the details overlay of a job is no longer triggered over the `…` button, and it closes when the pointer moves onto it.

### Fixed

- **Queue Draw Things:** a request whose only difference is an image that feeds the generation is a new job now: a moodboard image or its weight, the mask, the canvas image (Image2Image, edit, image to video), or a control image. Before, it was taken for a repeat of the job that was already in the queue. A moodboard or mask change always counts. The canvas image (and controls the app may make from it) count only if nothing was delivered to the client since its previous request, because the app puts the image it received last on the canvas; the canvas image also only if its pixels are sent with the request.

---

## [0.1.1] - 2026-11-18

### Changed

- **Queue Draw Things** is a new menu item and is **off by default**. With it off, the Draw Things App is served by the proxy like the `draw-things-cli`: the call passes through unchanged, runs in the foreground, and the app receives the final result like from the original gRPC server. The job still appears in the Queue Monitor, where it can be cancelled and saved. Turn it on for the experimental queuing with receipts and status images.
  - With **Queue Draw Things** off, the proxy passes the output of the original gRPC server through **1:1**.
  - It neither reads nor writes any Draw Things project file.
- The menu is regrouped: **Use Proxy**, **Set Proxy Port…**, **Queue Monitor**, and **Empty Queue…** come first; **Queue Draw Things**, **Issue Receipt**, and **Sync History** follow in their own group. **Issue Receipt** and **Sync History** are only available while **Queue Draw Things** is on.
- **Issue Receipt** is on by default (it applies with **Queue Draw Things**).

---

## [0.1.0-rc3] - 2026-11-14 Revision 1

### Added

- Initial Pre-Release.

A lightweight macOS menu bar app that starts, stops, and monitors the Draw Things gRPC server (`gRPCServerCLI-macOS`) which is provided on the [draw-things-community releases page](https://github.com/drawthingsai/draw-things-community/releases).