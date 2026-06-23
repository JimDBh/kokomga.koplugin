# Changelog

All notable changes to the KOReader Komga Client Plugin will be documented in this file.

## [Unreleased]

### Added
- *Accumulating upcoming features...*

---

## [1.0.0] - 2026-06-23

### Added
- **Authentication & Network Configuration**:
  - Automatic prompts to configure Server URL and API Key upon first startup.
  - Auto-generation of API keys using temporary Username/Password entry (credentials are not stored).
  - Interactive prompts to enable Wi-Fi connection if inactive when launching the browser.
- **Optimized Menu & Navigation Integration**:
  - Integrated the kokomga entry point into KOReader's search menu under "kokomga".
  - Cleaned up obsolete standalone and non-browser menus.
  - Increased hamburger icon size for better touch targeting on e-ink devices.
- **Enhanced Browser Layouts & Filtering**:
  - Re-implemented search and browse filters as checkboxes, allowing combination filters (e.g., "unread" and "in progress" together).
  - Implemented a coverless list view option with row height optimization to maximize single-page content.
- **Progress Synchronization & Behavior**:
  - Custom intercept of KOReader's native `kosync` to bypass standard synchronization and sync progress directly with the Komga server for matched books.
  - Added a configuration toggle to automatically set the reading direction to Right-to-Left (RTL) when opening books.
- **Performance & API Updates**:
  - Removed hardcoded cap restrictions (size 50-100) on list endpoints.
  - Integrated lazy, server-side paginated loading for browsing libraries and series.
- **Plugin Localization & Standards**:
  - Created standard `_meta.lua` metadata configuration.
  - Implemented system-wide i18n support.
