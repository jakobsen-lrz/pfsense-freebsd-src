---
-- SPDX-License-Identifier: BSD-2-Clause
--
-- Copyright(c) 2022 Baptiste Daroussin <bapt@FreeBSD.org>

local unistd = require("posix.unistd")
local sys_stat = require("posix.sys.stat")
local lfs = require("lfs")

local function decode_base64(input)
	local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
	input = string.gsub(input, '[^'..b..'=]', '')

	local result = {}
	local bits = ''

	-- convert all characters in bits
	for i = 1, #input do
		local x = input:sub(i, i)
		if x == '=' then
			break
		end
		local f = b:find(x) - 1
		for j = 6, 1, -1 do
			bits = bits .. (f % 2^j - f % 2^(j-1) > 0 and '1' or '0')
		end
	end

	for i = 1, #bits, 8 do
		local byte = bits:sub(i, i + 7)
		if #byte == 8 then
			local c = 0
			for j = 1, 8 do
				c = c + (byte:sub(j, j) == '1' and 2^(8 - j) or 0)
			end
			table.insert(result, string.char(c))
		end
	end

	return table.concat(result)
end

local function warnmsg(str, prepend)
	if not str then
		return
	end
	local tag = ""
	if prepend ~= false then
		tag = "nuageinit: "
	end
	io.stderr:write(tag .. str .. "\n")
end

local function errmsg(str, prepend)
	warnmsg(str, prepend)
	os.exit(1)
end

local function chmod(path, mode)
	local mode = tonumber(mode, 8)
	local _, err, msg = sys_stat.chmod(path, mode)
	if err then
		errmsg("chmod(" .. path .. ", " .. mode .. ") failed: " .. msg)
	end
end

local function chown(path, owner, group)
	local _, err, msg = unistd.chown(path, owner, group)
	if err then
		errmsg("chown(" .. path .. ", " .. owner .. ", " .. group .. ") failed: " .. msg)
	end
end

local function dirname(oldpath)
	if not oldpath then
		return nil
	end
	local path = oldpath:gsub("[^/]+/*$", "")
	if path == "" then
		return nil
	end
	return path
end

local function mkdir_p(path)
	if lfs.attributes(path, "mode") ~= nil then
		return true
	end
	local r, err = mkdir_p(dirname(path))
	if not r then
		return nil, err .. " (creating " .. path .. ")"
	end
	return lfs.mkdir(path)
end

local function sethostname(hostname)
	if hostname == nil then
		return
	end
	local root = os.getenv("NUAGE_FAKE_ROOTDIR")
	if not root then
		root = ""
	end
	local hostnamepath = root .. "/etc/rc.conf.d/hostname"

	mkdir_p(dirname(hostnamepath))
	local f, err = io.open(hostnamepath, "w")
	if not f then
		warnmsg("Impossible to open " .. hostnamepath .. ":" .. err)
		return
	end
	f:write('hostname="' .. hostname .. '"\n')
	f:close()
end

