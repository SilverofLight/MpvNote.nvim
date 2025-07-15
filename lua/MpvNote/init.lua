local M = {}
local command = vim.api.nvim_create_user_command

-- default configration
M.config = {
  socket = "/tmp/mpvsocket", -- default socket path for mpv IPC
  clipboard_cmd = "wl-copy", -- default clipboard comman (wayland)
  width = nil,               -- default hover image width
  height = nil,              -- default hover image height
}

-- execute command in mpv via socket
function M.mpv_command(cmd_data)
  local json_cmd = vim.fn.json_encode(cmd_data)
  local cmd = string.format('echo %q | socat - %s', json_cmd, M.config.socket)
  return vim.fn.system(cmd)
end

-- wait for mpv socket to become available
local function wait_for_mpv_socket(timeout)
  local socket = M.config.socket
  local wait_time = 0
  local interval = 0.1
  local max_time = timeout or 3

  while wait_time < max_time do
    -- ping
    local result = M.mpv_command({ command = { "get_property", "time-pos" } })
    if result and not result:match("Connection refused") then
      return true
    end
    vim.cmd(interval .. "sleep")
    wait_time = wait_time + interval
  end

  return false
end

-- start mpv instance with specified media file
local function start_mpv(path)
  local socket = M.config.socket
  local cmd = string.format("mpv --input-ipc-server=%s \"%s\" > /dev/null 2>&1 &", socket, path)
  os.execute(cmd)
  -- wait for socket to become available
  return wait_for_mpv_socket(3)
end

-- extract data from mpv JSON response
local function extract_data(response)
  local ok, parsed = pcall(vim.fn.json_decode, response)
  if not ok then
    vim.notify("JSON extract failed: " .. response, vim.log.levels.ERROR)
    return nil
  end

  return parsed.data
end

-- get current playback timestamp and path from mpv
local function get_timestamp()
  local time_result = M.mpv_command({ command = { "get_property", "time-pos" }, log = false })
  local path_result = M.mpv_command({ command = { "get_property", "path" }, log = false })

  if time_result:match("Connection refused") or path_result:match("Connection refused") then
    vim.notify("mpv server not running", vim.log.levels.WARN)
    return nil
  end

  local time = extract_data(time_result)
  local path = extract_data(path_result)

  if path then
    local home_dir = os.getenv("HOME")
    if home_dir and path:sub(1, #home_dir) == home_dir then
      path = "~" .. path:sub(#home_dir + 1)
    end
  end

  return {
    time = time,
    path = path
  }
end

-- parse timestamp line in format: ["path" ; time]]
local function parse_stamp_line(line)
  local path, time = line:match('%["(.-)"%s*;%s*(%d+%.?%d*)%]')
  if not path or not time then
    vim.notify("format not matched: [\"path\" ; time]", vim.log.levels.WARN)
    return nil, nil
  end

  -- dicode ~ to HOME
  if path and path:sub(1, 1) == "~" then
    local home = os.getenv("HOME")
    if home then
      path = home .. path:sub(2)
    end
  end

  -- ensure file exists
  if not (vim.loop.fs_stat(path) and vim.loop.fs_stat(path).type == "file") then
    vim.notify("file not found: " .. path, vim.log.levels.ERROR)
    return nil, nil
  end

  return path, tonumber(time)
end

-- open media at timestamp form current line
local function open_temp()
  local path, time = parse_stamp_line(vim.api.nvim_get_current_line())

  if not path or not time then
    vim.notify("format not matched: [\"path\" ; time]", vim.log.levels.WARN)
    return
  end

  local socket = M.config.socket

  -- ensure the socket exists
  local socket_stat = vim.loop.fs_stat(socket)

  if not (socket_stat and socket_stat.type == "socket") then
    vim.notify("mpv socket not exists, creating a new one", vim.log.levels.WARN)
    if not start_mpv(path) then return end
  else
    local result = M.mpv_command({ command = { "loadfile", path } })
    if result:match("Connection refused") then
      vim.notify("mpv server not running, opening a new one", vim.log.levels.WARN)
      if not start_mpv(path) then return end
    end
  end

  M.mpv_command({ command = { "set_property", "pause", true } })
  M.mpv_command({ command = { "seek", time, "absolute" } })
  M.mpv_command({ command = { "set_property", "pause", false } })

  vim.notify(string.format("Opening: %s @ %s", path, time), vim.log.levels.INFO)
end

-- get image dimensions using ffprobe
local function get_image_size(path)
  local cmd = string.format(
    "ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 %q",
    path
  )
  local output = vim.fn.system(cmd)
  local width, height = output:match("(%d+)x(%d+)")
  if width and height then
    return tonumber(width), tonumber(height)
  else
    return nil, nil
  end
end

-- show media snapshot in floating window
local function MpvHover()
  local path, time = parse_stamp_line(vim.api.nvim_get_current_line())
  if not path then
    vim.notify("format not matched: [\"path\" ; time]", vim.log.levels.WARN)
    return
  end

  local seacks_ok, snacks = pcall(require, "snacks")

  if not seacks_ok then
    vim.notify("Snacks.nvim not found", vim.log.levels.ERROR)
    return
  end

  local cache_dir = vim.fn.stdpath("cache") .. "/mpvhover"
  local filename = "mpvhover_" .. tostring(os.time()) .. ".png"
  local image_path = cache_dir .. "/" .. filename

  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end

  -- generate png with ffmpeg
  local ffmpeg_cmd = string.format(
    'ffmpeg -y -ss %s -i "%s" -vframes 1 -q:v 2 "%s" 2>/dev/null',
    time, path, image_path
  )
  os.execute(ffmpeg_cmd)

  -- check png file
  local img_stat = vim.loop.fs_stat(image_path)
  if not (img_stat and img_stat.type == "file") then
    vim.notify("Failed to generate png image", vim.log.levels.ERROR)
    return
  end

  -- create floating window
  local float_buf = vim.api.nvim_create_buf(false, true)

  local opts = {
    relative = "cursor",
    row = 1,
    col = 1,
    width = 1,
    height = 1,
    focusable = false,
    style = "minimal",
    border = "rounded",
  }
  local image_width, image_height = get_image_size(image_path)

  opts.width = M.width or math.floor(image_width / 30)
  opts.height = M.height or math.floor(image_height / 60)

  local float_win = vim.api.nvim_open_win(float_buf, false, opts)

  snacks.image.placement.new(float_buf, image_path, { inline = true, ops = { 1, 0 } })
  vim.api.nvim_buf_set_option(float_buf, "modifiable", true)

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufUnload" }, {
    group = vim.api.nvim_create_augroup("MpvNoteHover", { clear = true }),
    once = true,
    callback = function()
      if float_win and vim.api.nvim_win_is_valid(float_win) then
        vim.api.nvim_win_close(float_win, { force = true })
        float_win = nil
      end
      if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
        vim.api.nvim_buf_delete(float_buf, { force = true })
        float_buf = nil
      end
      if image_path then
        os.remove(image_path)
        image_path = nil
      end
    end,
  })
