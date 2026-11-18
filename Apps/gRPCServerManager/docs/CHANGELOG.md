# Changelog

Notable changes to this project will be documented in this file.

## Distribution

- **Source Code and Documentation:** [GitHub Repository](https://github.com/ceveyne/draw-things-community/tree/main/Apps/gRPCServerManager)  

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