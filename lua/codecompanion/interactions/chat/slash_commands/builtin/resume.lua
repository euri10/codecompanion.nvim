local utils = require("codecompanion.utils")

---@class CodeCompanion.SlashCommand.Resume: CodeCompanion.SlashCommand
local SlashCommand = {}

---@param args CodeCompanion.SlashCommand
function SlashCommand.new(args)
  local self = setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })

  return self
end

---Is the slash command enabled?
---@param chat CodeCompanion.Chat
---@return boolean,string
function SlashCommand.enabled(chat)
  if not chat.acp_connection then
    return false, "The resume slash command requires an ACP connection"
  end

  if not chat.acp_connection:can_list_sessions() then
    return false, "This agent does not support listing sessions"
  end

  if not chat.acp_connection:can_load_session() then
    return false, "This agent does not support loading sessions"
  end

  return true, ""
end

---Format a session for display in the picker
---@param session table SessionInfo
---@return string
local function format_session(session)
  local parts = {}

  if session.updatedAt then
    local ts = utils.parse_iso8601(session.updatedAt)
    if ts then
      table.insert(parts, "(" .. utils.make_relative(ts) .. ")")
    end
  end

  if session.title then
    table.insert(parts, session.title)
  elseif session.cwd then
    table.insert(parts, session.cwd .. " — " .. session.sessionId)
  else
    table.insert(parts, session.sessionId)
  end

  return table.concat(parts, " ")
end

---Load the selected session into the chat buffer
---@param Chat CodeCompanion.Chat
---@param session table SessionInfo
---@return nil
local function load_session(Chat, session)
  local updates = {}
  local ok = Chat.acp_connection:load_session(session.sessionId, {
    on_session_update = function(update)
      table.insert(updates, update)
    end,
  })

  if ok then
    local acp_commands = require("codecompanion.interactions.chat.acp.commands")
    acp_commands.link_buffer_to_session(Chat.bufnr, Chat.acp_connection.session_id)

    require("codecompanion.interactions.chat.acp.render").restore_session(Chat, updates)

    if session.title then
      Chat:set_title(session.title)
    end

    utils.fire("ACPChatRestored", {
      bufnr = Chat.bufnr,
      id = Chat.id,
      session_id = Chat.acp_connection.session_id,
      title = Chat.title,
    })

    utils.notify("Resumed session: " .. (session.title or session.sessionId), vim.log.levels.INFO)
  else
    utils.notify("Failed to load session", vim.log.levels.ERROR)
  end
end

local providers = {
  ---The default provider
  ---@param SlashCommand CodeCompanion.SlashCommand
  ---@return nil
  default = function(SlashCommand)
    local Chat = SlashCommand.Chat
    local sessions = Chat.acp_connection:session_list({
      max_sessions = (SlashCommand.config.opts and SlashCommand.config.opts.max_sessions) or 500,
    })

    if #sessions == 0 then
      return utils.notify("No previous sessions found", vim.log.levels.INFO)
    end

    local choices = {}
    local session_map = {}
    for i, session in ipairs(sessions) do
      table.insert(choices, format_session(session))
      session_map[i] = session
    end

    vim.ui.select(choices, {
      prompt = "Resume Session",
      kind = "codecompanion.nvim",
    }, function(_, idx)
      if not idx then
        return
      end
      load_session(Chat, session_map[idx])
    end)
  end,

  ---The Snacks.nvim provider
  ---@param SlashCommand CodeCompanion.SlashCommand
  ---@return nil
  snacks = function(SlashCommand)
    local Chat = SlashCommand.Chat
    local sessions = Chat.acp_connection:session_list({
      max_sessions = (SlashCommand.config.opts and SlashCommand.config.opts.max_sessions) or 500,
    })

    if #sessions == 0 then
      return utils.notify("No previous sessions found", vim.log.levels.INFO)
    end

    -- Build a preview text for a session showing its conversation contents
    local function session_preview(session)
      -- If the adapter provides a history file path via _meta, read it directly
      if session._meta and session._meta.historyJsonlPath then
        local path = session._meta.historyJsonlPath
        local ok, raw = pcall(function()
          local f = io.open(path, "r")
          if not f then
            return nil, "io.open returned nil"
          end
          local content = f:read("*a")
          f:close()
          return content
        end)
        if ok and raw then
          local lines = {}
          local line_count = 0
          for line in raw:gmatch("[^\n]+") do
            line_count = line_count + 1
            if line_count > 120 then
              table.insert(lines, "... (truncated)")
              break
            end
            local ok2, entry = pcall(vim.json.decode, line)
            if ok2 and entry and entry.content then
              local role = entry.role or "unknown"
              local content = entry.content
              -- Truncate tool results and long content
              if role == "tool" and #content > 500 then
                content = content:sub(1, 500) .. "..."
              elseif #content > 2000 then
                content = content:sub(1, 2000) .. "..."
              end
              table.insert(lines, role:upper())
              table.insert(lines, content)
              table.insert(lines, "")
            end
          end
          if #lines > 0 then
            return table.concat(lines, "\n")
          end
        end
      end

      -- Fallback: metadata-only preview
      local lines = {}
      if session.title then
        table.insert(lines, "Title: " .. session.title)
      end
      table.insert(lines, "ID: " .. session.sessionId)
      if session.cwd then
        table.insert(lines, "CWD: " .. session.cwd)
      end
      if session.updatedAt then
        table.insert(lines, "Updated: " .. session.updatedAt)
      end
      if session.summary then
        table.insert(lines, "")
        table.insert(lines, session.summary)
      end
      return table.concat(lines, "\n")
    end

    local items = {}
    for _, session in ipairs(sessions) do
      table.insert(items, {
        display = format_session(session),
        preview = { text = session_preview(session) },
        session = session,
      })
    end

    local snacks = require("codecompanion.providers.slash_commands.snacks")
    snacks = snacks.new({
      title = "Resume Session: ",
      output = function(selection)
        load_session(Chat, selection.session)
      end,
    })

    snacks.provider.picker.pick({
      title = "Resume Session",
      items = items,
      prompt = snacks.title,
      format = function(item, _)
        return { { item.display } }
      end,
      preview = "preview",
      confirm = snacks:display(),
      main = { file = false, float = true },
    })
  end,
}

---Execute the slash command
---@param SlashCommands CodeCompanion.SlashCommands
---@return nil
function SlashCommand:execute(SlashCommands)
  local Chat = self.Chat

  if Chat.cycle > 1 then
    return utils.notify("The /resume command must be called before submitting any messages", vim.log.levels.WARN)
  end

  if not Chat.acp_connection then
    return utils.notify("No ACP connection available", vim.log.levels.WARN)
  end

  return SlashCommands:set_provider(self, providers)
end

return SlashCommand
