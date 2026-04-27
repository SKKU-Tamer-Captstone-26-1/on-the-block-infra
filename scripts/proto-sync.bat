@echo off
setlocal EnableDelayedExpansion

cd /d "%~dp0\.."
set "GEN_DIR=%CD%\gen\go"

REM -------------------------------------------------------
REM 동기화 대상 서비스 레포 경로를 아래에 추가하세요.
REM 형식: set "SVC_서비스명=상대\또는\절대\경로"
REM 예시: set "SVC_backend=..\on-the-block-backend\internal\proto"
REM -------------------------------------------------------

REM set "SVC_backend=..\on-the-block-backend\internal\proto"

REM -------------------------------------------------------
REM 여기서부터는 수정하지 않아도 됩니다.
REM -------------------------------------------------------

set "FOUND=0"

for /f "tokens=1,* delims==" %%A in ('set SVC_ 2^>nul') do (
    set "FOUND=1"
    set "DEST=%%B"
    echo   -^> %%A: !GEN_DIR! → !DEST!
    if not exist "!DEST!" mkdir "!DEST!"
    robocopy "!GEN_DIR!" "!DEST!" /MIR /NFL /NDL /NJH /NJS
)

if "!FOUND!"=="0" (
    echo [오류] SVC_ 로 시작하는 대상 경로가 없습니다.
    echo   proto-sync.bat 상단의 SVC_서비스명 변수를 설정하세요.
    exit /b 1
)

echo ^>^> 동기화 완료.
endlocal
