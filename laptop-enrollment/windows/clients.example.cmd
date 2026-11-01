@echo off
REM Copy to clients.cmd and add one block per client.
REM Called by Enroll.cmd with the client key as %1.
set TENANT=
set GROUPTAG=

if /i "%1"=="contoso" (
  set TENANT=contosovc.onmicrosoft.com
  set GROUPTAG=CONTOSO-STD
)

if /i "%1"=="fabrikam" (
  set TENANT=fabrikamcapital.onmicrosoft.com
  set GROUPTAG=FABRIKAM-STD
)
