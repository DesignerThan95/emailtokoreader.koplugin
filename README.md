# Email to KOReader (Streaming Architecture Fork)

Automatically download book attachments from your email directly to your KOReader device.

> **Note on this fork:** This version features a completely rebuilt, embedded-safe streaming IMAP parser designed specifically for low-memory e-ink devices like the Kindle Paperwhite. 

## 🚀 The Streaming Refactor
The original version of this plugin processed emails by loading the entire payload into memory and running heavy regex scans, which could cause watchdog freezes and crashes on 800MHz e-ink hardware when downloading large (5MB+) EPUBs. 

This fork introduces a **True Streaming Architecture**:
* **IMAP Literal Accounting:** Reads exact byte counts to prevent protocol strings from corrupting the EPUB ZIP structure.
* **Bounded Memory Usage:** Decodes Base64 payloads directly to disk in 8KB mathematically aligned chunks.
* **UI Yielding:** Cooperatively yields to the KOReader UI loop to prevent device watchdog lockups.
* **Strict RFC MIME Parsing:** Accurately isolates payloads and prevents random truncation from nested email boundaries.
* **Atomic Filesystem Writes:** Safely writes to `.tmp` files and renames them only upon successful verification.

## 📦 Installation
1. Download the latest version of this repository.
2. Place the `emailtokoreader.koplugin` folder into your KOReader `plugins` directory (usually `koreader/plugins/`).
3. Copy `config.example.lua` to `config.lua` and add your email credentials (use an App Password if using Gmail).
4. Restart KOReader.

`config.lua` is deliberately not tracked by git, so your credentials stay out of the repository.

## ⚙️ Configuration
Credentials live in `config.lua`; the download folder and the accepted file extensions can be
set from the device under **Tools > Email to KOReader**:

* **Download folder** — opens KOReader's folder picker and shows the folder currently in use.
* **File extensions** — tick the attachment types to download (`.epub`, `.acsm`, `.pdf`, `.mobi`, `.cbz`).

Both are stored in `koreader/settings/emailtokoreader.lua`, outside the plugin folder, so they
survive plugin updates. The precedence is **menu choice → `config.lua` → built-in default**, which
means the corresponding `config.lua` entries stay in effect until you change them on the device:

```lua
download_path = "/mnt/us/books/",
allowed_extensions = {"epub", "acsm"},
```

Any extension listed in `config.lua` also shows up in the **File extensions** menu, so extra types
can be added there without editing files on the device.

> **Note on `.acsm`:** these are Adobe DRM fulfillment tokens, not books. KOReader cannot open them —
> download them into a folder your device's own Adobe-enabled reader can see, and fulfill them there.

## 📶 Wi-Fi
If the device is offline when you check the inbox, KOReader's usual "turn on Wi-Fi?" handling kicks
in instead of a name-resolution error, and the inbox check resumes by itself once the device is
online. Whether you get a prompt or Wi-Fi is enabled silently follows your setting under
**Network > Action when Wi-Fi is off**.

## ⚡ Gestures & profiles
"Check Inbox" is registered as a dispatcher action (*Email to KOReader: check inbox*), so it can be
bound to a gesture or key under **Taps and gestures**, or added to a profile or QuickMenu, instead of
going through the menu each time.

## 📖 Usage & Filename Requirements
Because KOReader's internal library scanner relies on standard naming conventions to extract metadata, **your EPUB attachments must be named precisely**.

* **Format:** `Book Title - Author Name.epub`
* **Valid Example:** `The Martian - Andy Weir.epub`
* **Invalid Example:** `The-Martian-Andy-Weir.epub` *(Dashes instead of spaces will cause KOReader to fail to read the EPUB format!)*

To trigger a download, simply open KOReader's top menu, navigate to **Tools > Email to KOReader**, and tap **Check Inbox**.