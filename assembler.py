#!/usr/bin/env python3
#
# usage: python assembler.py spinning_cube.asm -o memfile.mem
#
# processes .obj directives in the .asm source (like ".obj minecraft_char.obj xzy") and injects vertex data
# into the data section of the memory image; only one .obj directive is supported per program
# (supports loading up to 40 vertices from obj data - defined by sx/sy buffer sizes in the assembly code)
#
# two pass assembler:
#   pass 1: scan for labels and their addresses, collect .data entries
#   pass 2: encode each instruction to 16 bit hex
# encoding formats (16 bit):
#  r type:  [4 opcode][3 Rd][3 Rs][6 unused], i type:  [4 opcode][3 Rd][1 zero][8 imm], 
#  b type:  [4 opcode][3 Rs][3 Rt][6 offset], j type:  [4 opcode][12 offset],
#  n type:  [4 opcode][12 zeros] (reuses r type encoding with rd=0 and rs=0)

import sys  # CLI and file I/O
import re   # regex parsing for instructions and labels
import math # sqrt for vector normalization

# opcodes for all 16 of our instructions
OPCODES = {
    "ADD":   0x0,
    "SUB":   0x1,
    "MUL":   0x2,
    "AND":   0x3,
    "OR":    0x4,
    "SHL":   0x5,
    "SHR":   0x6,
    "LDI":   0x7,
    "MOV":   0x8,
    "LOAD":  0x9,
    "STORE": 0xA,
    "BEQ":   0xB,
    "BLT":   0xC,
    "JMP":   0xD,
    "PLOT":  0xE,
    "CLR":   0xF,
}

# format each instruction uses
R_TYPE = {"ADD", "SUB", "MUL", "AND", "OR", "MOV", "LOAD", "STORE", "PLOT"}
I_TYPE = {"LDI", "SHL", "SHR"}
B_TYPE = {"BEQ", "BLT"}
J_TYPE = {"JMP"}
N_TYPE = {"CLR"}

def parseRegister(token):
    """
    @token: String Ex. R0, R1, R2
    parse a register name like R0, r3, R7 and return its number (0-7).
    raises ValueError if the token is not a valid register name.
    """
    token = token.strip().lower().rstrip(",")
    match = re.match(r"^r([0-7])$", token)
    if not match:
        raise ValueError(f"invalid register: '{token}'")
    return int(match.group(1))

def parseImmediate(token):
    """
    parses the immediate value and supports decimal, hex (0x..), and binary (0b..).
    returns its integer value
    """
    token = token.strip().rstrip(",")
    if token.startswith("0x") or token.startswith("0X"):
        return int(token, 16)
    if token.startswith("0b") or token.startswith("0B"):
        return int(token, 2)
    return int(token)

def toUnsigned(value, bits):
    """
    mask an integer to the given number of bits.
    this handles negative values correctly via twos complement -
    for example maskToBitWidth(-1, 6) gives 0b111111 = 63.
    used when encoding branch/jump offsets that can be negative.
    """
    mask = (1 << bits) - 1 # shift bits left and subtract by 1 to mask to the specified width
    return value & mask    # return binary value

# Encoding functions
# need one for each format type
# r type: shift opcode left 12, rd left 9, rs left 6
# i type: shift opcode left 12, rd left 9, then 8-bit immediate in low bits
# b type: like r type but offset in low 6 bits instead of zeros
# j type: opcode left 12, 12-bit offset in low bits
# n type: just opcode left 12, rest zeros (can reuse r type encoding with rd=0 and rs=0)
#
# for b and j the offset needs to be relative to PC+1
# (branch target - current address - 1)
#
# might need to handle sign extension for the offset fields

def encodeRtype(opcode, rd, rs): # (also handles N-type since it's just R-type with rd=0 and rs=0)
    # encodes a register-register instruction [4 opcode][3 Rd][3 Rs][6 unused]
    return (opcode << 12) | (rd << 9) | (rs << 6)
def encodeItype(opcode, rd, imm8):
    # encodes an immediate instruction [4 opcode][3 Rd][1 zero][8 imm]
    return (opcode << 12) | (rd << 9) | toUnsigned(imm8, 8)
def encodeBtype(opcode, rs, rt, offset6):
    # encodes a branch instruction [4 opcode][3 Rs][3 Rt][6 offset]
    return (opcode << 12) | (rs << 9) | (rt << 6) | toUnsigned(offset6, 6)
