# Welcome to the kokomga Wiki

`kokomga` is a highly-optimized, modular KOReader plugin designed to bridge your e-reader with your self-hosted **Komga** server. This plugin is crafted with a focus on E-Ink responsiveness, efficient data caching, robust progress synchronization, and seamless downloading workflows.

## Table of Contents

Navigate through the comprehensive guide sections below to learn how to install, configure, and get the most out of your Komga integration:

1. [**Installation Guide**](Installation.md)  
   Learn how to deploy the plugin to your KOReader device.
2. [**Authentication & Server Setup**](Authentication.md)  
   Understand how to authenticate securely with your Komga server using automated API Key generation or manual setups.
3. [**Browser & Catalog User Interface**](Browser-UI.md)  
   Explore the layout configurations (List vs. Grid mode), dynamic pagination, and catalog exploration.
4. [**Downloads & Bulk Actions**](Downloads-and-Bulk-Actions.md)  
   Learn how downloading, bulk actions (e.g., download-all on current page), and automated metadata/cover-image populating are handled.
5. [**Reading Progress Synchronization**](Reading-Progress-Synchronization.md)  
   Discover how background progress sync, native KOReader `kosync` interception, and offline queueing align your reading state with your server.
6. [**Next Chapter Flow**](Next-Chapter-Flow.md)  
   Understand the seamless end-of-book transitions, automatic next chapter fetching, and download prompt options.
7. [**Quality of Life Features**](Quality-of-Life-Features.md)  
   Learn about built-in enhancements such as Auto Right-to-Left (RTL) reading order, cover caching controls, and the "Clean Cache" utility.

---

## High-Level Architecture Overview

The plugin is designed to run asynchronously and safely within KOReader's UI loop:
* **`main.lua`**: The entry point. Handles settings loading/saving via `luasettings`, event registration, and hooks into KOReader's lifecycle.
* **`core/api.lua`**: Connects to the Komga backend, abstracting REST requests and managing basic/API-key authentication.
* **`core/cache.lua`**: Implements a caching mechanism for covers and metadata to minimize network roundtrips and power consumption on E-Ink devices.
* **`core/sync.lua`**: Handles progress synchronization (pull/push), offline dirty states, and API requests for next book navigation.
* **`ui/`**: Responsive and E-Ink friendly components tailored to standard KOReader layouts, supporting both List and Grid presentation models.
