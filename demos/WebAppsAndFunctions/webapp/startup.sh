#!/bin/bash
# Startup script for the Web App.
# Sets PYTHONPATH to include bundled dependencies and starts gunicorn.
# This file is deployed to /home/site/wwwroot/ and referenced by appCommandLine.
export PYTHONPATH="/home/site/wwwroot/.python_packages/lib/site-packages"
exec gunicorn --bind=0.0.0.0:8000 app:app