def encodeJtype(opcode, offset12):
    # encodes a jump instruction [4 opcode][12 offset]
    return (opcode << 12) | toUnsigned(offset12, 12)

def cleanLine(line):
    """
    Remove all comments and whitespaces from inputs
    """
    line = re.sub(r";.*", "", line) # semicolon comments
    line = re.sub(r"#.*", "", line) # hash comments
    return line.strip()

def floatToFixed88(floatValue):
    """
    convert a floating point number to 8.8 fixed point representation.
    8.8 means 8 bits for the integer part and 8 bits for the fractional part,
    so we multiply by 256 and round to the nearest integer.
    examples: 5.0 -> 1280,  -5.0 -> -1280,  0.5 -> 128
    result is clamped to fit in a signed 16-bit word (-32768 to 32767).
    """
    fixedValue = int(round(floatValue * 256))
    fixedValue = max(-32768, min(32767, fixedValue))
    return fixedValue

def injectObjData(objFilePath, dataEntries, labels, constants, axisOrder="xyz"):
    """
    Read a .obj file and inject its vertex and edge data into the assembler's data section.

    Produces three vertex arrays (vx, vy, vz) and a wireframe edge list (obj_edges).
    
    Also sets obj_vcount and obj_ecount as integer constants so .word directives in the
    .asm file can reference the counts directly (not as memory addresses).

    axisOrder controls which .obj axis maps to each renderer axis.
    Use 'xzy' for models where z points up so they stand upright on the screen.

    Only edges at sharp corners are kept (crease edge filtering), which removes the
    diagonal edges that appear when quad faces are split into triangles.
    """
    MAX_VERTEX_COUNT = 40   # must match the sx/sy buffer size in spinning_cube.asm
    CREASE_THRESHOLD = 0.99 # dot product cutoff: edges between flat faces are discarded

    # axisOrder is a string like 'xzy'; convert each character to an index (x=0, y=1, z=2)
    # so we can reorder raw coordinates from the file into renderer x/y/z
    axisMap = {"x": 0, "y": 1, "z": 2}
    axisOrder = axisOrder.lower()
    xi = axisMap[axisOrder[0]]
    yi = axisMap[axisOrder[1]]
    zi = axisMap[axisOrder[2]]

    # read the .obj file

    rawCoords = []  # list of [x, y, z] floats, one per vertex
    rawFaces = []   # list of vertex index lists, one per face

    try:
        with open(objFilePath, "r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("v "):
                    # vertex line: "v x y z" - skip vt/vn by requiring exactly 4 tokens
                    parts = line.split()
                    if len(parts) == 4:
                        try:
                            rawCoords.append([float(parts[1]), float(parts[2]), float(parts[3])])
                        except ValueError:
                            pass
                elif line.startswith("f "):
                    # face line: "f 1 2 3" or "f 1/t/n 2/t/n 3/t/n" etc.
                    # indices are 1-based; grab only the vertex part before the first "/"
                    parts = line.split()
                    try:
                        rawFaces.append([int(p.split("/")[0]) - 1 for p in parts[1:]])
                    except ValueError:
                        pass
    except FileNotFoundError as exc:
        raise FileNotFoundError(f".obj file not found: '{objFilePath}'") from exc

    if not rawCoords:
        raise ValueError(f"no vertex data found in '{objFilePath}'")

    # remap, center, and scale the vertices

    # reorder coordinates according to axisOrder
    xCoords = [c[xi] for c in rawCoords]
    yCoords = [c[yi] for c in rawCoords]
    zCoords = [c[zi] for c in rawCoords]

    # shift each axis so the model's midpoint lands at the origin (so it spins in place)
    def centerAxis(vals):
        mid = (min(vals) + max(vals)) / 2.0
        return [v - mid for v in vals]

    xCoords = centerAxis(xCoords)
    yCoords = centerAxis(yCoords)
    zCoords = centerAxis(zCoords)

    # scale uniformly so the largest dimension reaches +/-5.0, matching the other shapes
    maxExtent = max(
        max(abs(v) for v in xCoords),
        max(abs(v) for v in yCoords),
        max(abs(v) for v in zCoords),
    )
    if maxExtent > 0:
        scale = 5.0 / maxExtent
        xCoords = [v * scale for v in xCoords]
        yCoords = [v * scale for v in yCoords]
        zCoords = [v * scale for v in zCoords]

    vertexCount = len(xCoords)
    if vertexCount > MAX_VERTEX_COUNT:
        raise ValueError(
            f"'{objFilePath}' has {vertexCount} vertices (max {MAX_VERTEX_COUNT}); "
            f"enlarge the sx/sy buffers in the .asm to support more"
        )

    # build the wireframe edge list (crease edge filtering)
    # the goal is to keep only edges that sit at visible corners of the model,
    # and discard the internal diagonal edges added when quads are split into triangles.

    # step 1: break every face into triangles by fanning out from the first vertex
    # Reference: https://en.wikipedia.org/wiki/Fan_triangulation
    triangles = []
    for face in rawFaces:
        for i in range(1, len(face) - 1):
            triangles.append((face[0], face[i], face[i + 1]))

    # step 2: record which triangles share each edge
    edgeToTris = {}
    for triIdx, (v0, v1, v2) in enumerate(triangles):
        for edge in [
            (min(v0, v1), max(v0, v1)),
            (min(v1, v2), max(v1, v2)),
            (min(v0, v2), max(v0, v2)),
        ]:
            edgeToTris.setdefault(edge, []).append(triIdx)

    # step 3: compute the outward-facing surface normal for each triangle
    def crossProduct(a, b):
        return [
            a[1]*b[2] - a[2]*b[1],
            a[2]*b[0] - a[0]*b[2],
            a[0]*b[1] - a[1]*b[0],
        ]

    def normalize(v):
        mag = math.sqrt(v[0]**2 + v[1]**2 + v[2]**2)
        return [c / mag for c in v] if mag > 1e-10 else [0.0, 0.0, 0.0]

    triNormals = []
    for v0, v1, v2 in triangles:
        p0 = [xCoords[v0], yCoords[v0], zCoords[v0]]
        p1 = [xCoords[v1], yCoords[v1], zCoords[v1]]
        p2 = [xCoords[v2], yCoords[v2], zCoords[v2]]
        edge1 = [p1[i] - p0[i] for i in range(3)]
        edge2 = [p2[i] - p0[i] for i in range(3)]
        triNormals.append(normalize(crossProduct(edge1, edge2)))

    # step 4: keep edges where the two adjacent faces point in clearly different directions
    # the dot product of two unit normals equals the cosine of the dihedral angle between the faces;
    # Reference: https://en.wikipedia.org/wiki/Dihedral_angle
    # - a dot product near 1.0 means the faces are flat/coplanar -> internal edge, discard
    # - a dot product well below 1.0 means there is a real corner here -> keep the edge
    # - edges with only one adjacent face are always kept
    creaseEdges = []
    for edge, tris in sorted(edgeToTris.items()):
        if len(tris) == 1:
            creaseEdges.append(edge)
        elif len(tris) == 2:
            n0, n1 = triNormals[tris[0]], triNormals[tris[1]]
            dotProduct = sum(a * b for a, b in zip(n0, n1))
            if dotProduct < CREASE_THRESHOLD:
                creaseEdges.append(edge)

    edgeCount = len(creaseEdges)

    # store counts as integer constants (not addresses) so .word obj_vcount resolves to the number
    constants["obj_vcount"] = vertexCount
    constants["obj_ecount"] = edgeCount
    print(f"  .obj '{objFilePath}': {vertexCount} vertices, {edgeCount} crease edges")

    # write vertex arrays and edge list into the data section
    # each append adds one word to memory; labels["name"] records that word's address so the .asm file can reference it by name

    labels["vertex_count"] = len(dataEntries)
    dataEntries.append(("vertex_count", vertexCount))

    # three arrays: all x coords, then all y, then all z (struct-of-arrays layout)
    labels["vx"] = len(dataEntries)
    for i, x in enumerate(xCoords):
        dataEntries.append((f"vx_{i}", floatToFixed88(x)))

    labels["vy"] = len(dataEntries)
    for i, y in enumerate(yCoords):
        dataEntries.append((f"vy_{i}", floatToFixed88(y)))

    labels["vz"] = len(dataEntries)
    for i, z in enumerate(zCoords):
        dataEntries.append((f"vz_{i}", floatToFixed88(z)))

    # edge list: alternating v0, v1 pairs - the runtime reads two words per edge
    labels["obj_edges"] = len(dataEntries)
    for i, (v0, v1) in enumerate(creaseEdges):
        dataEntries.append((f"obj_edge_{i}_v0", v0))
        dataEntries.append((f"obj_edge_{i}_v1", v1))

def resolveDataEntries(labels, dataEntries, constants=None):
    resolvedDataEntries = []

    for name, rawValue in dataEntries:
        if isinstance(rawValue, int):
            resolvedValue = rawValue
        elif constants and rawValue in constants:
            resolvedValue = constants[rawValue]  # integer value, not a memory address
        elif rawValue in labels:
            resolvedValue = labels[rawValue]     # memory address of the labeled word
        else:
            resolvedValue = parseImmediate(rawValue)
        resolvedDataEntries.append((name, resolvedValue))

    return resolvedDataEntries

def firstPass(lines):
    """
    scan all source lines, find labels and their memory addresses,
    and collect all .data entries. also handles the .obj directive.
    returns (labels, instructions, dataEntries).

    addressing structure:
        data words occupy addresses 0, 1, 2 ... (len(dataEntries) - 1)
        instructions start immediately after at address len(dataEntries)
        code label addresses stored here are relative to the start of the
        instruction section
        - the code label addresses get fixed up to absolute addresses at the end
          of this function once the full data section size is known.
    """
    labels = {}
    instructions = []
    dataEntries = []
    constants = {}  # integer constants set by directives (like obj_vcount, obj_ecount)
    inDataSection = False
    relativeInstructionCounter = 0 # (formerly programCounter)
    # ^^ counts how many instructions we've seen so far, which is the address
    # of the next instruction relative to the start of the instruction section

    for lineNum, rawLine in enumerate(lines, start=1):
        line = cleanLine(rawLine)
        if not line:
            continue

        if line.lower() == ".data":
            inDataSection = True
            continue
        if line.lower() == ".text":
            inDataSection = False
            continue

        # .obj directive: .obj path/to/file.obj [axisOrder]
        # axisOrder is optional (default xyz); for example, use 'xzy' for z-up models
        objDirectiveMatch = re.match(r"^\.obj\s+(\S+)(?:\s+([xyz]{3}))?$", line, re.IGNORECASE)
        if objDirectiveMatch:
            objFilePath = objDirectiveMatch.group(1)
            axisOrder = objDirectiveMatch.group(2) or "xyz"
            injectObjData(objFilePath, dataEntries, labels, constants, axisOrder)
            continue

        # data section: "name: .word value"
        if inDataSection:
            match = re.match(r"^(\w+):\s*\.word\s+(.+)$", line, re.IGNORECASE)
            if match:
                name = match.group(1)
                rawValue = match.group(2).strip()
                try:
                    value = parseImmediate(rawValue)
                except ValueError:
                    value = rawValue
                labels[name] = len(dataEntries)
                dataEntries.append((name, value))
            continue

        if ":" in line:
            labelPart, remainder = line.split(":", 1)
            labelName = labelPart.strip()
            if labelName:
                labels[labelName] = ("code", relativeInstructionCounter)
            line = remainder.strip()
            if not line:
                continue

        instructions.append((lineNum, line, relativeInstructionCounter))
        relativeInstructionCounter += 1

    # fix up all code labels to absolute addresses now that data section size is known
    dataSectionSize = len(dataEntries)
    for labelName in list(labels.keys()):
        storedValue = labels[labelName]
        if isinstance(storedValue, tuple) and storedValue[0] == "code":
            labels[labelName] = dataSectionSize + storedValue[1]
            # ^^ code label address = size of data section + offset within code section

    dataEntries = resolveDataEntries(labels, dataEntries, constants)
    return labels, instructions, dataEntries


def secondPass(labels, instructions, dataEntries):
    """
    walk through every instruction collected by firstPass and encode
    each one into a single 16-bit integer (machine code).

    basic idea for each instruction type like:
    rtype (add, sub, mul, and, or, mov, load, store, plot):
        parse two registers call encodeRtype
    itype (shl, shr, ldi):
        parse one register and one immediate (or data label address)
    btype (beq, blt):
        parse two registers and a label compute offset = target - (pc+1)
    jtype (jmp):
        parse label compute offset = target - (pc+1)
    ntype (clr):
        no operands just encode opcode with zeros

    offset gotcha:
        labels were fixed up to absolute addresses in firstPass
        (data section size + relative instruction offset).
        but the pc stored with each instruction tuple is still relative
        to the start of the instruction section. so when computing
        branch/jump offsets we need to convert pc to absolute first:
            absolutePC = len(dataEntries) + relativePC
            offset = labels[target] - absolutePC - 1
        the -1 is because the branch is relative to PC+1 (the next instruction).
    """
    dataSectionSize = len(dataEntries)
    machineCode = []

    for lineNum, line, relativePC in instructions:
        tokens = line.replace(",", " ").split()
        mnemonic = tokens[0].upper()

        if mnemonic not in OPCODES:
            raise SyntaxError(f"line {lineNum}: unknown instruction '{mnemonic}'")

        opcode = OPCODES[mnemonic]
        absolutePC = dataSectionSize + relativePC

        if mnemonic in R_TYPE:
            rd = parseRegister(tokens[1])
            rs = parseRegister(tokens[2])
            word = encodeRtype(opcode, rd, rs)

        elif mnemonic in I_TYPE:
            rd = parseRegister(tokens[1])
            immToken = tokens[2]
            # check if the immediate is actually a label name
            if immToken in labels:
                imm = labels[immToken]
            else:
                imm = parseImmediate(immToken)
            word = encodeItype(opcode, rd, imm)

        elif mnemonic in B_TYPE:
            rs = parseRegister(tokens[1])
            rt = parseRegister(tokens[2])
            target = tokens[3]
            if target in labels:
                offset = labels[target] - absolutePC - 1
            else:
                offset = parseImmediate(target)
            word = encodeBtype(opcode, rs, rt, offset)

        elif mnemonic in J_TYPE:
            target = tokens[1]
            if target in labels:
                offset = labels[target] - absolutePC - 1
            else:
                offset = parseImmediate(target)
            word = encodeJtype(opcode, offset)

        elif mnemonic in N_TYPE:
            word = encodeRtype(opcode, 0, 0)

        else:
            raise SyntaxError(f"line {lineNum}: '{mnemonic}' has no known format")

        machineCode.append(word)

    return machineCode

def formatOutput(machineCode, dataEntries):
    """format data words and instructions as hex, one 16-bit word per line"""
    outputLines = []

    # data words first (they sit at addresses 0 .. len-1)
    for idx, (name, value) in enumerate(dataEntries):
        hexWord = f"{toUnsigned(value, 16):04X}"
        outputLines.append(f"{hexWord}  ; data[{idx}] {name} = {value}")

    # instructions follow right after
    for idx, word in enumerate(machineCode):
        hexWord = f"{word:04X}"
        outputLines.append(f"{hexWord}  ; instr[{idx}]")

    return "\n".join(outputLines)


def main():
    """
    main function:
    expects the .asm filename as a CLI argument
    to run and print to terminal:
        python assembler.py spinning_cube.asm
    to run and write to file:
        python assembler.py spinning_cube.asm -o memfile.mem
    
    after reading the source file, it runs the two passes of the assembler and prints the final machine code output.
    """
    
    # check for correct usage and read the source file
    if len(sys.argv) < 2:
        print("usage: assembler.py <source.asm> [-o output.mem]")
        sys.exit(1)

    asmFilePath = sys.argv[1]
    outputPath = None
    if "-o" in sys.argv:
        oIndex = sys.argv.index("-o")
        if oIndex + 1 < len(sys.argv):
            outputPath = sys.argv[oIndex + 1]

    try:
        with open(asmFilePath, "r") as asmFile:
            sourceLines = asmFile.readlines()
    except FileNotFoundError:
        print(f"error: file not found: '{asmFilePath}'")
        sys.exit(1)

    # run the two passes of the assembler and print the final machine code output
    labels, instructions, dataEntries = firstPass(sourceLines)
    encodedInstructions = secondPass(labels, instructions, dataEntries)
    output = formatOutput(encodedInstructions, dataEntries)

    print(output)

    if outputPath:
        with open(outputPath, "w") as outFile:
            outFile.write(output + "\n")
        print(f"\nassembled {len(encodedInstructions)} instructions, {len(dataEntries)} data words -> {outputPath}")


if __name__ == "__main__":
    main()