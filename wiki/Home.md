# Welcome to the kokomga Wiki

`kokomga` is a KOReader plugin that integrates your self-hosted **Komga** server directly into your e-reader.

## Table of Contents

1. [**Installation Guide**](Installation.md) — How to deploy the plugin to your KOReader device.
2. [**Authentication & Server Setup**](Authentication.md) — Connect securely using Auto-Generated API Keys or manual credentials.
3. [**Browser & Catalog UI**](Browser-UI.md) — Layout configuration (List vs. Grid mode), pagination, and E-Ink friendly visual badges.
4. [**Downloads & Bulk Actions**](Downloads-and-Bulk-Actions.md) — File management, folder structures, cover image retrieval, and page-based downloading.
5. [**Reading Progress Synchronization**](Reading-Progress-Synchronization.md) — Native `kosync` interception, background updates, and offline caching.
6. [**Next Chapter Flow**](Next-Chapter-Flow.md) — Seamless end-of-book Transitions, next book lookups, and auto-download prompts.
7. [**Quality of Life Features**](Quality-of-Life-Features.md) — Auto Right-to-Left (RTL) layout, cover cache controls, and cache cleaning.

---

## Architecture Overview

The plugin operates asynchronously within KOReader's main UI loop:
* **`main.lua`**: Main entry point, settings manager, and event hooks.
* **`core/api.lua`**: Abstracts connection/requests to the Komga REST API.
* **`core/cache.lua`**: Handles local persistence of cover thumbnails and metadata timestamps.
* **`core/sync.lua`**: Tracks reading progress, handles next book endpoints, and manages the offline dirty state.
* **`ui/`**: E-Ink responsive UI widgets for lists, grids, and settings.
