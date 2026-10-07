--[[
    Copyright © 2026 @APHONlC. All rights reserved.

    No copying, modification, distribution, or sale without prior written permission.
    AI/ML ingestion and training are strictly prohibited (TDM opt-out).

    See LICENSE.md for full terms and maintenance exceptions.
]]

local APHP = APHProfilerCore

local PARSE_JOB = "APHProfiler_Parse"
local NS_PER_MS = 1000000
local MAX_CALLER_HOPS = 64
local TIMELINE_BUCKETS = 600
local CONSOLE_TIMELINE_BUCKETS = 120
local MIN_TIMELINE_OWNERS = 15
APHP.TIMELINE_OTHER = "Other"
local MAX_STACK = 6
local WORST_FRAMES_KEPT = 3

local ESOUI_OWNER = APHP.L("GAME_UI")
local GC_OWNER = APHP.L("LUA_GARBAGE_COLLECTOR")

local state = {
	running = false,
	parsing = false,
	frame = 0,
	frames = 0,
	started_at = 0,
	elapsed_ms = 0,
	owners = nil,
	funcs = nil,
	timeline = nil,
}

local path_owner = {}
local addon_roots = {}
local library_names = {}

local duration = {}
local caller = {}
local child_time = {}
local owner_of = {}
local data_index = {}
local data_type = {}
local func_key = {}

function APHP.IsRunning() return state.running end

function APHP.GetRecordingElapsedMs()
	if not state.running then return nil end
	return GetGameTimeMilliseconds() - state.started_at
end
function APHP.IsParsing() return state.parsing end

