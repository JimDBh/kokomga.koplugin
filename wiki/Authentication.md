# Authentication & Server Setup

To enable communication between KOReader and your Komga server, you must authenticate. `kokomga` supports two modes of setup: **Auto-Generate API Key** (recommended) and **Manual Setup**.

---

## 1. Auto-Generate API Key (Recommended)

This method is the most secure and convenient. It uses your username and password to request a dedicated API Key from your Komga server, then saves only that API Key on your e-reader. **Your actual password is never stored on the device.**

### How it works in the code:
1. When you enter your credentials, the plugin temporarily constructs a `Basic` authentication header:
   ```lua
   -- Under the hood, your credentials are Base64 encoded:
   self.auth_header = "Basic " .. encode_base64(username .. ":" .. password)
   ```
2. The plugin makes a `POST` request to your server at `/api/v2/users/me/api-keys` with a payload of `{ comment = "KOReader Client" }`.
3. The server generates a unique API Key and sends it back.
4. The plugin saves this API Key and your Server URL to its settings file (`kokomga.lua`), then immediately clears your username/password from memory.

---

## 2. Manual Setup

If you prefer to generate an API Key manually through the Komga Web UI or if your server has restricted configurations:

1. Log into your **Komga Web UI**.
2. Navigate to **Account Settings** -> **API Keys**.
3. Create a new API Key (e.g., labeled "KOReader").
4. In KOReader, go to the **kokomga Settings Menu** and manually enter:
   * **Server URL**: The full address of your server (e.g., `http://192.168.1.100:8080` or `https://mykomga.domain.com`).
   * **API Key**: Paste the generated key string.

### Network Transmission (Headers)
Once authenticated, every request sent to your Komga server uses secure headers:
```lua
function KomgaAPI:get_headers()
    local headers = {
        ["Accept"] = "application/json",
        ["Content-Type"] = "application/json"
    }
    if self.api_key and self.api_key ~= "" then
        headers["X-API-Key"] = self.api_key -- Custom API key header
    elseif self.auth_header then
        headers["Authorization"] = self.auth_header
    end
    return headers
end
```

---

## Technical Security Notes

* **Settings File Location**: All settings, including your Server URL and API Key, are saved inside your KOReader settings directory as `kokomga.lua` (typically inside `koreader/settings/` or your system's data storage equivalent).
* **HTTPS Support**: The plugin fully supports both `http://` and `https://` servers. If you use `https://`, connections are established securely using KOReader's bundled SSL library (`ssl.https`).
