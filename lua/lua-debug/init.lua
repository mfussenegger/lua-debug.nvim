-- Generated from attach.lua.tl, breakpoint_hit.lua.tl, handle_message.lua.tl, init.lua.tl, initialize.lua.tl, launch.lua.tl, log_remote.lua.tl, message_loop.lua.tl, receive.lua.tl, send.lua.tl, server.lua.tl, set_breakpoints.lua.tl using ntangle.nvim
local server_messages = {}

local seq_id = 1

local nvim_server

local debug_hook_conn 

local host = "127.0.0.1"

-- for now, only accepts a single
-- connection
local client

local make_response

local make_event

local log

local sendProxyDAP

local M = {}
M.server_messages = server_messages
function make_response(request, response)
  local msg = {
    type = "response",
    seq = seq_id,
    request_seq = request.seq,
    success = true,
    command = request.command
  }
  seq_id = seq_id + 1
  return vim.tbl_extend('error', msg, response)
end

function M.launch()
  log("launch!")
  nvim_server = vim.fn.jobstart({'nvim', '--embed', '--headless'}, {rpc = true})
  
  local hook_address = vim.fn.serverstart()
  vim.fn.rpcrequest(nvim_server, 'nvim_exec_lua', [[debug_hook_conn_address = ...]], {hook_address})
  
  local server = vim.fn.rpcrequest(nvim_server, 'nvim_exec_lua', [[return require"lua-debug".start_server()]], {})
  

  return server
end

function M.wait_attach()
  local timer = vim.loop.new_timer()
  timer:start(0, 100, vim.schedule_wrap(function()
    local has_attach = false
    for _,msg in ipairs(server_messages) do
      if msg.command == "attach" then
        has_attach = true
      end
    end
    if not has_attach then return end
    log("Attach!")
    timer:close()

    local handlers = {}
    local breakpoints = {}
    
    function handlers.attach(msg)
      log("Attached!")
    end
    
    function handlers.setBreakpoints(request)
      local args = request.arguments
      local results_bps = {}
      
      for _, bp in ipairs(args.breakpoints) do
        breakpoints[bp.line] = breakpoints[bp.line] or {}
        local line_bps = breakpoints[bp.line]
        line_bps[args.source.path] = true
        table.insert(results_bps, { verified = true })
        log("Set breakpoint at line " .. bp.line .. " in " .. args.source.path)
      end
      
      sendProxyDAP(make_response(request, {
        body = {
          breakpoints = results_bps
        }
      }))
      
    end
    
    debug.sethook(function(event, line)
      local i = 1
      while i <= #server_messages do
        local msg = server_messages[i]
        local f = handlers[msg.command]
        if f then
          f(msg)
        else
          log("Could not handle " .. msg.command)
        end
        i = i + 1
      end
      
      server_messages = {}
      
    
      local bps = breakpoints[line]
      if bps then
        local info = debug.getinfo(2, "S")
        local source_path = info.source
        log(source_path)
        
        if source_path:sub(1, 1) == "@" then
          local path = source_path:sub(2)
          path = vim.fn.fnamemodify(path, ":p")
          if bps[path] then
            log("Break!")
          end
        end
      end
      
    end, "l")
    
  end))
end
function log(str)
  if debug_output then
    table.insert(debug_output, tostring(str))
  else
    print(str)
  end
end
function M.sendDAP(msg)
  local succ, encoded = pcall(vim.fn.json_encode, msg)
  
  if succ then
    local bin_msg = "Content-Length: " .. string.len(encoded) .. "\r\n\r\n" .. encoded
    
    client:write(bin_msg)
  else
    log(encoded)
  end
end

function M.start_server()
  local server = vim.loop.new_tcp()
  
  server:bind(host, 0)
  
  server:listen(128, function(err)
    local sock = vim.loop.new_tcp()
    server:accept(sock)
    local tcp_data = ""
    
    function make_event(event)
      local msg = {
        type = "event",
        seq = seq_id,
        event = event,
      }
      seq_id = seq_id + 1
      return msg
    end
    
  
    client = sock
  
    local function read_body(length)
      while string.len(tcp_data) < length do
        coroutine.yield()
      end
    
      local body = string.sub(tcp_data, 1, length)
      local succ, decoded = pcall(vim.fn.json_decode, body)
      
      tcp_data = string.sub(tcp_data, length+1)
      
    
      return decoded
    end
    
    local function read_header()
      while not string.find(tcp_data, "\r\n\r\n") do
        coroutine.yield()
      end
      local content_length = string.match(tcp_data, "^Content%-Length: (%d+)")
      
      local _, sep = string.find(tcp_data, "\r\n\r\n")
      tcp_data = string.sub(tcp_data, sep+1)
      
    
      return {
        content_length = tonumber(content_length),
      }
    end
    
    local dap_read = coroutine.create(function()
      local msg
      do
        local len = read_header()
        msg = read_body(len.content_length)
      end
      
      M.sendDAP(make_response(msg, {
        body = {}
      }))
      
      M.sendDAP(make_event('initialized'))
    
      while true do
        local msg
        do
          local len = read_header()
          msg = read_body(len.content_length)
        end
        
        if debug_hook_conn then
          vim.fn.rpcnotify(debug_hook_conn, "nvim_exec_lua", [[table.insert(require"lua-debug".server_messages, ...)]], {msg})
        end
        
      end
    end)
    
    sock:read_start(vim.schedule_wrap(function(err, chunk)
      if chunk then
        tcp_data = tcp_data .. chunk
        coroutine.resume(dap_read)
        
      else
        sock:shutdown()
        sock:close()
      end
    end))
    
  end)
  
  log("Server started on " .. server:getsockname().port)
  
  if debug_hook_conn_address then
    debug_hook_conn = vim.fn.sockconnect("pipe", debug_hook_conn_address, {rpc = true})
  end
  

  return {
    host = host,
    port = server:getsockname().port
  }
end

function M.test()
  return 2
end

function sendProxyDAP(data)
  vim.fn.rpcnotify(nvim_server, 'nvim_exec_lua', [[require"lua-debug".sendDAP(...)]], {data})
end

return M