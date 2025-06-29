local M = {}
local command = vim.api.nvim_create_user_command

M.config = {
  socket = "/tmp/mpvsocket",
  clipboard_cmd = "wl-copy"
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
end

return M
