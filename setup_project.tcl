##############################################################################################
#
# Configure and run a vivado project 
#
# Thanks to https://grittyengineer.com/vivado-project-mode-tcl-script/ for this script!
# Also thanks to https://www.eevblog.com/forum/fpga/using-vivado-in-tcl-mode/ for simulation 
# configuration information!
###############################################################################################

###################################################################
# Configure the project
####################################################################
# Set this to the path to the output folder you desire
set outputdir "./generated"
# Set to top level entity name - entity to be used by the board and/or to be used by testbench simulation
set topLevelModuleName "spinning_cube_top" 
# Set this to the top level entity name in your simulation testbench vhdl file or set to "" if no testbench
set topLevelTestbenchModuleName ""
# Set this to the name of your  simulation testbench vhdl file or leave as "" if no test bench
set simulationTestbench ""
# flag to generate bitstream. Set to true if you want to program the board
set generateBitStream "true"
# Set this to the FPGA part name - (it is already set to the BASYS 3 FPGA part )
set fpgaPart "xc7a35tcpg236-1"
# set to the name/location of your constraints file. I suggest leaving in the project folder
set constraintsFile "Basys3_Master.xdc"

# set this if you only want to program the device from this script
set programDevice "true"

# set this to false if you want to run both synthesis & simulation
set skipSynthesis "false"

########################################################################
# Check if we want to run synthesis and/or simlulation
# set skipSyntheis to "false" if you want to run synthesis
########################################################################
if { $skipSynthesis ne "true" } {

    ####################################################################
    # Create output folder and/or clear contents if not empty
    ####################################################################
    if { [file isdirectory "$outputdir"] } {
        # if the directory exists, make sure it is empty
        puts "$outputdir exists! Emptying it! --------------------------"
        set files [glob -nocomplain "$outputdir/*"]
        if {[llength $files] != 0} {
            # clear folder contents if not empty
            puts "deleting contents of $outputdir ----------------------"
            file delete -force {*}[glob -directory $outputdir *]; 

            # clean up any log and jou files
            file delete -force {*}[glob *.backup.log *.backup.jou ]
        }
    } else {
        # make the output folder since it does not exist
        file mkdir "$outputdir"   
    }

    # output folder is now empty
    puts "Creating project inside $outputdir --------------------------"

    ####################################################################
    # Create the project and add files for the project
    ####################################################################
    create_project -part $fpgaPart $topLevelModuleName $outputdir

    # add source files for the  Vivado simulation project
    if {$simulationTestbench ne ""} {
        add_files -fileset sim_1 $simulationTestbench
    }

    # add local vhdl source files to the board project
    add_files [glob ./*.vhd ]

    # add the constraints file to the board project
    add_files -fileset constrs_1 $constraintsFile

    ####################################################################
    # Set the top level modules for the component and the testbench
    ####################################################################
    set_property top $topLevelModuleName [current_fileset]

    if {$topLevelTestbenchModuleName ne ""} {
        set_property top $topLevelTestbenchModuleName [get_fileset sim_1]
    }

    # Set the compile order for both the FPGA project and simulation
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1

    #####################################################################
    # Launch simulation
    #####################################################################
    if {$topLevelTestbenchModuleName ne ""} {
        puts "\n\nLaunching Simulation ----------------------------------------"
        # set_property runtime {$simulationTimeNS} [get_filesets sim_1]
        launch_simulation -simset sim_1 -mode behavioral
    }

    #####################################################################
    # Launch synthesis, generate bitstream and output the bitstream
    #####################################################################
    if { $generateBitStream eq "true" } {
        puts "\n\nLaunching Synthesis ----------------------------------------"
        launch_runs synth_1
        wait_on_run synth_1


        # Run implementation and generate bitstream
        set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
        launch_runs impl_1 -to_step write_bitstream 
        wait_on_run impl_1
    }
}

if { $programDevice eq "true" } {

    set fpgaPart xc7a35t_0
    set bitfilePath [ file normalize ${outputdir}/${topLevelModuleName}.runs/impl_1/${topLevelModuleName}.bit ]
    puts "Bit file path is $bitfilePath"
    puts "Opening the Hardware Manager."
    open_hw_manager
    puts "Connecting to the FPGA board."
    connect_hw_server -allow_non_jtag
    open_hw_target
    current_hw_device [get_hw_devices $fpgaPart]
    refresh_hw_device -update_hw_probes false [lindex [get_hw_devices $fpgaPart] 0]
    set_property PROGRAM.FILE ${bitfilePath} [get_hw_devices $fpgaPart]
    current_hw_device [get_hw_devices $fpgaPart]
    puts "Programming the FPGA Board."
    set_property PROBES.FILE {} [get_hw_devices $fpgaPart]
    set_property FULL_PROBES.FILE {} [get_hw_devices $fpgaPart]
    set_property PROGRAM.FILE ${bitfilePath} [get_hw_devices $fpgaPart]
    program_hw_devices [get_hw_devices $fpgaPart]
    refresh_hw_device [lindex [get_hw_devices $fpgaPart] 0]
    puts "Closing the Hardware Manager."
    close_hw_target
    close_hw_manager
}





puts "\n\nImplementation done! ----------------------------------------"