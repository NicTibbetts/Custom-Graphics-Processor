; spinning_cube.asm  GFX16 final project demo
;
; draws a rotating wireframe 3D shape on the 160x120 VGA framebuffer.
; four shapes are available (cube, pyramid, octahedron, .obj injected shape) and are selected at runtime via the io_shape register.
; color and animation speed are also read from i/o registers each frame. edges are drawn using Bresenham's line algorithm.
; perspective projection makes the farther vertices appear smaller than the closer ones.
;
; Bresenham's line algorithm references:
; https://en.wikipedia.org/wiki/Bresenham%27s_line_algorithm
; https://www.youtube.com/watch?v=CceepU1vIKo
;
; register usage:
;   r0 = vertex/edge loop counter, reset each pass
;   r1 = sin(angle) loaded once per frame, reused across all vertices
;   r2 = cos(angle) loaded once per frame, reused across all vertices
;   r3 = angle index (0..63), persists across frames
;   r4 = scratch / address pointer
;   r5 = scratch / working value
;   r6 = scratch / working value
;   r7 = pixel color, loaded from io_color at the start of each frame
;
; memory-mapped i/o addresses:
;   240 = io_shape   (selected shape input)
;   241 = io_color   (selected color input)
;   242 = io_speed   (speed selection input)
;   243 = io_keycode (latest keyboard scan code input)
;   244 = io_led     (LED output register on STORE)
;
; memory layout (addresses assigned top-to-bottom as the assembler reads this file):
;   sin_0..sin_63             addresses   0-63   64-entry sine table
;   cos_0..cos_63             addresses  64-127  64-entry cosine table
;   delay_0..delay_15         addresses 128-143  frame delay values indexed by io_speed
;   camera_z                  address     144    camera distance (12.0 = 3072 in 8.8)
;   perspective_0..20         addresses 145-165  precomputed focal/depth scale factors
;   active_vcount..edge_base  addresses 166-171  active shape parameters loaded each frame
;   sx_0..sx_39               addresses 172-211  projected screen-space x buffer (up to 40 vertices)
;   tmp_y1..tmp_scale         addresses 212-220  scratch words for rotation, projection, line drawing
;   shape_vcount_0..3         addresses 221-224  vertex counts for each of the 4 shapes
;   shape_ecount_0..3         addresses 225-228  edge counts for each of the 4 shapes
;   shape_vx_base_0..3        addresses 229-232  base address of x vertex array per shape
;   shape_vy_base_0..3        addresses 233-236  base address of y vertex array per shape
;   io_hole_pad_0..7          addresses 237-244  placeholder words spanning the hardware i/o hole
;   shape_vz_base_0..3        addresses 245-248  base address of z vertex array per shape
;   shape_edge_base_0..3      addresses 249-252  base address of edge list per shape
;   sy_0..sy_39               addresses 253-292  projected screen-space y buffer (up to 40 vertices)
;   cube/pyramid/octa/char    addresses   293+   vertex and edge data for all four shapes
;   instructions start after all data words are placed
;
; note: all labels accessed via LDI must be at addresses 0-255 (8-bit immediate limit).
;   the data section above is laid out carefully so that all labels fall within range.
;   addresses 237-244 are the hardware i/o hole; loads from there return live register
;   values instead of stored data, so those addresses are occupied by padding words.
;   However, addresses 237-239 are padding only; I/O mapping starts at 240.
;
; rotation math (two-axis rotation, y-axis then x-axis):
;   y-axis pass:
;     x' = x*cos - z*sin
;     z' = x*sin + z*cos
;   x-axis pass (rotates using z' from above):
;     y'' = y*cos - z'*sin
;     z'' = y*sin + z'*cos
;
; perspective projection:
;   z_camera = z'' + camera_z             (shift into positive camera space)
;   scale    = perspective[z_camera >> 8] (focal/depth lookup, capped at index 20)
;   screen_x = (x' * scale) >> 16 + 80    (center of 160-wide display)
;   screen_y = 60 - (y'' * scale) >> 16   (center of 120-tall display, y inverted)
;   MUL computes (a*b)>>8, so the extra >>8 makes the combined shift >>16.
;
; sin/cos table values are 8.8 fixed point (1.0 = 256), covering one full 360-degree
; rotation in 64 equal steps (~5.6 degrees each):
;   sin(0deg) =   0,  sin(90deg) = 256,  sin(180deg) =   0,  sin(270deg) = -256
;   cos(0deg) = 256,  cos(90deg) =   0,  cos(180deg) = -256,  cos(270deg) =   0

.data
; angle tables in 8.8 fixed point.
sin_0: .word 0
sin_1: .word 25
sin_2: .word 50
sin_3: .word 74
sin_4: .word 98
sin_5: .word 121
sin_6: .word 142
sin_7: .word 162
sin_8: .word 181
sin_9: .word 198
sin_10: .word 213
sin_11: .word 226
sin_12: .word 237
sin_13: .word 245
sin_14: .word 251
sin_15: .word 255
sin_16: .word 256
sin_17: .word 255
sin_18: .word 251
sin_19: .word 245
sin_20: .word 237
sin_21: .word 226
sin_22: .word 213
sin_23: .word 198
sin_24: .word 181
sin_25: .word 162
sin_26: .word 142
sin_27: .word 121
sin_28: .word 98
sin_29: .word 74
sin_30: .word 50
sin_31: .word 25
sin_32: .word 0
sin_33: .word -25
sin_34: .word -50
sin_35: .word -74
sin_36: .word -98
sin_37: .word -121
sin_38: .word -142
sin_39: .word -162
sin_40: .word -181
sin_41: .word -198
sin_42: .word -213
sin_43: .word -226
sin_44: .word -237
sin_45: .word -245
sin_46: .word -251
sin_47: .word -255
sin_48: .word -256
sin_49: .word -255
sin_50: .word -251
sin_51: .word -245
sin_52: .word -237
sin_53: .word -226
sin_54: .word -213
sin_55: .word -198
sin_56: .word -181
sin_57: .word -162
sin_58: .word -142
sin_59: .word -121
sin_60: .word -98
sin_61: .word -74
sin_62: .word -50
sin_63: .word -25

cos_0: .word 256
cos_1: .word 255
cos_2: .word 251
cos_3: .word 245
cos_4: .word 237
cos_5: .word 226
cos_6: .word 213
cos_7: .word 198
cos_8: .word 181
cos_9: .word 162
cos_10: .word 142
cos_11: .word 121
cos_12: .word 98
cos_13: .word 74
cos_14: .word 50
cos_15: .word 25
cos_16: .word 0
cos_17: .word -25
cos_18: .word -50
cos_19: .word -74
cos_20: .word -98
cos_21: .word -121
cos_22: .word -142
cos_23: .word -162
cos_24: .word -181
cos_25: .word -198
cos_26: .word -213
cos_27: .word -226
cos_28: .word -237
cos_29: .word -245
cos_30: .word -251
cos_31: .word -255
cos_32: .word -256
cos_33: .word -255
cos_34: .word -251
cos_35: .word -245
cos_36: .word -237
cos_37: .word -226
cos_38: .word -213
cos_39: .word -198
cos_40: .word -181
cos_41: .word -162
cos_42: .word -142
cos_43: .word -121
cos_44: .word -98
cos_45: .word -74
cos_46: .word -50
cos_47: .word -25
cos_48: .word 0
cos_49: .word 25
cos_50: .word 50
cos_51: .word 74
cos_52: .word 98
cos_53: .word 121
cos_54: .word 142
cos_55: .word 162
cos_56: .word 181
cos_57: .word 198
cos_58: .word 213
cos_59: .word 226
cos_60: .word 237
cos_61: .word 245
cos_62: .word 251
cos_63: .word 255

; delay table indexed by io_speed (0..15). larger value = slower animation.
delay_0: .word 96
delay_1: .word 128
delay_2: .word 160
delay_3: .word 192
delay_4: .word 224
delay_5: .word 256
delay_6: .word 320
delay_7: .word 384
delay_8: .word 512
delay_9: .word 640
delay_10: .word 768
delay_11: .word 896
delay_12: .word 1152
delay_13: .word 1408
delay_14: .word 1664
delay_15: .word 1920

camera_z: .word 3072
perspective_0: .word 16384
perspective_1: .word 16384
perspective_2: .word 8192
perspective_3: .word 5461
perspective_4: .word 4096
perspective_5: .word 3277
perspective_6: .word 2731
perspective_7: .word 2341
perspective_8: .word 2048
perspective_9: .word 1820
perspective_10: .word 1638
perspective_11: .word 1489
perspective_12: .word 1365
perspective_13: .word 1260
perspective_14: .word 1170
perspective_15: .word 1092
perspective_16: .word 1024
perspective_17: .word 964
perspective_18: .word 910
perspective_19: .word 862
perspective_20: .word 819

; current active shape parameters loaded at frame start.
active_vcount: .word 0
active_ecount: .word 0
active_vx_base: .word 0
active_vy_base: .word 0
active_vz_base: .word 0
active_edge_base: .word 0

; projected screen-space buffers.
sx_0: .word 0
sx_1: .word 0
sx_2: .word 0
sx_3: .word 0
sx_4: .word 0
sx_5: .word 0
sx_6: .word 0
sx_7: .word 0
sx_8: .word 0
sx_9: .word 0
sx_10: .word 0
sx_11: .word 0
sx_12: .word 0
sx_13: .word 0
sx_14: .word 0
sx_15: .word 0
sx_16: .word 0
sx_17: .word 0
sx_18: .word 0
sx_19: .word 0
sx_20: .word 0
sx_21: .word 0
sx_22: .word 0
sx_23: .word 0
sx_24: .word 0
sx_25: .word 0
sx_26: .word 0
sx_27: .word 0
sx_28: .word 0
sx_29: .word 0
sx_30: .word 0
sx_31: .word 0
sx_32: .word 0
sx_33: .word 0
sx_34: .word 0
sx_35: .word 0
sx_36: .word 0
sx_37: .word 0
sx_38: .word 0
sx_39: .word 0

; scratch words sit immediately after sx_39 (addresses 212-220), all within 8-bit LDI range.
; tmp_xrot/yrot/zrot/scale are used during vertex_loop (rotation and perspective projection).
; tmp_y1/sx/sy/dx/dy are used during draw_edges (Bresenham's line algorithm).
tmp_y1: .word 0
tmp_sx: .word 0
tmp_sy: .word 0
tmp_dx: .word 0
tmp_dy: .word 0
tmp_xrot: .word 0
tmp_yrot: .word 0
tmp_zrot: .word 0
tmp_scale: .word 0

; shape lookup tables split around the i/o hole at 237-244.
; shape_vcount through shape_vy_base land at addresses 221-236 (below the hole).
shape_vcount_0: .word 8
shape_vcount_1: .word 5
shape_vcount_2: .word 6
shape_vcount_3: .word obj_vcount

shape_ecount_0: .word 12
shape_ecount_1: .word 8
shape_ecount_2: .word 12
shape_ecount_3: .word obj_ecount

shape_vx_base_0: .word cube_vx_0
shape_vx_base_1: .word pyramid_vx_0
shape_vx_base_2: .word octa_vx_0
shape_vx_base_3: .word vx

shape_vy_base_0: .word cube_vy_0
shape_vy_base_1: .word pyramid_vy_0
shape_vy_base_2: .word octa_vy_0
shape_vy_base_3: .word vy

; 8 placeholders occupy 237-244; runtime i/o mapping is active at 240-244.
io_hole_pad_0: .word 0
io_hole_pad_1: .word 0
io_hole_pad_2: .word 0
io_hole_pad_3: .word 0
io_hole_pad_4: .word 0
io_hole_pad_5: .word 0
io_hole_pad_6: .word 0
io_hole_pad_7: .word 0

; shape_vz_base and shape_edge_base land at 245-252 (above the hole).
shape_vz_base_0: .word cube_vz_0
shape_vz_base_1: .word pyramid_vz_0
shape_vz_base_2: .word octa_vz_0
shape_vz_base_3: .word vz

shape_edge_base_0: .word cube_edges_0
shape_edge_base_1: .word pyramid_edges_0
shape_edge_base_2: .word octa_edges_0
shape_edge_base_3: .word obj_edges

; sy_0 lands at 253, within 8-bit ldi range and clear of the i/o hole.
; sy[0..39] occupies 253-292 with no overlap with 237-244.
sy_0: .word 0
sy_1: .word 0
sy_2: .word 0
sy_3: .word 0
sy_4: .word 0
sy_5: .word 0
sy_6: .word 0
sy_7: .word 0
sy_8: .word 0
sy_9: .word 0
sy_10: .word 0
sy_11: .word 0
sy_12: .word 0
sy_13: .word 0
sy_14: .word 0
sy_15: .word 0
sy_16: .word 0
sy_17: .word 0
sy_18: .word 0
sy_19: .word 0
sy_20: .word 0
sy_21: .word 0
sy_22: .word 0
sy_23: .word 0
sy_24: .word 0
sy_25: .word 0
sy_26: .word 0
sy_27: .word 0
sy_28: .word 0
sy_29: .word 0
sy_30: .word 0
sy_31: .word 0
sy_32: .word 0
sy_33: .word 0
sy_34: .word 0
sy_35: .word 0
sy_36: .word 0
sy_37: .word 0
sy_38: .word 0
sy_39: .word 0

; cube centered at origin.
cube_vx_0: .word -1280
cube_vx_1: .word 1280
cube_vx_2: .word 1280
cube_vx_3: .word -1280
cube_vx_4: .word -1280
cube_vx_5: .word 1280
cube_vx_6: .word 1280
cube_vx_7: .word -1280

cube_vy_0: .word -1280
cube_vy_1: .word -1280
cube_vy_2: .word 1280
cube_vy_3: .word 1280
cube_vy_4: .word -1280
cube_vy_5: .word -1280
cube_vy_6: .word 1280
cube_vy_7: .word 1280

cube_vz_0: .word -1280
cube_vz_1: .word -1280
cube_vz_2: .word -1280
cube_vz_3: .word -1280
cube_vz_4: .word 1280
cube_vz_5: .word 1280
cube_vz_6: .word 1280
cube_vz_7: .word 1280

cube_edges_0: .word 0
cube_edges_1: .word 1
cube_edges_2: .word 1
cube_edges_3: .word 2
cube_edges_4: .word 2
cube_edges_5: .word 3
cube_edges_6: .word 3
cube_edges_7: .word 0
cube_edges_8: .word 4
cube_edges_9: .word 5
cube_edges_10: .word 5
cube_edges_11: .word 6
cube_edges_12: .word 6
cube_edges_13: .word 7
cube_edges_14: .word 7
cube_edges_15: .word 4
cube_edges_16: .word 0
cube_edges_17: .word 4
cube_edges_18: .word 1
cube_edges_19: .word 5
cube_edges_20: .word 2
cube_edges_21: .word 6
cube_edges_22: .word 3
cube_edges_23: .word 7

; pyramid.
pyramid_vx_0: .word -1280
pyramid_vx_1: .word 1280
pyramid_vx_2: .word 1280
pyramid_vx_3: .word -1280
pyramid_vx_4: .word 0

pyramid_vy_0: .word -1024
pyramid_vy_1: .word -1024
pyramid_vy_2: .word -1024
pyramid_vy_3: .word -1024
pyramid_vy_4: .word 1792

pyramid_vz_0: .word -1280
pyramid_vz_1: .word -1280
pyramid_vz_2: .word 1280
pyramid_vz_3: .word 1280
pyramid_vz_4: .word 0

pyramid_edges_0: .word 0
pyramid_edges_1: .word 1
pyramid_edges_2: .word 1
pyramid_edges_3: .word 2
pyramid_edges_4: .word 2
pyramid_edges_5: .word 3
pyramid_edges_6: .word 3
pyramid_edges_7: .word 0
pyramid_edges_8: .word 0
pyramid_edges_9: .word 4
pyramid_edges_10: .word 1
pyramid_edges_11: .word 4
pyramid_edges_12: .word 2
pyramid_edges_13: .word 4
pyramid_edges_14: .word 3
pyramid_edges_15: .word 4

; octahedron.
octa_vx_0: .word 0
octa_vx_1: .word 1536
octa_vx_2: .word 0
octa_vx_3: .word -1536
octa_vx_4: .word 0
octa_vx_5: .word 0

octa_vy_0: .word 1536
octa_vy_1: .word 0
octa_vy_2: .word 0
octa_vy_3: .word 0
octa_vy_4: .word 0
octa_vy_5: .word -1536

octa_vz_0: .word 0
octa_vz_1: .word 0
octa_vz_2: .word 1536
octa_vz_3: .word 0
octa_vz_4: .word -1536
octa_vz_5: .word 0

octa_edges_0: .word 0
octa_edges_1: .word 1
octa_edges_2: .word 0
octa_edges_3: .word 2
octa_edges_4: .word 0
octa_edges_5: .word 3
octa_edges_6: .word 0
octa_edges_7: .word 4
octa_edges_8: .word 5
octa_edges_9: .word 1
octa_edges_10: .word 5
octa_edges_11: .word 2
octa_edges_12: .word 5
octa_edges_13: .word 3
octa_edges_14: .word 5
octa_edges_15: .word 4
octa_edges_16: .word 1
octa_edges_17: .word 2
octa_edges_18: .word 2
octa_edges_19: .word 3
octa_edges_20: .word 3
octa_edges_21: .word 4
octa_edges_22: .word 4
octa_edges_23: .word 1

; shape slot 3 is loaded from a .obj file. change the filename below to use a different model.
; the optional axis order argument remaps .obj axes to renderer axes (xzy makes z-up models stand upright).
; the assembler reads the face list, auto-centers/scales the vertices, and generates the edge list.
; supports up to 40 vertices (limited by the sx/sy buffer sizes defined earlier in the data section).
.obj minecraft_char.obj xyz
; vertex arrays (vx, vy, vz) and edge list (obj_edges) are injected here automatically at assemble time.

.text
; each frame follows the same pattern:
; read the controls, project every vertex, rasterize every edge, then wait long
; enough that the display hardware can show the finished frame.
main:
    ; r3 is the angle index into the 64-step sin/cos tables.
    LDI r3, 0

frame_loop:
    ; read selected shape and mirror it to the LED output register.
    LDI r4, 240
    LOAD r0, r4
    LDI r4, 244
    STORE r4, r0

    ; load active shape metadata from lookup tables.
    LDI r4, shape_vcount_0
    ADD r4, r0
    LOAD r1, r4
    LDI r4, active_vcount
    STORE r4, r1

    LDI r4, shape_ecount_0
    ADD r4, r0
    LOAD r1, r4
    LDI r4, active_ecount
    STORE r4, r1

    LDI r4, shape_vx_base_0
    ADD r4, r0
    LOAD r1, r4
    LDI r4, active_vx_base
    STORE r4, r1

    LDI r4, shape_vy_base_0
    ADD r4, r0
    LOAD r1, r4
    LDI r4, active_vy_base
    STORE r4, r1

    LDI r4, shape_vz_base_0
    ADD r4, r0
    LOAD r1, r4
    LDI r4, active_vz_base
    STORE r4, r1

    LDI r4, shape_edge_base_0
    ADD r4, r0
    LOAD r1, r4
    LDI r4, active_edge_base
    STORE r4, r1

    ; flip pages then clear the new back page to black.
    CLR
    LDI r7, 0
    LDI r0, 0
clear_y_loop:
    LDI r1, 0
clear_x_loop:
    PLOT r1, r0
    LDI r2, 1
    ADD r1, r2
    LDI r2, 160
    BEQ r1, r2, clear_x_done
    JMP clear_x_loop
clear_x_done:
    LDI r2, 1
    ADD r0, r2
    LDI r2, 120
    BEQ r0, r2, clear_done
    JMP clear_y_loop
clear_done:
    LDI r4, 241
    LOAD r7, r4

    ; load sin and cos for the current angle.
    LDI r4, sin_0
    ADD r4, r3
    LOAD r1, r4

    LDI r4, cos_0
    ADD r4, r3
    LOAD r2, r4

    LDI r0, 0

    ; walk every vertex once, rotate it in two axes, apply perspective, and
    ; stash the final screen coordinates for the edge pass.
vertex_loop:
    ; load x and z from the active shape.
    LDI r4, active_vx_base
    LOAD r4, r4
    ADD r4, r0
    LOAD r5, r4

    LDI r4, active_vz_base
    LOAD r4, r4
    ADD r4, r0
    LOAD r6, r4

    ; x' = x*cos - z*sin
    MOV r4, r5
    MUL r4, r2
    MOV r5, r6
    MUL r5, r1
    SUB r4, r5
    LDI r5, tmp_xrot
    STORE r5, r4

    ; z' = x*sin + z*cos
    LDI r4, active_vx_base
    LOAD r4, r4
    ADD r4, r0
    LOAD r5, r4
    MUL r5, r1
    MOV r4, r6
    MUL r4, r2
    ADD r5, r4
    LDI r4, tmp_zrot
    STORE r4, r5

    ; y' = y*cos - z'*sin
    LDI r4, active_vy_base
    LOAD r4, r4
    ADD r4, r0
    LOAD r6, r4
    MOV r4, r6
    MUL r4, r2
    LDI r5, tmp_zrot
    LOAD r5, r5
    MUL r5, r1
    SUB r4, r5
    LDI r5, tmp_yrot
    STORE r5, r4

    ; z'' = y*sin + z'*cos so the shape rotates around a second axis.
    LDI r4, active_vy_base
    LOAD r4, r4
    ADD r4, r0
    LOAD r6, r4
    MUL r6, r1
    LDI r5, tmp_zrot
    LOAD r5, r5
    MUL r5, r2
    ADD r6, r5
    LDI r5, tmp_zrot
    STORE r5, r6

    ; perspective projection
    ; closer vertices appear larger, farther ones smaller.
    ; step 1: shift z into camera space (add camera_z so depth is always positive).
    ; step 2: look up a scale factor = focal_length / z_camera from a precomputed
    ;         table (no divide instruction available, so values are precomputed).
    ; step 3: multiply rotated x and y by that scale, then shift to screen center.
    ;         y is subtracted from the center so positive 3D y points up on screen.

    ; z_camera = z'' + camera distance so perspective uses a positive depth.
    LDI r5, camera_z
    LOAD r5, r5
    ADD r6, r5

    ; scale = focal / z_camera via lookup table on integer camera-space depth.
    MOV r4, r6
    SHR r4, 8
    LDI r5, 20
    BLT r4, r5, scale_index_ready
    MOV r4, r5

scale_index_ready:
    LDI r5, perspective_0
    ADD r5, r4
    LOAD r4, r5
scale_store:
    LDI r5, tmp_scale
    STORE r5, r4

    ; project scaled x to screen space.
    ; shift before adding center so the 16-bit intermediate stays in range.
    LDI r5, tmp_xrot
    LOAD r5, r5
    MUL r5, r4
    SHR r5, 8          ; shift first: result fits in ~[-70,70], no overflow
    LDI r6, 80
    ADD r5, r6          ; add center after shift: result in ~[10,150], safe

    ; project y with screen-space inversion so positive 3D Y moves upward.
    ; same ordering: shift before applying the center offset.
    LDI r6, tmp_yrot
    LOAD r6, r6
    MUL r6, r4
    SHR r6, 8          ; shift first
    LDI r4, 60
    SUB r4, r6          ; subtract from center after shift: no overflow
    MOV r6, r4

    ; store the projected vertex in the screen buffers.
    LDI r4, sx_0
    ADD r4, r0
    STORE r4, r5

    LDI r4, sy_0
    ADD r4, r0
    STORE r4, r6

    LDI r4, 1
    ADD r0, r4
    LDI r4, active_vcount
    LOAD r4, r4
    BEQ r0, r4, draw_edges
    JMP vertex_loop

    ; once all projected points are ready, walk the edge list and draw one line
    ; at a time out of the cached screen-space buffers.
draw_edges:
    LDI r0, 0

edge_loop:
    ; load edge endpoints v0 and v1.
    LDI r4, active_edge_base
    LOAD r4, r4
    MOV r5, r0
    SHL r5, 1
    ADD r4, r5
    LOAD r1, r4

    LDI r5, 1
    ADD r4, r5
    LOAD r2, r4

    ; load x0 and y0.
    LDI r4, sx_0
    ADD r4, r1
    LOAD r4, r4

    LDI r5, sy_0
    ADD r5, r1
    LOAD r5, r5

    ; load x1 and y1.
    LDI r6, sx_0
    ADD r6, r2
    LOAD r6, r6

    LDI r1, sy_0
    ADD r1, r2
    LOAD r1, r1
    LDI r2, tmp_y1
    STORE r2, r1

    ; Bresenham's line algorithm: compute dx, dy, and per-axis step signs,
    ; then drive the major axis one pixel at a time and use an integer error
    ; accumulator to decide when to step the minor axis.
    ; tmp_sx = sign(x1 - x0)
    BLT r4, r6, set_sx_pos
    BEQ r4, r6, set_sx_zero
set_sx_neg:
    LDI r1, 255
    SHL r1, 8
    LDI r2, 255
    OR r1, r2
    JMP save_sx
set_sx_pos:
    LDI r1, 1
    JMP save_sx
set_sx_zero:
    LDI r1, 0
save_sx:
    LDI r2, tmp_sx
    STORE r2, r1

    ; tmp_sy = sign(y1 - y0)
    LDI r2, tmp_y1
    LOAD r1, r2
    BLT r5, r1, set_sy_pos
    BEQ r5, r1, set_sy_zero
set_sy_neg:
    LDI r1, 255
    SHL r1, 8
    LDI r2, 255
    OR r1, r2
    JMP save_sy
set_sy_pos:
    LDI r1, 1
    JMP save_sy
set_sy_zero:
    LDI r1, 0
save_sy:
    LDI r2, tmp_sy
    STORE r2, r1

    ; tmp_dx = abs(x1 - x0)
    BLT r6, r4, dx_from_x0
dx_from_x1:
    MOV r1, r6
    SUB r1, r4
    JMP save_dx
dx_from_x0:
    MOV r1, r4
    SUB r1, r6
save_dx:
    LDI r2, tmp_dx
    STORE r2, r1

    ; tmp_dy = abs(y1 - y0)
    LDI r2, tmp_y1
    LOAD r1, r2
    BLT r1, r5, dy_from_y0
dy_from_y1:
    SUB r1, r5
    JMP save_dy
dy_from_y0:
    MOV r2, r5
    SUB r2, r1
    MOV r1, r2
save_dy:
    LDI r2, tmp_dy
    STORE r2, r1

    ; choose major axis for line stepping.
    LDI r2, tmp_dx
    LOAD r1, r2
    LDI r2, tmp_dy
    LOAD r2, r2
    BLT r1, r2, draw_line_y_major

    ; x-major line raster: step x every iteration, step y when error >= dx.
    LDI r1, tmp_dx
    LOAD r6, r1
    LDI r2, 0              ; r2 = Bresenham error accumulator
draw_line_x_major_loop:
    PLOT r4, r5

    LDI r1, 0
    BEQ r6, r1, x_done_local
    LDI r1, 1
    SUB r6, r1

    LDI r1, tmp_sx
    LOAD r1, r1
    ADD r4, r1             ; step major axis (x)

    LDI r1, tmp_dy
    LOAD r1, r1
    ADD r2, r1             ; accumulate error by dy

    LDI r1, tmp_dx
    LOAD r1, r1
    BLT r2, r1, draw_line_x_major_loop

    LDI r1, tmp_sy
    LOAD r1, r1
    ADD r5, r1             ; step minor axis (y)

    LDI r1, tmp_dx
    LOAD r1, r1
    SUB r2, r1             ; reset error by dx
    JMP draw_line_x_major_loop

x_done_local:
    JMP draw_line_done

draw_line_y_major:
    ; y-major line raster: step y every iteration, step x when error >= dy.
    LDI r1, tmp_dy
    LOAD r6, r1
    LDI r2, 0              ; r2 = Bresenham error accumulator
draw_line_y_major_loop:
    PLOT r4, r5

    LDI r1, 0
    BEQ r6, r1, y_done_local
    LDI r1, 1
    SUB r6, r1

    LDI r1, tmp_sy
    LOAD r1, r1
    ADD r5, r1             ; step major axis (y)

    LDI r1, tmp_dx
    LOAD r1, r1
    ADD r2, r1             ; accumulate error by dx

    LDI r1, tmp_dy
    LOAD r1, r1
    BLT r2, r1, draw_line_y_major_loop

    LDI r1, tmp_sx
    LOAD r1, r1
    ADD r4, r1             ; step minor axis (x)

    LDI r1, tmp_dy
    LOAD r1, r1
    SUB r2, r1             ; reset error by dy
    JMP draw_line_y_major_loop

y_done_local:
    JMP draw_line_done

draw_line_done:
    PLOT r4, r5

    LDI r5, 1
    ADD r0, r5
    LDI r5, active_ecount
    LOAD r5, r5
    BEQ r0, r5, frame_done
    JMP edge_loop

frame_done:
    ; delay based on runtime speed selection so the cpu does not lap the display
    ; swap logic and make the animation unreadable.
    LDI r4, 242
    LOAD r4, r4
    LDI r5, delay_0
    ADD r5, r4
    LOAD r4, r5
frame_delay_outer:
    LDI r5, 255
frame_delay_inner:
    LDI r6, 1
    SUB r5, r6
    LDI r6, 0
    BEQ r5, r6, frame_delay_next
    JMP frame_delay_inner
frame_delay_next:
    LDI r5, 1
    SUB r4, r5
    LDI r5, 0
    BEQ r4, r5, frame_advance_angle
    JMP frame_delay_outer

; wrap back to the start of the trig tables after one full turn.
frame_advance_angle:
    LDI r4, 1
    ADD r3, r4
    LDI r4, 64
    BEQ r3, r4, reset_angle
    JMP frame_loop

reset_angle:
    LDI r3, 0
    JMP frame_loop