-- Safe entry point for the real main.lua offline shell contract.
-- Never defaults to installed plugins, production settings, SEC downloads or API calls.
-- Host: LUA_PATH=<explicit host adapters>/?.lua;; luajit plugin_shell_test.lua --offline <empty-dir> <plugin-dir>
-- Kindle (ONLY after approval, from /mnt/us/koreader):
-- ./luajit <isolated-tests>/plugin_shell_test.lua --device-offline <empty-dir> <isolated-plugin-dir>
local mode, root, plugin_dir = arg[1], arg[2], arg[3]
if (mode ~= "--offline" and mode ~= "--device-offline") or not root or not plugin_dir then
    io.stderr:write("Usage: plugin_shell_test.lua --offline|--device-offline <empty-sandbox> <isolated-plugin-dir>\n")
    os.exit(2)
end
assert(root:sub(1,1)=="/" and plugin_dir:sub(1,1)=="/", "use explicit absolute paths")
assert(plugin_dir ~= "/mnt/us/koreader/plugins/secfilings.koplugin", "do not test installed production plugin")
assert(not root:match("^/mnt/us/documents"), "sandbox cannot be the user's book library")
if mode == "--device-offline" then
    assert(root:match("^/mnt/us/secfilings%-test%-"), "device sandbox must be under /mnt/us/secfilings-test-*")
    dofile("setupkoenv.lua")
end
local lfs = require("libs/libkoreader-lfs")
assert(lfs.symlinkattributes(root, "mode")=="directory", "sandbox must be an existing real directory")
for name in lfs.dir(root) do assert(name=="." or name=="..", "sandbox must be empty") end
package.path=plugin_dir .. "/?.lua;" .. package.path
SEC_TEST_PLUGIN_DIR = plugin_dir -- test harness must not shadow the explicitly selected plugin
local here=arg[0]:match("^(.*)/[^/]+$") or "."
arg[1]=root
-- The harness injects fake UI/network/SEC endpoints, but loads the actual main and translation modules.
dofile(here .. "/sec_translation_ui_test.lua")
print("PASS plugin_shell_test: explicit sandbox only; no SEC or DeepSeek traffic")
