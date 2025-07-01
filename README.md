# 📼 MpvNote.nvim

English/[中文](./src/README.md)

A lightweight plugin designed for Neovim users to interact with the mpv media player, allowing you to record and replay video timestamps. Ideal for clip notes, course annotations, segment tagging, and more.

# ✨ Features

📋 Copy Timestamp: Get the current playback path and timestamp from mpv, then copy it to the clipboard in a standard format.

📝 Paste Timestamp: Insert the timestamp as a new line into the current file.

🎬 Open Timestamp: Click on a timestamp to directly launch mpv and jump to that segment.

# 🧩 Timestamp Format

The plugin uses a unified timestamp format:

```
["/path/to/video.mp4" ; 192.360]
```

The first field is the video path

The second field is the time (in seconds), precise to three decimal places

# 🚀 Usage

1. Start mpv with IPC socket control enabled

`mpv --input-ipc-server=/path/to/your/socket_file "/path/to/your/video"`

The default `socket_file` is `/tmp/mpvsocket`.

2. Configure the plugin

Using Lazy.nvim

```lua
return {
  "SilverofLight/MpvNote.nvim",
  lazy = true,
  cmd = { "MpvCopyStamp", "MpvPasteStamp", "MpvOpenStamp", "MpvHover" },
  dependencies = "folke/snacks.nvim", -- optional
  opts = {
    socket = "/tmp/mpvsocket", -- your socket file
    clipboard_cmd = "wl-copy", -- your clipboard tool command
    width = nil,
    height = nil, -- MpvHover's size
  },

  -- set your keybindings below
  vim.keymap.set("n", "<leader>mn", "<cmd>MpvCopyStamp<CR>", { desc = "Copy Mpv Note" }),
  vim.keymap.set("n", "<leader>mp", "<cmd>MpvPasteStamp<CR>", { desc = "Paste Mpv Note" }),
  vim.keymap.set("n", "<leader>mo", "<cmd>MpvOpenStamp<CR>", { desc = "Open Mpv Note" })
}
```

3. Available Commands

`:MpvCopyStamp`

Get the current timestamp from mpv and copy it to the clipboard.

`:MpvPasteStamp`

Get the timestamp and insert it as a new line below the current line.

`:MpvOpenStamp`

If the cursor is on a properly formatted timestamp, this command will trigger mpv to play the corresponding segment.

If mpv is not running, it will be automatically launched in the background and jump to the timestamp.

`:MpvHover`

Extract current frame with ffmpeg and display with Snacks.nvim.

`:MpvTogglePause`

Just toggle pause/play

# 🛠 Requirements

Make sure the following tools are available:

mpv (with --input-ipc-server enabled)

socat (for socket communication)

A clipboard tool (like wl-copy, pbcopy, etc.)

ffmpeg (optional, for MpvHover)

folke/snacks.nvim -> image (optional, for MpvHover)

The plugin uses the JSON IPC protocol. Ensure your mpv version supports it.

# 📌 Example Workflow

![gif](./src/mpvNote.gif)

Run `:MpvCopyStamp` at the segment you want to mark

Paste it into your markdown/notes using `:MpvPasteStamp`

Move the cursor to any timestamp line and replay the clip using `:MpvOpenStamp`

# 📚 Roadmap

Support for multi-socket / multi-instance management

# 📄 License

MIT License
