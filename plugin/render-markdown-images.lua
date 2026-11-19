-- The plugin's one command: `:RenderMarkdownImages <name>`. Nothing of the plugin is loaded until it is used.
if vim.g.loaded_render_markdown_images then return end
vim.g.loaded_render_markdown_images = true

vim.api.nvim_create_user_command("RenderMarkdownImages", function(opts)
  require("render-markdown-images.command").run(opts.fargs)
end, {
  nargs = "*",
  bar = true,
  complete = function(lead, line)
    -- Only the first word after the command is a name.
    local words = vim.split(line, "%s+", { trimempty = true })
    local first = (#words == 1 and line:match "%s$") or (#words == 2 and not line:match "%s$")
    if not first then return {} end
    return require("render-markdown-images.command").complete(lead)
  end,
  desc = "render-markdown-images.nvim: toggle, enable or disable the images of every markdown buffer",
})
