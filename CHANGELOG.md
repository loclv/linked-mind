# CHANGELOG

## [Unreleased] - 2026-05-31

### Added
- Native background file watcher daemon accessible via the li watch command.
- Live UI rehydration for the Web Visualizer in index.html, enabling real-time Force-Graph updates via automatic polling without page reloads.
- Physics-coordinate preservation mechanism to prevent node jumping during graph rehydration.
- Custom glassmorphism toast notification system for real-time visualizer updates.

### Changed
- Refactored watchWorkspace to trigger an initial build at startup and execute updateGraphAndExport incrementally upon file creation, update, or deletion events.
- Updated ARCHITECTURE.md and README.md to document the file watcher and rehydration features.