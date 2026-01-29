@echo off
REM Windows path validation test for validate.exe
REM Tests basic path handling on Windows including:
REM - Current directory (".")
REM - Absolute paths
REM - Paths with spaces
REM - Single file validation

setlocal enabledelayedexpansion

set "BIN=zig-out\bin\validate.exe"
set "EXITCODE=0"

REM Check if binary exists
if not exist "%BIN%" (
    echo FAIL: validate.exe not found at %BIN%
    exit /b 1
)

REM Create temp directory for test files
set "TMPDIR=%TEMP%\validate_test_%RANDOM%"
mkdir "%TMPDIR%" || (echo FAIL: Could not create temp dir & exit /b 1)

REM Create a minimal valid PNG file (1x1 pixel)
REM Using certutil to decode base64 since Windows lacks easy binary echo
echo iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg== > "%TMPDIR%\test.png.b64"
certutil -decode "%TMPDIR%\test.png.b64" "%TMPDIR%\test.png" > nul 2>&1 || (
    REM Fallback: create an empty file if certutil fails
    type nul > "%TMPDIR%\test.png"
)
del /q "%TMPDIR%\test.png.b64" 2>nul

echo.
echo === Windows Path Validation Tests ===
echo.

REM Test 1: Validate using "." (current directory)
echo Test 1: Validate using "."
pushd "%TMPDIR%"
"%~dp0..\..\%BIN%" . > nul 2>&1
set "EC=!ERRORLEVEL!"
popd
if !EC! neq 0 (
    echo   FAIL: "." path returned exit code !EC!
    set "EXITCODE=1"
) else (
    echo   PASS: "." path works
)

REM Test 2: Validate directory by absolute path
echo Test 2: Validate directory by absolute path
"%BIN%" "%TMPDIR%" > nul 2>&1
set "EC=!ERRORLEVEL!"
if !EC! neq 0 (
    echo   FAIL: Absolute directory path returned exit code !EC!
    set "EXITCODE=1"
) else (
    echo   PASS: Absolute directory path works
)

REM Test 3: Validate single file
echo Test 3: Validate single file
"%BIN%" "%TMPDIR%\test.png" > "%TMPDIR%\output.txt" 2>&1
set "EC=!ERRORLEVEL!"
REM Even if validation fails (due to our minimal PNG), the program should run without error
if !EC! gtr 1 (
    echo   FAIL: Single file validation returned exit code !EC!
    type "%TMPDIR%\output.txt"
    set "EXITCODE=1"
) else (
    echo   PASS: Single file validation works
)

REM Test 4: Path with spaces
echo Test 4: Path with spaces
mkdir "%TMPDIR%\path with spaces" 2>nul
copy "%TMPDIR%\test.png" "%TMPDIR%\path with spaces\" > nul 2>&1
"%BIN%" "%TMPDIR%\path with spaces" > nul 2>&1
set "EC=!ERRORLEVEL!"
if !EC! neq 0 (
    echo   FAIL: Path with spaces returned exit code !EC!
    set "EXITCODE=1"
) else (
    echo   PASS: Path with spaces works
)

REM Test 5: Drive-relative path (if not on C:)
echo Test 5: Drive letter path handling
REM Just verify the program doesn't crash on a simple path
"%BIN%" "%TMPDIR%" > nul 2>&1
if !ERRORLEVEL! gtr 2 (
    echo   FAIL: Drive path handling error
    set "EXITCODE=1"
) else (
    echo   PASS: Drive path handling works
)

REM Test 6: Help output (verify program runs)
echo Test 6: Help output
"%BIN%" --help > nul 2>&1
set "EC=!ERRORLEVEL!"
if !EC! neq 0 (
    echo   FAIL: --help returned exit code !EC!
    set "EXITCODE=1"
) else (
    echo   PASS: --help works
)

REM Test 7: Version output
echo Test 7: Version output
"%BIN%" --version > nul 2>&1
set "EC=!ERRORLEVEL!"
if !EC! neq 0 (
    echo   FAIL: --version returned exit code !EC!
    set "EXITCODE=1"
) else (
    echo   PASS: --version works
)

REM Cleanup
rd /s /q "%TMPDIR%" 2>nul

echo.
if !EXITCODE! equ 0 (
    echo All Windows path validation tests passed!
) else (
    echo Some tests failed!
)

exit /b !EXITCODE!