end

function M.pasteImage()
  local path, time = parse_stamp_line(vim.api.nvim_get_current_line())
  if not path then
    vim.notify("format not matched: [\"path\" ; time]", vim.log.levels.WARN)
    return
  end

  local cache_dir = vim.fn.stdpath("cache") .. "/mpvhover/pasted"
  local filename = "mpvhover_" .. tostring(os.time()) .. ".png"
  local image_path = cache_dir .. "/" .. filename

  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end

  -- generate png with ffmpeg
  local ffmpeg_cmd = string.format(
    'ffmpeg -y -ss %s -i "%s" -vframes 1 -q:v 2 "%s" 2>/dev/null',
    time, path, image_path
  )
  os.execute(ffmpeg_cmd)

  -- check png file
  local img_stat = vim.loop.fs_stat(image_path)
  if not (img_stat and img_stat.type == "file") then
    vim.notify("Failed to generate png image", vim.log.levels.ERROR)
    return
  end


  local output = string.format("![](%s)", image_path)

  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(0, row, row, false, { output })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- INFO: copy stamp to clipboard
  command("MpvCopyStamp", function()
    local stamp = get_timestamp()

    if not (stamp and stamp.path and stamp.time) then
      return
    end
    local output = string.format("[\"%s\" ; %.3f]", stamp.path, stamp.time)

    local copy_cmd = string.format('echo %q | %s', output, M.config.clipboard_cmd)
    vim.fn.system(copy_cmd)

    vim.notify("MpvNote: stamp copyed", vim.log.levels.INFO)
  end, { desc = "copy mpv timestamp" })

  -- INFO: paste stamp to current file directly
  command("MpvPasteStamp", function()
    local stamp = get_timestamp()

    if not (stamp and stamp.path and stamp.time) then
      vim.notify("MpvNote: failed to get timestamp", vim.log.levels.WARN)
      return
    end
    local output = string.format("[\"%s\" ; %.3f]", stamp.path, stamp.time)

    local row = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(0, row, row, false, { output })
  end, { desc = "paste stamp at this position" })

  -- INFO: play stamps in mpv
  command("MpvOpenStamp", open_temp, { desc = "open stamped path in mpv" })

  -- INFO: display image with snacks.nvim
  command("MpvHover", MpvHover, { desc = "hover snapshot from stamp" })

  -- INFO: toggle pause/play
  command("MpvTogglePause", function()
    M.mpv_command({ command = { "cycle", "pause" } })
  end, { desc = "toggle pause/play" })

  -- INFO: paste detected image
  command("MpvPasteImage", function()
    M.pasteImage()
  end, { desc = "paste detected image" })
end

return M
