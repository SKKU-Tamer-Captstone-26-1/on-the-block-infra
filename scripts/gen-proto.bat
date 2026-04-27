@echo off
setlocal

cd /d "%~dp0\.."

echo ^>^> buf로 코드 생성 시작...

where buf >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [오류] buf 가 설치되어 있지 않습니다.
    echo   설치: https://buf.build/docs/installation
    exit /b 1
)

buf generate %*

if %ERRORLEVEL% neq 0 (
    echo [오류] buf generate 실패
    exit /b 1
)

echo ^>^> 생성 완료: gen\ 디렉토리를 확인하세요.
endlocal
