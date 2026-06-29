@echo off
:: Kudu Triggered WebJob: recover-startup
:: Deletes startup-fail.flag then bounces ANCM so the app starts cleanly.
:: Works even when the main app is crashed (SCM process runs independently).
:: Trigger via: POST https://<app>.scm.azurewebsites.net/api/triggeredwebjobs/recover-startup/run

set FLAGFILE=%HOME%\site\wwwroot\startup-fail.flag
set OFFLINE=%HOME%\site\wwwroot\app_offline.htm

if exist "%FLAGFILE%" (
    del /f /q "%FLAGFILE%"
    echo [recover-startup] startup-fail.flag deleted.
) else (
    echo [recover-startup] No flag found - app was already healthy.
)

:: Bounce ANCM in-process host: writing app_offline.htm causes ANCM to drain
:: the in-process worker; removing it signals ANCM to spin up a fresh process.
echo Recovering... > "%OFFLINE%"
ping -n 4 127.0.0.1 > nul
del /f /q "%OFFLINE%"
echo [recover-startup] app_offline.htm removed - ANCM starting fresh worker.
