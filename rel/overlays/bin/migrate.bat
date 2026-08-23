@echo off
setlocal
cd /d %~dp0
call .\elixir_stage.bat eval "apps = [:soundai, :soundpanel]; for app <- apps do mod = Module.concat([app, :Release]); if Code.ensure_loaded?(mod) do :io.puts(~s[Migrating #{app}]); apply(mod, :migrate, []) else :io.puts(~s[#{app} has no Release module; skipping]) end"