local function splitlist(list)
	local ret = {}
	if type(list) == "string" then
		for str in list:gmatch("([^, ]+)") do
			ret[#ret + 1] = str
		end
	elseif type(list) == "table" then
		ret = list
	else
		warnmsg("Invalid type " .. type(list) .. ", expecting table or string")
	end
	return ret
end

local function adduser(pwd)
	if (type(pwd) ~= "table") then
		warnmsg("Argument should be a table")
		return nil
	end
	local root = os.getenv("NUAGE_FAKE_ROOTDIR")
	local cmd = "pw "
	if root then
		cmd = cmd .. "-R " .. root .. " "
	end
	local f = io.popen(cmd .. " usershow " .. pwd.name .. " -7 2> /dev/null")
	local pwdstr = f:read("*a")
	f:close()
	if pwdstr:len() ~= 0 then
		return pwdstr:match("%a+:.+:%d+:%d+:.*:(.*):.*")
	end
	if not pwd.gecos then
		pwd.gecos = pwd.name .. " User"
	end
	if not pwd.homedir then
		pwd.homedir = "/home/" .. pwd.name
	end
	local extraargs = ""
	if pwd.groups then
		local list = splitlist(pwd.groups)
		extraargs = " -G " .. table.concat(list, ",")
	end
	-- pw will automatically create a group named after the username
	-- do not add a -g option in this case
	if pwd.primary_group and pwd.primary_group ~= pwd.name then
		extraargs = extraargs .. " -g " .. pwd.primary_group
	end
	if not pwd.no_create_home then
		extraargs = extraargs .. " -m "
	end
	if not pwd.shell then
		pwd.shell = "/bin/sh"
	end
	local precmd = ""
	local postcmd = ""
	local input = nil
	if pwd.passwd then
		input = pwd.passwd
		postcmd = " -H 0"
	elseif pwd.plain_text_passwd then
		input = pwd.plain_text_passwd
		postcmd = " -h 0"
	end
	cmd = precmd .. "pw "
	if root then
		cmd = cmd .. "-R " .. root .. " "
	end
	cmd = cmd .. "useradd -n " .. pwd.name .. " -M 0755 -w none "
	cmd = cmd .. extraargs .. " -c '" .. pwd.gecos
	cmd = cmd .. "' -d '" .. pwd.homedir .. "' -s " .. pwd.shell .. postcmd

	local f = io.popen(cmd, "w")
	if input then
		f:write(input)
	end
	local r = f:close(cmd)
	if not r then
		warnmsg("fail to add user " .. pwd.name)
		warnmsg(cmd)
		return nil
	end
	if pwd.locked then
		cmd = "pw "
		if root then
			cmd = cmd .. "-R " .. root .. " "
		end
		cmd = cmd .. "lock " .. pwd.name
		os.execute(cmd)
	end
	return pwd.homedir
end

local function addgroup(grp)
	if (type(grp) ~= "table") then
		warnmsg("Argument should be a table")
		return false
	end
	local root = os.getenv("NUAGE_FAKE_ROOTDIR")
	local cmd = "pw "
	if root then
		cmd = cmd .. "-R " .. root .. " "
	end
	local f = io.popen(cmd .. " groupshow " .. grp.name .. " 2> /dev/null")
	local grpstr = f:read("*a")
	f:close()
	if grpstr:len() ~= 0 then
		return true
	end
	local extraargs = ""
	if grp.members then
		local list = splitlist(grp.members)
		extraargs = " -M " .. table.concat(list, ",")
	end
	cmd = "pw "
	if root then
		cmd = cmd .. "-R " .. root .. " "
	end
	cmd = cmd .. "groupadd -n " .. grp.name .. extraargs
	local r = os.execute(cmd)
	if not r then
		warnmsg("fail to add group " .. grp.name)
		warnmsg(cmd)
		return false
	end
	return true
end

local function addsshkey(homedir, key)
	local chownak = false
	local chowndotssh = false
	local root = os.getenv("NUAGE_FAKE_ROOTDIR")
	if root then
		homedir = root .. "/" .. homedir
	end
	local ak_path = homedir .. "/.ssh/authorized_keys"
	local dotssh_path = homedir .. "/.ssh"
	local dirattrs = lfs.attributes(ak_path)
	if dirattrs == nil then
		chownak = true
		dirattrs = lfs.attributes(dotssh_path)
		if dirattrs == nil then
			assert(lfs.mkdir(dotssh_path))
			chowndotssh = true
			dirattrs = lfs.attributes(homedir)
		end
	end

	local f = io.open(ak_path, "a")
	if not f then
		warnmsg("impossible to open " .. ak_path)
		return
	end
	f:write(key .. "\n")
	f:close()
	if chownak then
		chmod(ak_path, "0600")
		chown(ak_path, dirattrs.uid, dirattrs.gid)
	end
	if chowndotssh then
		chmod(dotssh_path, "0700")
		chown(dotssh_path, dirattrs.uid, dirattrs.gid)
	end
end

local function addsudo(pwd)
	local chmodsudoersd = false
	local chmodsudoers = false
	local root = os.getenv("NUAGE_FAKE_ROOTDIR")
	local sudoers_dir = "/usr/local/etc/sudoers.d"
	if root then
		sudoers_dir= root .. sudoers_dir
	end
	local sudoers = sudoers_dir .. "/90-nuageinit-users"
	local sudoers_attr = lfs.attributes(sudoers)
	if sudoers_attr == nil then
		chmodsudoers = true
		local dirattrs = lfs.attributes(sudoers_dir)
		if dirattrs == nil then
			local r, err = mkdir_p(sudoers_dir)
			if not r then
				return nil, err .. " (creating " .. sudoers_dir .. ")"
			end
			chmodsudoersd = true
		end
	end
	local f = io.open(sudoers, "a")
	if not f then
		warnmsg("impossible to open " .. sudoers)
		return
	end
	if type(pwd.sudo) == "string" then
		f:write(pwd.name .. " " .. pwd.sudo .. "\n")
	elseif type(pwd.sudo) == "table" then
		for _, str in ipairs(pwd.sudo) do
			f:write(pwd.name .. " " .. str .. "\n")
		end
	end
	f:close()
	if chmodsudoers then
		chmod(sudoers, "0640")
	end
	if chmodsudoersd then
		chmod(sudoers, "0740")
	end
end

local n = {
	warn = warnmsg,
	err = errmsg,
	chmod = chmod,
	chown = chown,
	dirname = dirname,
	mkdir_p = mkdir_p,
	sethostname = sethostname,
	adduser = adduser,
	addgroup = addgroup,
	addsshkey = addsshkey
}

return n
