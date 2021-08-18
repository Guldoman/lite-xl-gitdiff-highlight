-- mod-version:1
local core = require "core"
local config = require "core.config"
local DocView = require "core.docview"
local Doc = require "core.doc"
local common = require "core.common"
local style = require "core.style"
local gitdiff = require "plugins.gitdiff_highlight.gitdiff"

-- vscode defaults
style.gitdiff_addition = {common.color "#587c0c"}
style.gitdiff_modification = {common.color "#0c7d9d"}
style.gitdiff_deletion = {common.color "#94151b"}

style.gitdiff_width = 3

local last_doc_lines = 0

config.max_diff_size = 2

-- test diff
local current_diff = {}
local current_file = {
    name = nil,
    is_in_repo = nil
}

local diffs = {}

local function update_diff()
	local current_doc = core.active_view.doc
	if current_doc == nil or current_doc.filename == nil then return end
	current_doc = system.absolute_path(current_doc.filename)

	core.log_quiet("updating diff for " .. current_doc)

	if current_file.is_in_repo ~= true then
		local is_in_repo = process.start({"git", "ls-files", "--error-unmatch", current_doc})
		is_in_repo:wait(10)
		is_in_repo = is_in_repo:returncode()
		is_in_repo = is_in_repo == 0
		current_file.is_in_repo = is_in_repo
	end
	if not current_file.is_in_repo then
		core.log_quiet("file ".. current_doc .." is not in a git repository")
		return
  end

	local max_diff_size = system.get_file_info(current_doc).size * config.max_diff_size
	local diff_proc = process.start({"git", "diff", "HEAD", current_doc})
	diff_proc:wait(100)
	local raw_diff = diff_proc:read_stdout(max_diff_size)
	local parsed_diff = gitdiff.changed_lines(raw_diff)
	current_diff = parsed_diff
end

local function set_doc(doc_name)
	if current_diff ~= {} and current_file.name ~= nil then
	diffs[current_file.name] = {
		diff = current_diff,
		is_in_repo = current_file.is_in_repo
	}
	end
	current_file.name = doc_name
	if diffs[current_file.name] ~= nil then
		current_diff = diffs[current_file.name].diff
		current_file.is_in_repo = diffs[current_file.name].is_in_repo
	else
		current_diff = {}
		current_file.is_in_repo = nil
	end
	update_diff()
end

local function gitdiff_padding(dv)
	return style.padding.x * 1.5 + dv:get_font():get_width(#dv.doc.lines)
end

local old_docview_gutter = DocView.draw_line_gutter
local old_gutter_width = DocView.get_gutter_width
function DocView:draw_line_gutter(idx, x, y, width)
	if not current_file.is_in_repo then
		return old_docview_gutter(self, idx, x, y, width)
	end

	local gw, gpad = old_gutter_width(self)

	old_docview_gutter(self, idx, x, y, gpad and gw - gpad or gw)

	if current_diff[idx] == nil then
		return
	end

	local color = nil

	if current_diff[idx] == "addition" then
		color = style.gitdiff_addition
	elseif current_diff[idx] == "modification" then
		color = style.gitdiff_modification
	else
		color = style.gitdiff_deletion
	end

	-- add margin in between highlight and text
	x = x + gitdiff_padding(self)

	local yoffset = self:get_line_text_y_offset()
	renderer.draw_rect(x, y + yoffset, style.gitdiff_width, self:get_line_height(), color)
end

function DocView:get_gutter_width()
	if not current_file.is_in_repo then return old_gutter_width(self) end
	return old_gutter_width(self) + style.padding.x / 2
end

local old_text_change = Doc.on_text_change
function Doc:on_text_change(type)
	local line, col = self:get_selection()
	if current_diff[line] == "addition" then goto end_of_function end
	-- TODO figure out how to detect an addition
	if type == "insert" or (type == "remove" and #self.lines == last_doc_lines) then
		current_diff[line] = "modification"
	elseif type == "remove" then
		current_diff[line] = "deletion"
	end
	::end_of_function::
	last_doc_lines = #self.lines
	return old_text_change(self, type)
end

local old_docview_update = DocView.update
function DocView:update()
	local filename = self.doc.abs_filename or ""
	if current_file.name ~= filename and filename ~= "---" and core.active_view.doc == self.doc then
		set_doc(filename)
	end

	return old_docview_update(self)
end

local old_doc_save = Doc.save
function Doc:save()
	old_doc_save(self)
	update_diff()
end