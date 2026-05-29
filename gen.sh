#!/bin/bash

# Get a list of possible folder locations for vivado
# put these in order of most recent to oldest
dirs=(  "/c/AMDDesignTools/2025.2/Vivado/bin"
        "/c/Xilinx/2025.2/Vivado/bin" 
        "/c/Xilinx/2025.1/Vivado/bin" 
        "/c/Xilinx/Vivado/2023.2/bin"         
        "/c/Xilinx/Vivado/2023.1/bin" 
)
# Expand the list of dirs to a list of quoted strings suitable for the for loop
for var in "${dirs[@]}"; do
    echo "Checking directory $var"
    if [ -d "$var" ]; then
        echo "found latest vivado at $var"
        latest="$var"
        break
    fi
done

# Quit if we cant find vivado
if [ -z "$latest" ]; then
    echo "couldnt find Vivado on this machine"
    exit
fi

PATH=$PATH:$latest

# Now we have located vivado and put it in ths system path
# we can run vivado directly from the command line
# we could also make a .vscode launch command if we wanted to
vivado -mode batch -source ./setup_project.tcl