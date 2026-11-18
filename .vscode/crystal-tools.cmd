@echo off
rem Shim between the "Crystal Language" VS Code extension (crystal-lang-tools.crystal-lang) and crystal.exe.
rem
rem Why it exists: on Windows the extension builds hover / go-to-definition / problems commands like
rem     crystal tool context -c \\source\\repos\\...\\handler.cr:34:9 ...
rem It drops the drive letter and then doubles every backslash, so Windows reads the path as a UNC path
rem (\\source\...). The compiler cannot match it to a source file and hover silently returns nothing.
rem This shim collapses "\\" back to "\" in the arguments and forwards everything to the real compiler.
rem
rem Wired up through "crystal-lang.compiler" in .vscode/settings.json. Not for use outside VS Code.
setlocal EnableDelayedExpansion

rem VS Code may have been started before Crystal was added to PATH; fall back to the default install dir.
where crystal >nul 2>&1 || set "PATH=%LOCALAPPDATA%\Programs\Crystal;%PATH%"

set "ARGS=%*"
set "ARGS=!ARGS:\\=\!"
crystal !ARGS!
exit /b %ERRORLEVEL%
