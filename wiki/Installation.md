# Installation Guide

## Prerequisites

* **KOReader**: Installed on your device (Kobo, Kindle, PocketBook, Android, Linux, desktop, etc.).
* **Komga Server**: Running and accessible from your device's network.

---

## Step-by-Step Installation

1. **Download the Plugin**:
   Obtain the latest release or clone the repository directly. The folder name containing the source files (including `main.lua`, `_meta.lua`, `core/`, `ui/`, etc.) must be named `kokomga.koplugin`.

2. **Connect your Device**:
   Connect your e-reader or device to your computer via USB, or open a file transfer connection (SFTP/SSH/OTG).

3. **Locate the Plugins Directory**:
   Navigate to the KOReader folder on your device. The plugins folder is typically located at:
   * **Kobo / Kindle / PocketBook**: `koreader/plugins/`
   * **Android**: `Android/data/org.koreader.launcher/files/koreader/plugins/` (depending on your installation type, search for the `koreader/` directory on internal storage).

4. **Copy the Plugin**:
   Copy the entire `kokomga.koplugin` folder directly into the `koreader/plugins/` directory. 
   
   The path should look like:
   ```text
   koreader/
   └── plugins/
       └── kokomga.koplugin/
           ├── core/
           ├── ui/
           ├── main.lua
           ├── _meta.lua
           └── ...
   ```

5. **Restart KOReader**:
   Safe-eject your device, disconnect the cable, and launch/restart KOReader. The plugin will automatically be discovered and loaded during startup.

---

## Verification

To verify that the plugin has loaded successfully:
1. Tap the top of your screen to open the KOReader main menu.
2. Navigate to the **Search Tab** (magnifying glass icon).
3. Look for the menu item labeled **`kokomga`**. If it is present, the installation was successful!
