# KOReader Komga Client Plugin

This is a developer-focused, low-overhead sync & auto-download client for your **Komga Server**, enabling reading state synchronization (page tracking and completion markers) automatically as you read books on your E-Reader.

## 📂 Installation

To manually install this plugin on a KOReader emulator or E-Reader device:

1. Locate your KOReader installation folder:
   - **Android**: `<internal storage>/koreader/plugins/`
   - **Kobo/Kindle**: `/.koreader/plugins/`
   - **Linux/Steam Deck/Desktop Emulator**: `/usr/lib/koreader/plugins/` or `~/.config/koreader/plugins/`

2. Create a folder named `komga.koplugin` inside the `/plugins/` directory:
   ```bash
   koreader/plugins/komga.koplugin/
   ```

3. Copy the following files from this repository directly into that folder:
   - `main.lua`
   - `komga_api.lua`

4. Restart KOReader.

---

## ⚙️ How to Configure

1. Open KOReader's top navigation bar.
2. Go to **Search/Tools** or **Settings** > **Komga Sync**.
3. Toggle/Input:
   - **Configure Server URL**: Enter your Komga server IP (e.g. `http://192.168.1.100:8080`).
   - **Configure API Key**: Enter your Komga API Key.

---

## 🔄 Dynamic Lifecycle Flow

When you open or close any ebook/document matching the title of a series/volume on your Komga server:

- **On Access (`onReaderReady`)**: Pulls remote page progress from Komga and compares it to your local offline position. If remote state is further ahead, it prompts/jumps directly to that page.
- **On Exit (`onCloseDocument`)**: Captures the current page index and marks completion automatically to report back to your Komga user database.