local function BuildAddonIndex()
	addon_roots = {}
	library_names = {}
	path_owner = {}

	local am = GetAddOnManager()
	if not am then return end
	for index = 1, am:GetNumAddOns() do
		local name, _, _, _, _, _, _, is_library = am:GetAddOnInfo(index)
		local root = am:GetAddOnRootDirectoryPath(index)
		if name and root and root ~= "" then
			addon_roots[#addon_roots + 1] = { prefix = string.upper(root), name = name }
			if is_library then library_names[name] = true end
		end
	end
end

local function OwnerForPath(path)
	if not path or path == "" then return nil end
	local cached = path_owner[path]
	if cached ~= nil then return cached or nil end

	local upper = string.upper(path)
	local owner
	for index = 1, #addon_roots do
		local entry = addon_roots[index]
		if string.find(upper, entry.prefix, 1, true) then
			owner = entry.name
			break
		end
	end
	if not owner and string.find(upper, "ESOUI", 1, true) then owner = ESOUI_OWNER end

	path_owner[path] = owner or false
	return owner
end

local function DirectOwner(dataIndex, dataType)
	if dataType == SCRIPT_PROFILER_RECORD_DATA_TYPE_CLOSURE then
		local _, path = GetScriptProfilerClosureInfo(dataIndex)
		return OwnerForPath(path)
	end
	if dataType == SCRIPT_PROFILER_RECORD_DATA_TYPE_GARBAGE_COLLECTION then
		return GC_OWNER
	end
	return nil
end

local function OwnerAbove(recordIndex, count)
	local index = caller[recordIndex]
	local hops = 0
	while index and index >= 1 and index <= count and hops < MAX_CALLER_HOPS do
		local owner = owner_of[index]
		if owner then return owner end
		index = caller[index]
		hops = hops + 1
	end
	return nil
end

local function IsExcluded(owner)
	if owner == APHP.name and APHP.saved.exclude_self then return true end
	if APHP.saved.exclude_libraries and library_names[owner] then return true end
	return false
end

local function BaseName(path)
	if not path then return "?" end
	return string.match(path, "([^/\\]+)$") or path
end

local function LabelFor(dataIndex, dataType)
	if dataType == SCRIPT_PROFILER_RECORD_DATA_TYPE_CLOSURE then
		local name, path, line = GetScriptProfilerClosureInfo(dataIndex)
		if name and name ~= "" then
			return string.format("%s  %s:%d", name, BaseName(path), line or 0)
		end
		return string.format("%s:%d", BaseName(path), line or 0)
	end
	if dataType == SCRIPT_PROFILER_RECORD_DATA_TYPE_CFUNCTION then
		return (GetScriptProfilerCFunctionInfo(dataIndex) or "?") .. "()"
	end
	if dataType == SCRIPT_PROFILER_RECORD_DATA_TYPE_GARBAGE_COLLECTION then
		return APHP.L("GARBAGE_COLLECTION")
	end
	if dataType == SCRIPT_PROFILER_RECORD_DATA_TYPE_USER_EVENT then
		return APHP.L("EVENT") .. (GetScriptProfilerUserEventInfo(dataIndex) or "?")
	end
	return "?"
end

local function StackFor(index, count)
	local stack, at = {}, index
	while at and at >= 1 and at <= count and #stack < MAX_STACK do
		if data_index[at] then stack[#stack + 1] = LabelFor(data_index[at], data_type[at]) end
		at = caller[at]
	end
	return stack
end

local function CreditFunction(owner, index, count, own_ms)
	local dataIndex, dataType = data_index[index], data_type[index]
	local key = owner .. "\t" .. tostring(dataType) .. ":" .. tostring(dataIndex)
	local wall = duration[index]
	local row = state.funcs[key]
	if not row then
		row = { owner = owner, label = LabelFor(dataIndex, dataType), own = 0, calls = 0, wall = 0,
			min = wall, max = -1, children = {} }
		state.funcs[key] = row
	end
	row.own = row.own + own_ms
	row.calls = row.calls + 1
	row.wall = row.wall + wall
	if wall < row.min then row.min = wall end
	if wall > row.max then
		row.max = wall
		row.stack = StackFor(index, count)
	end
	return key
end

local function NewTimeline(frames)
	local cap = IsConsoleUI() and CONSOLE_TIMELINE_BUCKETS or TIMELINE_BUCKETS
	local buckets = frames < cap and frames or cap
	local timeline = { buckets = buckets, frames = frames, frames_in = {}, owners = {}, worst_in = {}, worst = {} }
	for bucket = 1, buckets do
		timeline.frames_in[bucket] = 0
		timeline.worst_in[bucket] = 0
	end
	return timeline
end

local function BucketFor(frameIndex)
	local timeline = state.timeline
	return math.floor((frameIndex - 1) * timeline.buckets / timeline.frames) + 1
end

local function NoteFrame(frameIndex, frame_owner_ms)
	local timeline = state.timeline
	if not timeline then return end
	local bucket = BucketFor(frameIndex)
	timeline.frames_in[bucket] = timeline.frames_in[bucket] + 1

	local frame_total, top_owner, top_ms = 0, nil, 0
	for owner, ms in pairs(frame_owner_ms) do
		local series = timeline.owners[owner]
		if not series then
			series = {}
			timeline.owners[owner] = series
		end
		series[bucket] = (series[bucket] or 0) + ms
		frame_total = frame_total + ms
		if ms > top_ms then top_owner, top_ms = owner, ms end
	end
	if frame_total > timeline.worst_in[bucket] then timeline.worst_in[bucket] = frame_total end

	local worst = timeline.worst
	if frame_total > 0 and (#worst < WORST_FRAMES_KEPT or frame_total > worst[#worst].ms) then
		worst[#worst + 1] = { frame = frameIndex, ms = frame_total, owner = top_owner, owner_ms = top_ms }
		table.sort(worst, function(a, b) return a.ms > b.ms end)
		if #worst > WORST_FRAMES_KEPT then worst[#worst] = nil end
	end
end

function APHP.TrimTimeline(timeline, rows)
	if not timeline then return nil end
	local keep = {}
	local limit = math.max(APHP.GetListLimit(), MIN_TIMELINE_OWNERS)
	for index = 1, math.min(#rows, limit) do keep[rows[index].owner] = true end
	local other = {}
	for owner, series in pairs(timeline.owners) do
		if not keep[owner] then
			for bucket, ms in pairs(series) do other[bucket] = (other[bucket] or 0) + ms end
			timeline.owners[owner] = nil
		end
	end
	if next(other) then timeline.owners[APHP.TIMELINE_OTHER] = other end
	return timeline
end

local function Credit(owner, own_ms, total_ms)
	local row = state.owners[owner]
	if not row then
		row = { owner = owner, own = 0, total = 0, calls = 0, peak = 0 }
		state.owners[owner] = row
	end
	row.own = row.own + own_ms
	row.total = row.total + total_ms
	row.calls = row.calls + 1
	if own_ms > row.peak then row.peak = own_ms end
end

local function ParseFrame(frameIndex)
	local count = GetScriptProfilerFrameNumRecords(frameIndex) or 0
	if count < 1 then
		NoteFrame(frameIndex, {})
		return
	end

	for index = 1, count do
		local dataIndex, startNS, endNS, callerIndex, dataType = GetScriptProfilerRecordInfo(frameIndex, index)
		local ms = 0
		if startNS and endNS and endNS > startNS then ms = (endNS - startNS) / NS_PER_MS end
		duration[index] = ms
		caller[index] = callerIndex
		child_time[index] = 0
		data_index[index] = dataIndex
		data_type[index] = dataType
		owner_of[index] = dataIndex and DirectOwner(dataIndex, dataType) or false
	end

	for index = 1, count do
		local parent = caller[index]
		if parent and parent >= 1 and parent <= count then
			child_time[parent] = child_time[parent] + duration[index]
		end
	end

	local frame_owner_ms = {}
	for index = 1, count do
		func_key[index] = false
		local owner = owner_of[index] or OwnerAbove(index, count)
		if owner and not IsExcluded(owner) then
			local own = duration[index] - child_time[index]
			if own < 0 then own = 0 end
			Credit(owner, own, duration[index])
			frame_owner_ms[owner] = (frame_owner_ms[owner] or 0) + own
			if data_index[index] then func_key[index] = CreditFunction(owner, index, count, own) end
		end
	end

	for index = 1, count do
		local parent = caller[index]
		local parent_key = parent and parent >= 1 and parent <= count and func_key[parent]
		if parent_key and func_key[index] then
			local children = state.funcs[parent_key].children
			children[func_key[index]] = (children[func_key[index]] or 0) + duration[index]
		end
	end
	NoteFrame(frameIndex, frame_owner_ms)
end

local function ReleaseBuffers()
	duration = {}
	caller = {}
	child_time = {}
	owner_of = {}
	data_index = {}
	data_type = {}
	func_key = {}
	path_owner = {}
end

local function FinishParse()
	state.parsing = false
	local report = APHP.BuildReport(state.owners, state.funcs, state.frames, state.elapsed_ms)
	report.timeline = APHP.TrimTimeline(state.timeline, report.rows)
	state.owners = nil
	state.funcs = nil
	state.timeline = nil
	APHP.RecordRun(report)
	if APHP.saved.log_to_debuglogger then APHP.LogReportLines(report) end
	ReleaseBuffers()
	APHP.CleanUpAfterScan()
	APHP.SetHudStatus("")
	if APHP.saved.open_window_after_scan then APHP.ShowHud() else APHP.RefreshHud() end
end

local function ParseStep()
	local cap = APHP.LimitFor("frames", APHP.saved.frames_per_tick)
	if type(cap) ~= "number" or cap < 1 then cap = 1 end
	local budget_ms = LibAPH.GetSchedulerBudgetMs()
	local started = GetGameTimeSeconds() * 1000

	local parsed = 0
	while state.frame < state.frames and parsed < cap do
		state.frame = state.frame + 1
		ParseFrame(state.frame)
		parsed = parsed + 1
		if GetGameTimeSeconds() * 1000 - started >= budget_ms then break end
	end

	if state.frame >= state.frames then
		FinishParse()
		return true
	end
	APHP.SetHudStatus(string.format(APHP.L("READING_OF_FRAMES"), state.frame, state.frames))
	return false
end

function APHP.Start()
	if state.running then
		APHP.Print(APHP.L("ALREADY_RECORDING_USE_APHPSTOP_ONCE_YOU"), true)
		return false
	end
	if state.parsing then
		APHP.Print(APHP.L("STILL_READING_THE_LAST_RECORDING_GIVE"), true)
		return false
	end
	if type(StartScriptProfiler) ~= "function" then
		APHP.Print(APHP.L("THIS_CLIENT_HAS_NO_SCRIPT_PROFILER"), true)
		return false
	end

	state.running = true
	state.started_at = GetGameTimeMilliseconds()
	StartScriptProfiler()
	APHP.StartScanWatch()
	if APHP.OnRecordingStarted then APHP.OnRecordingStarted() end
	if APHP.IsTimedScan() then
		APHP.Print(string.format(APHP.L("RECORDING_FOR_DO_THE_THING_THAT"), APHP.FormatClock(APHP.ScanSeconds())))
	else
		APHP.Print(APHP.L("RECORDING_DO_THE_THING_THAT_STUTTERS"))
	end
	return true
end

function APHP.Stop()
	if not state.running then
		APHP.Print(APHP.L("NOT_RECORDING_USE_APHP_TO_START"), true)
		return false
	end

	StopScriptProfiler()
	APHP.StopScanWatch()
	state.running = false
	if APHP.OnRecordingStopped then APHP.OnRecordingStopped() end
	state.elapsed_ms = GetGameTimeMilliseconds() - state.started_at
	state.frames = GetScriptProfilerNumFrames() or 0
	if state.frames < 1 then
		APHP.Print(APHP.L("THE_RECORDING_HELD_NO_FRAMES"), true)
		return false
	end

	BuildAddonIndex()
	state.frame = 0
	state.owners = {}
	state.funcs = {}
	state.timeline = NewTimeline(state.frames)
	state.parsing = true
	APHP.SetHudStatus(string.format(APHP.L("READING_0_OF_FRAMES"), state.frames))
	LibAPH.Schedule(PARSE_JOB, ParseStep, { oncePerFrame = true })
	return true
end

APHP.ESOUI_OWNER = ESOUI_OWNER
APHP.GC_OWNER = GC_OWNER
