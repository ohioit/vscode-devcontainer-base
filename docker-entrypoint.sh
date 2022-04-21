#!/bin/bash
# This script is only really used if the container is run
# from something like Docker run. It's designed to setup some
# things vscode would otherwise do
exec sudo -u vscode -i
