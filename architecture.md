# GFX16 processor

## Overview

This project is a custom 16 bit cpu running on a Basys 3 fpga. The cpu executes an assembly program that renders animated wireframe 3D objects to a vga monitor.

The point of the project was to do something visual and "interactive," so the final demo became a small software rendered 3D engine. The cpu handles the actual rendering work: it reads input, rotates vertices, projects them to 2D, and draws lines into a framebuffer. And the vga hardware ends up only scanning out the pixels that the cpu already wrote.

Also, the system supports live input from the board buttons, switches, and a ps/2 keyboard. Those inputs control the selected shape, color, and animation speed while the program is running.

## File structure

The top level module is spinning_cube_top.vhd file. It connects the main pieces together:

* gfx16_cpu.vhd - the 16 bit cpu
* input_controller.vhd - handles buttons, switches, and keyboard input
* framebuffer.vhd - stores the rendered pixels
* vga_driver.vhd, - generates the vga timing
* display_hex.vhd - runs the seven segment display

The Basys 3 clock is divided down into two main clocks. The vga runs at 25 MHz, and the cpu runs at around 6.25 MHz.

That difference is really doesn't matter because the two sides never actually touch the same buffer at the same time. The vga side is continuously reading finished pixels from the front buffer, while the cpu is drawing the next frame into the back buffer. Since they work on separate pages (double buffering), the monitor will keep showing a stable image regardless of the clock difference.

It goes from:

input devices to input controller to cpu to framebuffer to vga driver to monitor

The cpu reads live input through memory mapped addresses and when the program draws a pixel it uses the plot instruction, which writes directly into the framebuffer.

## Design

The cpu is a single cycle 16 bit design. It has a 10 bit program counter, an 8 register register file, a control decoder, an alu, and one memory used for both instructions and data.

We kept it single cycle because the interesting part of this project was the graphics pipeline, not building some complicated cpu pipeline. A single cycle cpu made the control path much easier to understand and build.

The instruction set includes normal operations like ADD, SUB, MUL, LOAD, STORE, BEQ, BLT, and JMP. It also includes two graphics instructions:

- PLOT which draws one pixel into the framebuffer
- CLR which requests a framebuffer page flip

PLOT uses two registers for the x and y coordinates. The color comes from a cpu side latch tied to register 7, so the assembly program can set the draw color and then plot multiple pixels with that same color.

CLR is kind of a little misleading. But in the final design, it does not erase the framebuffer. It just tells the framebuffer that the current back buffer is ready to be displayed. The assembly program then clears the next back buffer manually by just drawing black pixels over it.

## Memory and input/output

The cpu memory is 1024 words, with 16 bits per word. The assembler places the .data section first and the program instructions after it. Because of that, the cpu reset address has to point to the first instruction, not address 0. In the final build, PC_RESET is set to 398.

Some low memory addresses are reserved for I/O:

|Address |Use                   |
|-------|-----------------------|
|240 | selected shape |
|241 | selected color |
|242 | selected speed |
|243 | last keyboard scan code|
|244 | led output |

It loads from 240 through 243 read live input values. Stores to 244 update the board LEDs.

One annoying constraint though is that LDI only has an 8 bit immediate, so directly loaded addresses have to fit in 0 through 255. Because of that, we had to be careful with the assembly file in regards to where important buffers, lookup tables, and the i/o addresses would land.

## Framebuffer and vga

The framebuffer was arguably one of the most important parts of the project. The visible render resolution is 160x120, with 16 bits per pixel. vga scales that up to 640x480 by turning each framebuffer pixel into a 4x4 block.

We used 160x120 because a full 640x480 framebuffer would be far too large for the little Basys 3 board. One 160x120 page is like 19,200 pixels.And with two 16 bit pages for double buffering, the design uses 614,400 bits of framebuffer storage, which is still reasonable for the board though.

The framebuffer keeps two pages. vga scans one page while the cpu draws into the other. The cpu writes to write page, and vga reads from front page. When the cpu finishes a frame, it requests a swap. The visible page only changes on the vga frame boundary, so the monitor does not show any half updated frames/artifacts.

Also the cpu and vga run on different clocks, so the page swap request has to cross the clock domains safely. The final version uses a toggle based synchronizer. The cpu toggles a request signal, then the vga side detects that change and the actual swap happens on frame tick.

An earlier version of the framebuffer we tried to get working was way too extra with how it dealt with state and metadata. The final version is simpler: store pixel colors, swap pages, and let software clear the next back buffer. That ended up being much easier to debug.

As for the vga driver. It generates standard 640x480 timing with a 25 MHz pixel clock. It requests framebuffer coordinates based on the current vga scan position. The x coordinate uses a small +2 offset to compensate for the framebuffer read delay. Without that, the image had a horizontal smear because the color arrives a couple cycles after the coordinate request.

## Rendering in assembly

The renderer is written in spinning_cube.asm. It does the transform and line drawing on the cpu.

The project supports a cube, pyramid, octahedron, and an imported Minecraft character model. The first three shapes are hand written vertex and edge tables. The fourth shape is generated from an .obj file by the assembler. The assembler reads the model vertices, recenters the model, scales it to fit the scene, then converts the coordinates to 8.8 fixed point, and writes that generated arrays into the data section.

The renderer uses signed 8.8 fixed point math because the cpu has no floating point hardware. A value like 1.0 is stored as 256, and a value like 5.0 is stored as 1280. Multiplication produces a larger intermediate result, so the alu shifts the product back down by 8 bits to keep values in that 8.8 format.

Rotation uses 64 entry sine and cosine lookup tables. Each frame loads the current sine and cosine values, rotates every vertex, and then projects the result onto the 160x120 screen.

Perspective is also just an approximation. Instead of dividing by depth, we just use a small lookup table:
```
z_camera = z_rot + camera_z
depth_index = min(20, z_camera >> 8)
scale = perspective[depth_index]
```

Then the projected point is centered on the framebuffer:
```
screen_x = 80 + ((x_rot * scale) >> 8)
screen_y = 60 - ((y_rot * scale) >> 8)
```

Something to note. A real bug came from doing the center offset way too early. Adding the offset before shifting would overflow the 16 bit signed range and make vertices wrap around. The final version shifts the fixed point product first and adds the screen center afterward.

## Line drawing

Once the vertices are projected, the program walks the shape's edge table and draws each wireframe line. That line routine is basically Bresenham's algorithm. It calculates the x and y distances between two points, decides which axis is the major direction, and then steps one pixel at a time while maintaining an integer error value. This kept the whole renderer integer based. Didn't need slope division or floating point math at all.

## Final frame loop

Each frame does roughly this:

1. read the current shape, color, and speed
2. mirror the selected shape to the LEDs
3. load the selected shape's vertex and edge data
4. request a page flip
5. clear the new back buffer
6. rotate and project all vertices
7. draw the wireframe edges
8. delay based on the selected speed
9. advance the angle index
10. and repeat...

## Some tradeoffs

The final design makes a few tradeoffs:

* single cycle cpu instead of a more complex pipeline
* fixed point math instead of floating point
* lookup table perspective instead of division
* 160x120 render resolution instead of full vga resolution
* double buffering to avoid tearing
* software clearing instead of complicated framebuffer metadata
* wireframe rendering instead of filled polygons

But, those choices made the project small enough to fit on the fpga while still being complex (and doable) enough to show a real cpu graphics pipeline.


