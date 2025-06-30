local M = {}
local command = vim.api.nvim_create_user_command

M.config = {
  socket = "/tmp/mpvsocket",
  clipboard_cmd = "wl-copy",
  width = nil,
  height = nil,
}

function M.get_timestamp()
  local time_json_cmd = '{ "command": ["get_property", "time-pos"], "log": false }'
  local path_json_cmd = '{ "command": ["get_property", "path"], "log": false }'
  local socket = M.config.socket

  local get_time_cmd = string.format('echo %q | socat - %s', time_json_cmd, socket)
  local get_path_cmd = string.format('echo %q | socat - %s', path_json_cmd, socket)

  local time_result_json = vim.fn.system(get_time_cmd)
  local path_result_json = vim.fn.system(get_path_cmd)

  if time_result_json:match("Connection refused") or path_result_json:match("Connection refused") then
    vim.notify("mpv server not running", vim.log.levels.WARN)
    return nil
  end

  local stamp = { time = time_result_json, path = path_result_json }

  local path = M.extract_data(path_result_json)
  if path then
    stamp.path = path
  end

  local time = M.extract_data(time_result_json)
  if time then
    stamp.time = time
  end

  return stamp
end

function M.extract_data(response)
  local ok, parsed = pcall(vim.fn.json_decode, response)
  if not ok then
    vim.notify("JSON extract failed: " .. response, vim.log.levels.ERROR)
    return nil
  end

  return parsed.data
end

local function wait_for_mpv_socket(socket, timeout_sec)
  local ping_cmd = string.format(
    'echo \'{"command": ["get_property", "time-pos"]}\' | socat - %s',
    socket
  )

  local wait_time = 0
  local interval = 0.1
  local max_time = timeout_sec or 3

  while wait_time < max_time do
    local result = vim.fn.system(ping_cmd)
    if result and result:match('"error"%s*:%s*"success"') then
      return true
    end
    local sleep_cmd = interval .. "sleep"
    vim.cmd(sleep_cmd)
    wait_time = wait_time + interval
  end

  return false
end

function M.open_temp()
  local line = vim.api.nvim_get_current_line()

  -- match format ["path" ; time]
  local path, time = line:match('%["(.-)"%s*;%s*(%d+%.?%d*)%]')

  if not path or not time then
    vim.notify("format not matched: [\"path\" ; time]", vim.log.levels.WARN)
    return
  end

  -- check if file exists
  local file_stat = vim.loop.fs_stat(path)
  if not (file_stat and file_stat.type == "file") then
    vim.notify("file not found: " .. path, vim.log.levels.ERROR)
    return
  end

  local socket = M.config.socket

  -- command
  local load_cmd = string.format(
    'echo \'{"command": ["loadfile", %q]}\' | socat - %s',
    path, socket
  )
  local seek_cmd = string.format(
    'echo \'{"command": ["seek", %s, "absolute"]}\' | socat - %s',
    time, socket
  )
  local pause_cmd = string.format(
    'echo \'{"command": ["set_property", "pause", true]}\' | socat - %s > /dev/null 2>&1',
    socket
  )
  local resume_cmd = string.format(
    'echo \'{"command": ["set_property", "pause", false]}\' | socat - %s > /dev/null 2>&1',
    socket
  )

  -- ensure the socket exists
  local stat = vim.loop.fs_stat(socket)
  if not (stat and stat.type == "socket") then
    vim.notify("mpv socket not exists, creating a new one", vim.log.levels.WARN)
    local new_mpv_cmd = "mpv --input-ipc-server=" .. socket .. " \"" .. path .. "\" > /dev/null 2>&1 &"
    os.execute(new_mpv_cmd)
    if not wait_for_mpv_socket(socket, 3) then
      vim.notify("MpvNote: Failed to create mpv socket", vim.log.levels.ERROR)
      return
    end
  else
    local load = vim.fn.system(load_cmd)

    if load:match("Connection refused") then
      vim.notify("mpv server not running, opening a new one", vim.log.levels.WARN)
      local new_mpv_cmd = "mpv --input-ipc-server=" .. socket .. " \"" .. path .. "\" > /dev/null 2>&1 &"
      os.execute(new_mpv_cmd)
      if not wait_for_mpv_socket(socket, 3) then
        vim.notify("MpvNote: Failed to open mpv", vim.log.levels.ERROR)
        return
      end
    end
  end

  vim.fn.system(pause_cmd)
  vim.fn.system(seek_cmd)
  vim.fn.system(resume_cmd)

  vim.notify(string.format("Opening: %s @ %s", path, time), vim.log.levels.INFO)
end

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

function M.MpvHover()
  local line = vim.api.nvim_get_current_line()

  -- match format ["path" ; time]
  local path, time = line:match('%["(.-)"%s*;%s*(%d+%.?%d*)%]')

  if not path or not time then
    vim.notify("format not matched: [\"path\" ; time]", vim.log.levels.WARN)
    return
  end

  -- check if file exists
  local file_stat = vim.loop.fs_stat(path)
  if not (file_stat and file_stat.type == "file") then
    vim.notify("file not found: " .. path, vim.log.levels.ERROR)
    return
  end

  local seacks_ok, snacks = pcall(require, "snacks")

  if not seacks_ok then
    vim.notify("Snacks.nvim not found", vim.log.levels.ERROR)
    return
  end

  local cache_dir = vim.fn.stdpath("cache")
  local filename = "mpvhover_" .. tostring(os.time()) .. ".png"
  local image_path = cache_dir .. "/" .. filename

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

  snacks.image.placement.new(float_buf, image_path, { inline = true, ops = {1, 0} })
  vim.api.nvim_buf_set_option(float_buf, "modifiable", true)

  vim.api.nvim_create_autocmd("CursorMoved", {
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

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- INFO: copy stamp to clipboard
  command("MpvCopyStamp", function()
    local stamp = M.get_timestamp()

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
    local stamp = M.get_timestamp()

    if not (stamp and stamp.path and stamp.time) then
      vim.notify("MpvNote: failed to get timestamp", vim.log.levels.WARN)
      return
    end
    local output = string.format("[\"%s\" ; %.3f]", stamp.path, stamp.time)

    local row = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(0, row, row, false, { output })
  end, { desc = "paste stamp at this position" })

  -- INFO: play stamps in mpv
  command("MpvOpenStamp", M.open_temp, { desc = "open stamped path in mpv" })

  -- INFO: display image with snacks.nvim
  command("MpvHover", M.MpvHover, { desc = "hover snapshot from stamp" })
end

return M
