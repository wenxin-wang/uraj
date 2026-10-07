-- Touchpad dead zones: a single touch that *starts* inside a dead zone
-- is reported to libinput as MT_TOOL_PALM for its whole lifetime, so it
-- never moves the pointer, taps or scrolls, even if the palm slides
-- into the rest of the touchpad.
--
-- libinput's own edge palm detection is a fixed 8 mm strip and lets a
-- touch go once it moves out of the strip within 200 ms; on lappie the
-- right palm lands up to 12 mm from the edge and slides inwards while
-- typing, which both get past.
--
-- Multi-finger gestures stay intact: a dead-zone touch that starts
-- within GRACE_US of a touch outside every dead zone is left alone.
--
-- Loaded by niri from $XDG_CONFIG_HOME/libinput/plugins (needs libinput
-- >= 1.30 built with Lua, see (uraj packages libinput)).  Edit the
-- zones and restart niri; test with
--   sudo libinput debug-events --verbose --enable-plugins \
--     --plugin-path ~/.config/libinput/plugins

local MT_TOOL_PALM = 2
local GRACE_US = 150 * 1000

-- Zones in mm from the top-left corner, keyed by "vid:pid".  A missing
-- bound is open.
local DEVICES = {
    -- lappie (ASUS Adol Book Air 14), BLTP7953, 127x80 mm.
    ["347d:7953"] = {
        { x_min = 110 },                -- right palm
        { x_max = 35, y_max = 20 },     -- left thumb near the space bar
    },
}

local function in_zone(zones, x, y)
    for _, z in ipairs(zones) do
        if (not z.x_min or x >= z.x_min) and (not z.x_max or x <= z.x_max)
            and (not z.y_min or y >= z.y_min) and (not z.y_max or y <= z.y_max) then
            return true
        end
    end
    return false
end

local function new_slot()
    -- kernel_tool: last ABS_MT_TOOL_TYPE from the kernel; reported_tool:
    -- what libinput currently believes.
    return { x = 0, y = 0, active = false, dead = false, forced = false,
             start = 0, kernel_tool = 0, reported_tool = 0 }
end

local function attach(device, zones)
    local absinfos = device:absinfos()
    local xres = absinfos[evdev.ABS_MT_POSITION_X].resolution
    local yres = absinfos[evdev.ABS_MT_POSITION_Y].resolution
    if not xres or xres <= 0 or not yres or yres <= 0 then
        libinput:log_error(device:name() .. ": no resolution, dead zones disabled")
        return
    end

    local slots = {}
    for s = absinfos[evdev.ABS_MT_SLOT].minimum, absinfos[evdev.ABS_MT_SLOT].maximum do
        slots[s] = new_slot()
    end
    local cur = 0

    device:connect("evdev-frame", function(_, frame, timestamp)
        local out = {}
        local began = {}
        local modified = false

        for _, e in ipairs(frame) do
            local u, v = e.usage, e.value
            local slot = slots[cur]
            if u == evdev.ABS_MT_SLOT then
                cur = v
            elseif slot == nil then
                -- slot out of range: pass through untouched
            elseif u == evdev.ABS_MT_TRACKING_ID then
                slot.active = v >= 0
                slot.forced = false
                if slot.active then
                    slot.start = timestamp
                    table.insert(began, cur)
                end
            elseif u == evdev.ABS_MT_POSITION_X then
                slot.x = v / xres
            elseif u == evdev.ABS_MT_POSITION_Y then
                slot.y = v / yres
            elseif u == evdev.ABS_MT_TOOL_TYPE then
                slot.kernel_tool = v
                if slot.forced then
                    e = { usage = u, value = MT_TOOL_PALM }
                    modified = true
                end
                slot.reported_tool = e.value
            end
            table.insert(out, e)
        end

        -- Positions arrive after the tracking id, so decide at the end.
        for _, s in ipairs(began) do
            slots[s].dead = in_zone(zones, slots[s].x, slots[s].y)
        end
        for _, s in ipairs(began) do
            local slot = slots[s]
            if slot.dead then
                slot.forced = true
                for o, other in pairs(slots) do
                    if o ~= s and other.active and not other.dead
                        and timestamp - other.start <= GRACE_US then
                        slot.forced = false
                    end
                end
            else
                -- A finger outside the zones joins a dead-zone touch that
                -- started just before: that is a gesture, release it.
                for _, other in pairs(slots) do
                    if other.forced and timestamp - other.start <= GRACE_US then
                        other.forced = false
                    end
                end
            end
        end

        local switched = false
        for s, slot in pairs(slots) do
            local want = slot.forced and MT_TOOL_PALM or slot.kernel_tool
            if slot.active and want ~= slot.reported_tool then
                table.insert(out, { usage = evdev.ABS_MT_SLOT, value = s })
                table.insert(out, { usage = evdev.ABS_MT_TOOL_TYPE, value = want })
                slot.reported_tool = want
                switched = true
                libinput:log_debug(string.format(
                    "dead zones: slot %d at %.1f/%.1f mm -> tool %d",
                    s, slot.x, slot.y, want))
            end
        end
        if switched then
            -- The kernel omits ABS_MT_SLOT while its slot is unchanged.
            table.insert(out, { usage = evdev.ABS_MT_SLOT, value = cur })
            modified = true
        end

        if modified then
            return out
        end
    end)
end

libinput:register({ 1 })

libinput:connect("new-evdev-device", function(device)
    local info = device:info()
    local zones = DEVICES[string.format("%04x:%04x", info.vid or 0, info.pid or 0)]
    if zones and device:udev_properties().ID_INPUT_TOUCHPAD
        and device:usages()[evdev.ABS_MT_TOOL_TYPE] then
        libinput:log_info(device:name() .. ": touchpad dead zones enabled")
        attach(device, zones)
    end
end)
